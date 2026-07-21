//
//  MPSRelationshipFaultingTests.swift
//  MIOPersistentStoreTests
//
//  Covers the store-level relationship faulting API on top of the cache:
//
//  newValue(forRelationship:) — a to-one resolves to the related node's
//  objectID (faulting the node with one delegate fetch when it is missing),
//  a to-many resolves every member id to an objectID and batch-faults ALL
//  missing members through a single delegate fetch. Nil relationships come
//  back as NSNull (to-one) / empty array (to-many).
//
//  storedValues(forRelationship:) — the raw membership the store knows:
//  [UUID] for a cached to-many, [] for missing values and temporary ids.
//
//  Save flow — context.save() merges changedValues() (whose to-many value is
//  a Set of managed objects) into the cache node, and the membership must
//  read back as UUIDs through both value(forRelationship:) and storedValues.
//

#if !APPLE_CORE_DATA

import XCTest
import Foundation
import MIOCore
import MIOCoreData
@testable import MIOPersistentStore

// MARK: - Test model (self-contained copy — do not share across test files)

private let faultingModelXML = """
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

// Materializing objects (managedObjectResultType fetches, existingObject)
// resolves the entity name through the _MIOCoreRegisterClass registry.
class ParentEntity: MIOCoreData.NSManagedObject {}
class ItemEntity: MIOCoreData.NSManagedObject {}

private func MPSFaultingTestModel() -> MIOCoreData.NSManagedObjectModel
{
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MPSFaultingTestModel-\(ProcessInfo.processInfo.processIdentifier).xml")
    if FileManager.default.fileExists(atPath: url.path) == false {
        try! faultingModelXML.data(using: .utf8)!.write(to: url)
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
    /// Every delegate fetch increments this — batch faulting asserts on it.
    var fetchCount = 0
    var saveCount = 0

    func store(store: MIOPersistentStore, fetchRequest: MIOCoreData.NSFetchRequest<MIOCoreData.NSManagedObject>, identifier: UUID?) -> MPSRequest? {
        fetchCount += 1
        return MockFetchRequest(entity: fetchRequest.entity!, rows: nextRows)
    }

    func store(store: MIOPersistentStore, saveRequest: MIOCoreData.NSSaveChangesRequest) -> MPSRequest? {
        saveCount += 1
        return MPSRequest()
    }

    func store(store: MIOPersistentStore, identifierForObject object: MIOCoreData.NSManagedObject) -> UUID? {
        return object.value(forKey: "identifier") as? UUID ?? UUID()
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

final class MPSRelationshipFaultingTests: XCTestCase
{
    fileprivate var container: MIOCoreData.NSPersistentContainer!
    fileprivate var store: MIOPersistentStore!
    fileprivate var storeDelegate: MockStoreDelegate!
    fileprivate var moc: MIOCoreData.NSManagedObjectContext!

    override func setUp() {
        super.setUp()

        MIOCoreData.NSPersistentStoreCoordinator.registerStoreClass(MIOPersistentStore.self, forStoreType: MIOPersistentStore.storeType)
        _MIOCoreRegisterClass(type: ParentEntity.self, forKey: "ParentEntity")
        _MIOCoreRegisterClass(type: ItemEntity.self, forKey: "ItemEntity")

        let description = MIOCoreData.NSPersistentStoreDescription(url: URL(string: "mps-fault-test://\(UUID().uuidString)")!)
        description.type = MIOPersistentStore.storeType

        container = MIOCoreData.NSPersistentContainer(name: "FaultTestDB", managedObjectModel: MPSFaultingTestModel())
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in
            if let error = error { fatalError("Store failed to load: \(error)") }
        }

        store = (container.persistentStoreCoordinator.persistentStores[0] as! MIOPersistentStore)
        storeDelegate = MockStoreDelegate()
        store.delegate = storeDelegate
        moc = container.viewContext
    }

    // MARK: Helpers

    private func entity(_ name: String) -> MIOCoreData.NSEntityDescription {
        return container.managedObjectModel.entitiesByName[name]!
    }

    private var itemsRel:    MIOCoreData.NSRelationshipDescription { entity("ParentEntity").relationshipsByName["items"]! }
    private var favoriteRel: MIOCoreData.NSRelationshipDescription { entity("ParentEntity").relationshipsByName["favorite"]! }

    @discardableResult
    private func fetch(_ entityName: String, rows: [[String:Any]],
                       resultType: MIOCoreData.NSFetchRequestResultType = .managedObjectIDResultType) throws -> [Any] {
        storeDelegate.nextRows = rows
        let request = MIOCoreData.NSFetchRequest<MIOCoreData.NSManagedObject>(entityName: entityName)
        request.entity = entity(entityName)
        request.resultType = resultType
        return try store.fetchObjects(fetchRequest: request, with: moc)
    }

    private func parentRow(_ id: UUID, items: [UUID]? = nil, favorite: UUID? = nil) -> [String:Any] {
        var row: [String:Any] = [ "classname": "ParentEntity", "identifier": id.uuidString, "name": "p", "version": 1 ]
        if let items = items { row["items"] = items.map { $0.uuidString } }
        if let favorite = favorite { row["favorite"] = favorite.uuidString }
        return row
    }

    private func itemRow(_ id: UUID) -> [String:Any] {
        return [ "classname": "ItemEntity", "identifier": id.uuidString, "version": 1 ]
    }

    private func referenceID(of objectID: MIOCoreData.NSManagedObjectID) -> UUID {
        return store.referenceObject(for: objectID) as! UUID
    }

    private func parentObjectID(_ id: UUID) throws -> MIOCoreData.NSManagedObjectID {
        return try store.cacheNode(withIdentifier: id, entity: entity("ParentEntity"))!.objectID
    }

    // MARK: newValue(forRelationship:) — to-one

    func testToOneNewValueReturnsObjectIDFaultingMissingNodeWithOneFetch() throws {
        let parentID = UUID(), favID = UUID()
        try fetch("ParentEntity", rows: [ parentRow(parentID, favorite: favID) ])

        storeDelegate.nextRows = [ itemRow(favID) ]
        let fetchesBefore = storeDelegate.fetchCount

        let value = try store.newValue(forRelationship: favoriteRel, forObjectWith: parentObjectID(parentID), with: moc)

        guard let objID = value as? MIOCoreData.NSManagedObjectID else {
            return XCTFail("to-one must resolve to an objectID, got \(value)")
        }
        XCTAssertEqual(referenceID(of: objID), favID)
        XCTAssertEqual(objID.entity.name, "ItemEntity")
        XCTAssertEqual(storeDelegate.fetchCount - fetchesBefore, 1, "missing node must fault with exactly one fetch")

        // Second read hits the cache: no further fetch.
        _ = try store.newValue(forRelationship: favoriteRel, forObjectWith: parentObjectID(parentID), with: moc)
        XCTAssertEqual(storeDelegate.fetchCount - fetchesBefore, 1)
    }

    func testToOneNewValueForNilRelationshipReturnsNSNull() throws {
        let parentID = UUID()
        try fetch("ParentEntity", rows: [ parentRow(parentID) ])

        let value = try store.newValue(forRelationship: favoriteRel, forObjectWith: parentObjectID(parentID), with: moc)
        XCTAssertTrue(value is NSNull, "nil to-one must read back as NSNull, got \(value)")
    }

    // MARK: newValue(forRelationship:) — to-many

    func testToManyNewValueBatchFaultsAllMissingMembersInOneFetch() throws {
        let parentID = UUID()
        let itemIDs = [UUID(), UUID(), UUID()]
        try fetch("ParentEntity", rows: [ parentRow(parentID, items: itemIDs) ])

        // No item node is cached yet: all three must fault through ONE fetch.
        storeDelegate.nextRows = itemIDs.map { itemRow($0) }
        let fetchesBefore = storeDelegate.fetchCount

        let value = try store.newValue(forRelationship: itemsRel, forObjectWith: parentObjectID(parentID), with: moc)

        guard let objIDs = value as? [MIOCoreData.NSManagedObjectID] else {
            return XCTFail("to-many must resolve to [NSManagedObjectID], got \(value)")
        }
        XCTAssertEqual(Set(objIDs.map { referenceID(of: $0) }), Set(itemIDs))
        XCTAssertEqual(storeDelegate.fetchCount - fetchesBefore, 1, "all missing members must batch-fault in a single fetch")
    }

    func testToManyNewValueUsesCachedNodesWithoutFetching() throws {
        let parentID = UUID()
        let itemIDs = [UUID(), UUID()]
        try fetch("ItemEntity", rows: itemIDs.map { itemRow($0) })
        try fetch("ParentEntity", rows: [ parentRow(parentID, items: itemIDs) ])

        let fetchesBefore = storeDelegate.fetchCount
        let value = try store.newValue(forRelationship: itemsRel, forObjectWith: parentObjectID(parentID), with: moc)

        XCTAssertEqual(Set((value as! [MIOCoreData.NSManagedObjectID]).map { referenceID(of: $0) }), Set(itemIDs))
        XCTAssertEqual(storeDelegate.fetchCount, fetchesBefore, "cached members must not fetch")
    }

    func testToManyNewValueForMissingRelationshipReturnsEmptyArray() throws {
        let parentID = UUID()
        try fetch("ParentEntity", rows: [ parentRow(parentID) ])

        let value = try store.newValue(forRelationship: itemsRel, forObjectWith: parentObjectID(parentID), with: moc)
        XCTAssertEqual((value as? [Any])?.count, 0, "missing to-many must read back as an empty array, got \(value)")
    }

    // MARK: storedValues(forRelationship:) shapes

    func testStoredValuesReturnsUUIDsForCachedToMany() throws {
        let parentID = UUID()
        let itemIDs = [UUID(), UUID()]
        try fetch("ParentEntity", rows: [ parentRow(parentID, items: itemIDs) ])

        let fetchesBefore = storeDelegate.fetchCount
        let stored = try store.storedValues(forRelationship: itemsRel, forObjectWith: parentObjectID(parentID), with: moc)

        XCTAssertEqual(stored as? [UUID], itemIDs)
        XCTAssertEqual(storeDelegate.fetchCount, fetchesBefore, "a version>0 node must not refetch")
    }

    func testStoredValuesReturnsEmptyForMissingRelationshipAndForToOne() throws {
        let parentID = UUID(), favID = UUID()
        try fetch("ParentEntity", rows: [ parentRow(parentID, favorite: favID) ])

        XCTAssertEqual(try store.storedValues(forRelationship: itemsRel, forObjectWith: parentObjectID(parentID), with: moc).count, 0)
        // A to-one UUID is neither Set<NSManagedObject> nor [UUID]: degrades to [].
        XCTAssertEqual(try store.storedValues(forRelationship: favoriteRel, forObjectWith: parentObjectID(parentID), with: moc).count, 0)
    }

    func testStoredValuesForTemporaryObjectIDIsEmptyWithoutFetching() throws {
        let obj = MIOCoreData.NSManagedObject(entity: entity("ParentEntity"), insertInto: moc)
        XCTAssertTrue(obj.objectID.isTemporaryID)

        let fetchesBefore = storeDelegate.fetchCount
        let stored = try store.storedValues(forRelationship: itemsRel, forObjectWith: obj.objectID, with: moc)

        XCTAssertEqual(stored.count, 0)
        XCTAssertEqual(storeDelegate.fetchCount, fetchesBefore, "temporary ids must not hit the delegate")
    }

    func testStoredValuesOnVersionZeroNodeTriggersDelegateFetch() throws {
        // The hidden mid-save fetch: a node that exists at version 0 (registered
        // but never fetched) forces a full delegate round-trip inside
        // storedValues. Pinned here because DualLink's obj_to_line diff relies
        // on it — see EntityContext+Entity.swift.
        let parentID = UUID()
        let itemIDs = [UUID()]
        _ = try store.cacheNode(newNodeWithValues: [:], identifier: parentID, version: 0, entity: entity("ParentEntity"), objectID: nil)

        storeDelegate.nextRows = [ parentRow(parentID, items: itemIDs) ]
        let fetchesBefore = storeDelegate.fetchCount

        let stored = try store.storedValues(forRelationship: itemsRel, forObjectWith: parentObjectID(parentID), with: moc)

        XCTAssertEqual(storeDelegate.fetchCount - fetchesBefore, 1, "version-0 node must fetch through the delegate")
        XCTAssertEqual(stored as? [UUID], itemIDs)
    }

    // MARK: Save flow — changedValues() merged into the cache node

    func testSaveMergesToManyChangeIntoCacheNodeAndReadsBack() throws {
        let parentID = UUID()
        let itemIDs = [UUID(), UUID()]

        // Materialize parent (no items) and both items as real objects.
        let parents = try fetch("ParentEntity", rows: [ parentRow(parentID) ], resultType: .managedObjectResultType)
        let items   = try fetch("ItemEntity", rows: itemIDs.map { itemRow($0) }, resultType: .managedObjectResultType)
        let parent = parents[0] as! MIOCoreData.NSManagedObject

        parent.setValue(Set(items.map { $0 as! MIOCoreData.NSManagedObject }), forKey: "items")
        XCTAssertTrue(moc.updatedObjects.contains(parent))

        try moc.save()
        XCTAssertEqual(storeDelegate.saveCount, 1)

        // The cache node absorbed the Set<NSManagedObject> from changedValues()
        // and converts it back to UUIDs on read.
        let node = try store.cacheNode(withIdentifier: parentID, entity: entity("ParentEntity"))!
        guard let uuids = try node.value(forRelationship: itemsRel) as? [UUID] else {
            return XCTFail("merged to-many must read back as [UUID]")
        }
        XCTAssertEqual(Set(uuids), Set(itemIDs))

        // And the store-level APIs agree.
        let stored = try store.storedValues(forRelationship: itemsRel, forObjectWith: parent.objectID, with: moc)
        XCTAssertEqual(Set(stored as? [UUID] ?? []), Set(itemIDs))

        let value = try store.newValue(forRelationship: itemsRel, forObjectWith: parent.objectID, with: moc)
        XCTAssertEqual(Set((value as! [MIOCoreData.NSManagedObjectID]).map { referenceID(of: $0) }), Set(itemIDs))
    }

    func testSaveClearingToManyReadsBackEmpty() throws {
        let parentID = UUID()
        let itemIDs = [UUID()]

        let parents = try fetch("ParentEntity", rows: [ parentRow(parentID, items: itemIDs) ], resultType: .managedObjectResultType)
        _ = try fetch("ItemEntity", rows: itemIDs.map { itemRow($0) }, resultType: .managedObjectResultType)
        let parent = parents[0] as! MIOCoreData.NSManagedObject

        parent.setValue(nil, forKey: "items")
        try moc.save()

        let stored = try store.storedValues(forRelationship: itemsRel, forObjectWith: parent.objectID, with: moc)
        XCTAssertEqual(stored.count, 0, "cleared to-many must read back empty, got \(stored)")
    }

    // MARK: Malformed cache values

    func testDeltaShapedRelationshipValuePoisonsTheNode() throws {
        // The DualLink sync pipeline shapes to-many values as [[add],[sub]]
        // deltas. That shape must NEVER reach a cache node: if a delegate ever
        // feeds it through a fetch row, the first fault throws invalidValueType
        // instead of silently mis-reading membership.
        let parentID = UUID()
        var row = parentRow(parentID)
        row["items"] = [[UUID().uuidString], [UUID().uuidString]]
        try fetch("ParentEntity", rows: [row])

        let node = try store.cacheNode(withIdentifier: parentID, entity: entity("ParentEntity"))!
        XCTAssertThrowsError(try node.value(forRelationship: itemsRel))
        XCTAssertThrowsError(try store.storedValues(forRelationship: itemsRel, forObjectWith: node.objectID, with: moc))
    }
}

#endif
