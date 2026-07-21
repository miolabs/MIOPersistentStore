//
//  MPSRelationshipConversionTests.swift
//  MIOPersistentStoreTests
//
//  Covers the lazy relationship conversion in MPSCacheNode: raw relation
//  values (UUIDs, uuid strings, sets, object references) become UUID
//  reference ids on first fault, and malformed values throw instead of
//  silently degrading. Also exercises the ingest-to-fault path end to end:
//  a fetched row whose to-many key holds uuid strings must read back as
//  [UUID] through value(forRelationship:).
//

#if !APPLE_CORE_DATA

import XCTest
import Foundation
import MIOCoreData
@testable import MIOPersistentStore

// MARK: - Test model (self-contained copy — do not share with MPSCacheTests)

private let relationshipModelXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<model type="com.apple.IDECoreDataModeler.DataModel" documentVersion="1.0">
    <entity name="ParentEntity" representedClassName="ParentEntity" syncable="YES">
        <attribute name="identifier" attributeType="UUID"/>
        <attribute name="name" attributeType="String" optional="YES"/>
        <relationship name="items" optional="YES" toMany="YES" deletionRule="Nullify" destinationEntity="ItemEntity" inverseName="parent" inverseEntity="ItemEntity"/>
        <relationship name="favorite" optional="YES" deletionRule="Nullify" destinationEntity="ItemEntity"/>
    </entity>
    <entity name="ItemEntity" representedClassName="ItemEntity" syncable="YES">
        <attribute name="identifier" attributeType="UUID"/>
        <relationship name="parent" optional="YES" deletionRule="Nullify" destinationEntity="ParentEntity" inverseName="items" inverseEntity="ParentEntity"/>
    </entity>
