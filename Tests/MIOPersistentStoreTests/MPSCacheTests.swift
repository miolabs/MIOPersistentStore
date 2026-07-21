//
//  MPSCacheTests.swift
//  MIOPersistentStoreTests
//
//  Covers the node-cache internals: ingest through fetchObjects, cache-key
//  lookups, version gating, superentity registration, delete propagation and
//  thread safety of the per-store cache queue.
//

#if !APPLE_CORE_DATA

import XCTest
import Foundation
import MIOCoreData
@testable import MIOPersistentStore
@testable import CoreDataSwift

// MARK: - Test model

/// xcdatamodel `contents` XML parsed by NSManagedObjectModelParser. Written to
/// a temp file because the parser only loads from a URL.
private let testModelXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<model type="com.apple.IDECoreDataModeler.DataModel" documentVersion="1.0">
    <entity name="SimpleEntity" representedClassName="SimpleEntity" syncable="YES">
        <attribute name="identifier" attributeType="UUID"/>
        <attribute name="name" attributeType="String"/>
        <attribute name="type" attributeType="Integer 16" defaultValueString="0" usesScalarValueType="YES"/>
        <attribute name="when" attributeType="Date" optional="YES"/>
    </entity>
    <entity name="BaseEntity" isAbstract="YES" syncable="YES">
        <attribute name="identifier" attributeType="UUID"/>
        <attribute name="name" attributeType="String"/>
    </entity>
    <entity name="DerivedEntity" parentEntity="BaseEntity" syncable="YES">
        <attribute name="extra" attributeType="String" optional="YES"/>
    </entity>