</model>
"""

private func MPSRelationshipTestModel() -> MIOCoreData.NSManagedObjectModel
{
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MPSRelationshipTestModel-\(ProcessInfo.processInfo.processIdentifier).xml")
    if FileManager.default.fileExists(atPath: url.path) == false {
        try! relationshipModelXML.data(using: .utf8)!.write(to: url)
    }
    return MIOCoreData.NSManagedObjectModel(contentsOf: url)!
}

// MARK: - Delegate mock

fileprivate class MockFetchRequest: MPSFetchRequest
{
    let rows: [[String:Any]]

    init(entity: MIOCoreData.NSEntityDescription, rows: [[String:Any]]) {
        self.rows = rows
        super.init(entity: entity)
    }

    override func execute() throws {
        resultItems = [ "entities": rows, "relationShipEntities": [] ]
    }
}

fileprivate class MockStoreDelegate: NSObject, MIOPersistentStoreDelegate
{
    /// Rows the next fetch request will return.
    var nextRows: [[String:Any]] = []

    func store(store: MIOPersistentStore, fetchRequest: MIOCoreData.NSFetchRequest<MIOCoreData.NSManagedObject>, identifier: UUID?) -> MPSRequest? {
        return MockFetchRequest(entity: fetchRequest.entity!, rows: nextRows)
    }

    func store(store: MIOPersistentStore, saveRequest: MIOCoreData.NSSaveChangesRequest) -> MPSRequest? {
        return MPSRequest()
    }

    func store(store: MIOPersistentStore, identifierForObject object: MIOCoreData.NSManagedObject) -> UUID? {
        return UUID()
    }

    func store(store: MIOPersistentStore, identifierFromItem item: [String:Any], fetchEntityName: String) -> UUID? {
        return UUID(uuidString: item["identifier"] as! String)
    }

    func store(store: MIOPersistentStore, versionFromItem item: [String:Any], fetchEntityName: String) -> UInt64 {
        if let v = item["version"] as? UInt64 { return v }
        if let v = item["version"] as? Int    { return UInt64(v) }
        return 1
    }
}

// MARK: - Tests

final class MPSRelationshipConversionTests: XCTestCase
{
    fileprivate var container: MIOCoreData.NSPersistentContainer!
    fileprivate var store: MIOPersistentStore!
    fileprivate var storeDelegate: MockStoreDelegate!
    fileprivate var moc: MIOCoreData.NSManagedObjectContext!

    override func setUp() {
        super.setUp()

        MIOCoreData.NSPersistentStoreCoordinator.registerStoreClass(MIOPersistentStore.self, forStoreType: MIOPersistentStore.storeType)

        let description = MIOCoreData.NSPersistentStoreDescription(url: URL(string: "mps-rel-test://\(UUID().uuidString)")!)
        description.type = MIOPersistentStore.storeType

        container = MIOCoreData.NSPersistentContainer(name: "RelTestDB", managedObjectModel: MPSRelationshipTestModel())
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in
            if let error = error { fatalError("Store failed to load: \(error)") }
        }

        store = (container.persistentStoreCoordinator.persistentStores[0] as! MIOPersistentStore)
        storeDelegate = MockStoreDelegate()
        store.delegate = storeDelegate
        moc = container.viewContext
    }

    private func entity(_ name: String) -> MIOCoreData.NSEntityDescription {
        return container.managedObjectModel.entitiesByName[name]!
    }

    private var toOne:  MIOCoreData.NSRelationshipDescription { entity("ParentEntity").relationshipsByName["favorite"]! }
    private var toMany: MIOCoreData.NSRelationshipDescription { entity("ParentEntity").relationshipsByName["items"]! }

    private func convert(_ value: Any, _ rel: MIOCoreData.NSRelationshipDescription) throws -> Any {
        return try MPSCacheNode.convert(relationship: value, rel, entityName: "ParentEntity")
    }

    // MARK: convert(relationship:) — to-one

    func testToOneFromUUIDPassesThrough() throws {
        let id = UUID()
        XCTAssertEqual(try convert(id, toOne) as? UUID, id)
    }

    func testToOneFromUUIDStringConverts() throws {
        let id = UUID()
        XCTAssertEqual(try convert(id.uuidString, toOne) as? UUID, id)
        // Web/sync payloads often carry lowercase ids.
        XCTAssertEqual(try convert(id.uuidString.lowercased(), toOne) as? UUID, id)
    }

    // MARK: convert(relationship:) — to-many

    func testToManyFromUUIDArrayPassesThrough() throws {
        let ids = [UUID(), UUID()]
        XCTAssertEqual(try convert(ids, toMany) as? [UUID], ids)
    }

    func testToManyFromStringArrayConverts() throws {
        let ids = [UUID(), UUID()]
        let raw = [ids[0].uuidString, ids[1].uuidString.lowercased()]
        XCTAssertEqual(try convert(raw, toMany) as? [UUID], ids)
    }

    func testToManyFromUUIDSetConverts() throws {
        let ids: Set<UUID> = [UUID(), UUID(), UUID()]
        guard let converted = try convert(ids, toMany) as? [UUID] else {
            return XCTFail("Set<UUID> must convert to a UUID array")
        }
        XCTAssertEqual(Set(converted), ids)
    }

    func testToManyFromEmptyArrayIsEmpty() throws {
        XCTAssertEqual((try convert([Any](), toMany) as? [UUID])?.count, 0)
    }

    // MARK: convert(relationship:) — invalid values throw

    func testInvalidValuesThrow() {
        XCTAssertThrowsError(try convert(42, toOne))
        XCTAssertThrowsError(try convert("not-a-uuid", toOne))
        XCTAssertThrowsError(try convert(42, toMany))
        XCTAssertThrowsError(try convert(["not-a-uuid"], toMany))
        XCTAssertThrowsError(try convert([UUID().uuidString, "junk"], toMany), "one bad id must fail the whole array")
    }

    // MARK: End to end: ingest row -> value(forRelationship:)

    func testIngestedStringIDsReadBackAsUUIDs() throws {
        let parentID = UUID()
        let itemIDs = [UUID(), UUID()]
        let favoriteID = UUID()

        storeDelegate.nextRows = [[
            "classname": "ParentEntity",
            "identifier": parentID.uuidString,
            "name": "p",
            "version": 1,
            "items": itemIDs.map { $0.uuidString },
            "favorite": favoriteID.uuidString
        ]]

        let request = MIOCoreData.NSFetchRequest<MIOCoreData.NSManagedObject>(entityName: "ParentEntity")
        request.entity = entity("ParentEntity")
        request.resultType = MIOCoreData.NSFetchRequestResultType.managedObjectIDResultType
        _ = try store.fetchObjects(fetchRequest: request, with: moc)

        let node = try store.cacheNode(withIdentifier: parentID, entity: entity("ParentEntity"))
        XCTAssertNotNil(node)

        XCTAssertEqual(try node!.value(forRelationship: toMany) as? [UUID], itemIDs)
        XCTAssertEqual(try node!.value(forRelationship: toOne) as? UUID, favoriteID)
    }

    func testMissingRelationshipKeyReadsBackAsNil() throws {
        let parentID = UUID()
        storeDelegate.nextRows = [[
            "classname": "ParentEntity",
            "identifier": parentID.uuidString,
            "version": 1
        ]]

        let request = MIOCoreData.NSFetchRequest<MIOCoreData.NSManagedObject>(entityName: "ParentEntity")
        request.entity = entity("ParentEntity")
        request.resultType = MIOCoreData.NSFetchRequestResultType.managedObjectIDResultType
        _ = try store.fetchObjects(fetchRequest: request, with: moc)

        let node = try store.cacheNode(withIdentifier: parentID, entity: entity("ParentEntity"))!
        XCTAssertNil(try node.value(forRelationship: toMany))
        XCTAssertNil(try node.value(forRelationship: toOne))
    }
}

#endif