</model>
"""

func MPSTestManagedObjectModel() -> MIOCoreData.NSManagedObjectModel
{
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MPSTestModel-\(ProcessInfo.processInfo.processIdentifier).xml")
    if FileManager.default.fileExists(atPath: url.path) == false {
        try! testModelXML.data(using: .utf8)!.write(to: url)
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
    var fetchCount = 0

    func store(store: MIOPersistentStore, fetchRequest: MIOCoreData.NSFetchRequest<MIOCoreData.NSManagedObject>, identifier: UUID?) -> MPSRequest? {
        fetchCount += 1
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

final class MPSCacheTests: XCTestCase
{
    fileprivate var container: MIOCoreData.NSPersistentContainer!
    fileprivate var store: MIOPersistentStore!
    fileprivate var storeDelegate: MockStoreDelegate!
    fileprivate var moc: MIOCoreData.NSManagedObjectContext!

    override func setUp() {
        super.setUp()

        MIOCoreData.NSPersistentStoreCoordinator.registerStoreClass(MIOPersistentStore.self, forStoreType: MIOPersistentStore.storeType)

        let description = MIOCoreData.NSPersistentStoreDescription(url: URL(string: "mps-test://\(UUID().uuidString)")!)
        description.type = MIOPersistentStore.storeType

        container = MIOCoreData.NSPersistentContainer(name: "TestDB", managedObjectModel: MPSTestManagedObjectModel())
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

    @discardableResult
    private func fetch(_ entityName: String, rows: [[String:Any]]) throws -> [Any] {
        storeDelegate.nextRows = rows
        let request = MIOCoreData.NSFetchRequest<MIOCoreData.NSManagedObject>(entityName: entityName)
        request.entity = entity(entityName)
        request.resultType = MIOCoreData.NSFetchRequestResultType.managedObjectIDResultType
        return try store.fetchObjects(fetchRequest: request, with: moc)
    }

    private func row(_ classname: String, _ id: UUID, name: String, version: Int = 1) -> [String:Any] {
        return [ "classname": classname, "identifier": id.uuidString, "name": name, "version": version ]
    }

    // MARK: Ingest

    func testFetchIngestsRowsAndCreatesCacheNodes() throws {
        let id1 = UUID(), id2 = UUID()
        let ids = try fetch("SimpleEntity", rows: [ row("SimpleEntity", id1, name: "one"),
                                                    row("SimpleEntity", id2, name: "two") ])

        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(storeDelegate.fetchCount, 1)

        let node = try store.cacheNode(withIdentifier: id1, entity: entity("SimpleEntity"))
        XCTAssertNotNil(node)
        XCTAssertEqual(node!.version, 1)
        XCTAssertEqual(try node!.storeNode().value(for: "name") as? String, "one")
    }

    func testCacheMissReturnsNil() throws {
        let node = try store.cacheNode(withIdentifier: UUID(), entity: entity("SimpleEntity"))
        XCTAssertNil(node)
    }

    // MARK: Version gate

    func testStaleVersionDoesNotOverwriteNode() throws {
        let id = UUID()
        try fetch("SimpleEntity", rows: [ row("SimpleEntity", id, name: "original", version: 2) ])
        try fetch("SimpleEntity", rows: [ row("SimpleEntity", id, name: "stale", version: 2) ])

        let node = try store.cacheNode(withIdentifier: id, entity: entity("SimpleEntity"))!
        XCTAssertEqual(node.version, 2)
        XCTAssertEqual(try node.storeNode().value(for: "name") as? String, "original")
    }

    func testNewerVersionUpdatesNode() throws {
        let id = UUID()
        try fetch("SimpleEntity", rows: [ row("SimpleEntity", id, name: "original", version: 1) ])
        let nodeBefore = try store.cacheNode(withIdentifier: id, entity: entity("SimpleEntity"))!
        try fetch("SimpleEntity", rows: [ row("SimpleEntity", id, name: "updated", version: 2) ])

        let node = try store.cacheNode(withIdentifier: id, entity: entity("SimpleEntity"))!
        XCTAssertTrue(node === nodeBefore, "an update must mutate the existing node, not replace it")
        XCTAssertEqual(node.version, 2)
        XCTAssertEqual(try node.storeNode().value(for: "name") as? String, "updated")
    }

    // MARK: Entity hierarchy

    func testSubentityRowRegistersUnderEveryHierarchyLevel() throws {
        let id = UUID()
        // A fetch on the base entity returning a row whose classname is the subentity.
        try fetch("BaseEntity", rows: [ row("DerivedEntity", id, name: "child") ])

        let derivedNode = try store.cacheNode(withIdentifier: id, entity: entity("DerivedEntity"))
        let baseNode    = try store.cacheNode(withIdentifier: id, entity: entity("BaseEntity"))

        XCTAssertNotNil(derivedNode)
        XCTAssertNotNil(baseNode)
        XCTAssertTrue(derivedNode === baseNode, "hierarchy levels must share one node instance")
    }

    func testDeleteNodeRemovesEveryHierarchyLevel() throws {
        let id = UUID()
        try fetch("BaseEntity", rows: [ row("DerivedEntity", id, name: "child") ])

        try store.cacheNode(deleteNodeAtIdentifier: id, entity: entity("DerivedEntity"))

        XCTAssertNil(try store.cacheNode(withIdentifier: id, entity: entity("DerivedEntity")))
        XCTAssertNil(try store.cacheNode(withIdentifier: id, entity: entity("BaseEntity")))
    }

    // MARK: Cache key & referenceID

    func testCacheKeyEquality() {
        let id = UUID()
        XCTAssertEqual(MPSCacheKey(entityName: "SimpleEntity", id: id),
                       MPSCacheKey(entityName: "SimpleEntity", id: id))
        XCTAssertNotEqual(MPSCacheKey(entityName: "SimpleEntity", id: id),
                          MPSCacheKey(entityName: "BaseEntity", id: id))
        XCTAssertNotEqual(MPSCacheKey(entityName: "SimpleEntity", id: id),
                          MPSCacheKey(entityName: "SimpleEntity", id: UUID()))
    }

    func testReferenceIDFormatIsStable() throws {
        let id = UUID()
        try fetch("SimpleEntity", rows: [ row("SimpleEntity", id, name: "x") ])

        let node = try store.cacheNode(withIdentifier: id, entity: entity("SimpleEntity"))!
        // uuidString is already uppercase — referenceID must keep the historical format.
        XCTAssertEqual(node.referenceID, "SimpleEntity://" + id.uuidString)
        XCTAssertEqual(node.cacheKey, MPSCacheKey(entityName: "SimpleEntity", id: id))
    }

    // MARK: Value conversion degradation

    func testUnconvertibleAttributeDegradesToNilWithoutFailingTheObject() throws {
        let id = UUID()
        var values = row("SimpleEntity", id, name: "ok")
        values["type"] = "not-a-number"           // Integer 16
        values["when"] = "not-a-date"             // Date
        try fetch("SimpleEntity", rows: [values])

        let node = try store.cacheNode(withIdentifier: id, entity: entity("SimpleEntity"))!

        // storeNode() must not throw: bad columns degrade to nil, good ones survive.
        let storeNode = try node.storeNode()
        XCTAssertEqual(storeNode.value(for: "name") as? String, "ok")
        XCTAssertNil(storeNode.value(for: "type"))
        XCTAssertNil(storeNode.value(for: "when"))
    }

    func testConvertibleValuesStillConvert() throws {
        let id = UUID()
        var values = row("SimpleEntity", id, name: "ok")
        values["type"] = "7"                      // numeric string -> Int16
        values["when"] = Date(timeIntervalSince1970: 1000)
        try fetch("SimpleEntity", rows: [values])

        let node = try store.cacheNode(withIdentifier: id, entity: entity("SimpleEntity"))!
        let storeNode = try node.storeNode()

        XCTAssertEqual(storeNode.value(for: "type") as? Int16, 7)
        XCTAssertEqual(storeNode.value(for: "when") as? Date, Date(timeIntervalSince1970: 1000))
    }

    func testConvertAttributeReturnsNilForUnconvertibleValues() {
        let attrs = entity("SimpleEntity").attributesByName

        XCTAssertNil(MPSCacheNode.convert(attribute: "zzz", attrs["when"]!, entityName: "SimpleEntity"))
        XCTAssertNil(MPSCacheNode.convert(attribute: "zzz", attrs["identifier"]!, entityName: "SimpleEntity"))
        XCTAssertNil(MPSCacheNode.convert(attribute: Data(), attrs["name"]!, entityName: "SimpleEntity"))
        XCTAssertNil(MPSCacheNode.convert(attribute: "zzz", attrs["type"]!, entityName: "SimpleEntity"))

        XCTAssertNotNil(MPSCacheNode.convert(attribute: UUID().uuidString, attrs["identifier"]!, entityName: "SimpleEntity"))
        XCTAssertEqual(MPSCacheNode.convert(attribute: 5, attrs["type"]!, entityName: "SimpleEntity") as? Int16, 5)
    }

    // MARK: Thread safety

    func testConcurrentCacheAccessIsThreadSafe() throws {
        let simple = entity("SimpleEntity")
        let ids = (0..<200).map { _ in UUID() }

        DispatchQueue.concurrentPerform(iterations: ids.count) { i in
            _ = try! store.cacheNode(newNodeWithValues: ["classname": "SimpleEntity", "identifier": ids[i].uuidString, "name": "n\(i)"],
                                     identifier: ids[i], version: 1, entity: simple, objectID: nil)
            _ = try! store.cacheNode(withIdentifier: ids[i], entity: simple)
        }

        for id in ids {
            XCTAssertNotNil(try store.cacheNode(withIdentifier: id, entity: simple))
        }
        XCTAssertEqual(store.nodesByCacheKey.count, ids.count)
    }
}

#endif

// MARK: - Temporary-object invariant

extension MPSCacheTests {

    /// Temporary (unsaved) objects exist only in the context until save: the
    /// store must not fetch the DB for them, must not resolve relationships,
    /// and must not hold cache nodes for their temporary reference IDs.
    func testTemporaryObjectsNeverReachTheDelegateOrTheCache() throws {
        let entityDesc = entity("SimpleEntity")
        let tempID = MIOCoreData.NSManagedObjectID(WithEntity: entityDesc, referenceObject: nil)
        tempID._persistentStore = store
        XCTAssertTrue(tempID.isTemporaryID)

        // newValuesForObject: empty node, no delegate fetch, no cache node.
        let node = try store.newValuesForObject(with: tempID, with: moc)
        XCTAssertEqual(node.version, 0)
        XCTAssertEqual(storeDelegate.fetchCount, 0, "a temporary object must never trigger a DB fetch")
        XCTAssertEqual(store.nodesByCacheKey.count, 0, "a temporary object must never create a cache node")

        // Registration callback: no placeholder nodes for temporary IDs.
        store.managedObjectContextDidRegisterObjects(with: [tempID])
        XCTAssertEqual(store.nodesByCacheKey.count, 0, "registering a temporary object must not cache it")
    }
}
