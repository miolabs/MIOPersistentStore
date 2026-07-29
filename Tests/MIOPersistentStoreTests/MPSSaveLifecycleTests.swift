//
//  MPSSaveLifecycleTests.swift
//  MIOPersistentStoreTests
//
//  Save-request lifecycle of the node cache, per the Apple NSIncrementalStore
//  contract (macOS probe, 2026-07): the save request populates the row cache
//  for inserted objects, updates it for updated ones and evicts deleted ones;
//  didRegister/didUnregister are a reference count on the cache, evicting only
//  when the last registration goes away.
//
//  Regression covered: insert -> save -> update -> save trapped on a force
//  unwrap (Signal 4) because nothing cached a node for the inserted object
//  (DLPaymentServer crash, createOnlineOrderTransaction, 2026-07-29).
//

#if !APPLE_CORE_DATA

import XCTest
import Foundation
import MIOCoreData
@testable import MIOPersistentStore
@testable import CoreDataSwift

// MARK: - Delegate mock

fileprivate class LifecycleMockRequest: MPSFetchRequest
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

fileprivate class LifecycleMockDelegate: NSObject, MIOPersistentStoreDelegate
{
    var nextRows: [[String:Any]] = []
    var saveCount = 0

    func store(store: MIOPersistentStore, fetchRequest: MIOCoreData.NSFetchRequest<MIOCoreData.NSManagedObject>, identifier: UUID?) -> MPSRequest? {
        return LifecycleMockRequest(entity: fetchRequest.entity!, rows: nextRows)
    }

    func store(store: MIOPersistentStore, saveRequest: MIOCoreData.NSSaveChangesRequest) -> MPSRequest? {
        saveCount += 1
        return MPSRequest()
    }

    /// Deterministic permanent IDs: the object's own identifier attribute,
    /// exactly like the DL servers do.
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

final class MPSSaveLifecycleTests: XCTestCase
{
    fileprivate var container: MIOCoreData.NSPersistentContainer!
    fileprivate var store: MIOPersistentStore!
    fileprivate var storeDelegate: LifecycleMockDelegate!
    fileprivate var moc: MIOCoreData.NSManagedObjectContext!

    override func setUp() {
        super.setUp()

        MIOCoreData.NSPersistentStoreCoordinator.registerStoreClass(MIOPersistentStore.self, forStoreType: MIOPersistentStore.storeType)

        let description = MIOCoreData.NSPersistentStoreDescription(url: URL(string: "mps-lifecycle-test://\(UUID().uuidString)")!)
        description.type = MIOPersistentStore.storeType

        container = MIOCoreData.NSPersistentContainer(name: "TestDB", managedObjectModel: MPSTestManagedObjectModel())
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in
            if let error = error { fatalError("Store failed to load: \(error)") }
        }

        store = (container.persistentStoreCoordinator.persistentStores[0] as! MIOPersistentStore)
        storeDelegate = LifecycleMockDelegate()
        store.delegate = storeDelegate
        moc = container.viewContext
    }

    private func entity(_ name: String) -> MIOCoreData.NSEntityDescription {
        return container.managedObjectModel.entitiesByName[name]!
    }

    private func insertSimpleEntity(id: UUID, name: String) -> MIOCoreData.NSManagedObject {
        let obj = MIOCoreData.NSManagedObject(entity: entity("SimpleEntity"), insertInto: moc)
        obj.setValue(id, forKey: "identifier")
        obj.setValue(name, forKey: "name")
        return obj
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

    // MARK: Insert-save populates the cache

    func testInsertSaveCreatesCacheNode() throws {
        let id = UUID()
        _ = insertSimpleEntity(id: id, name: "fresh")

        try moc.save()

        XCTAssertEqual(storeDelegate.saveCount, 1)
        let node = try store.cacheNode(withIdentifier: id, entity: entity("SimpleEntity"))
        XCTAssertNotNil(node, "the save request must populate the row cache for inserted objects")
        XCTAssertEqual(try node!.storeNode().value(for: "name") as? String, "fresh")
    }

    // MARK: The DLPaymentServer regression

    func testInsertSaveUpdateSaveDoesNotTrap() throws {
        let id = UUID()
        let obj = insertSimpleEntity(id: id, name: "MOOD/00000")

        try moc.save()

        // The crash sequence: mutate the freshly saved object and save again.
        obj.setValue("PRF/600200", forKey: "name")
        XCTAssertNoThrow(try moc.save(),
                         "insert -> save -> update -> save must not fail (Signal 4 regression)")

        let node = try store.cacheNode(withIdentifier: id, entity: entity("SimpleEntity"))
        XCTAssertNotNil(node)
        XCTAssertEqual(try node!.storeNode().value(for: "name") as? String, "PRF/600200")
    }

    // MARK: Delete-save evicts

    func testDeleteSaveEvictsCacheNode() throws {
        let id = UUID()
        let obj = insertSimpleEntity(id: id, name: "doomed")
        try moc.save()
        XCTAssertNotNil(try store.cacheNode(withIdentifier: id, entity: entity("SimpleEntity")))

        moc.delete(obj)
        try moc.save()

        XCTAssertNil(try store.cacheNode(withIdentifier: id, entity: entity("SimpleEntity")),
                     "the save request must evict deleted rows from the cache")
    }

    // MARK: Missing node is an error, not a trap

    func testUpdateOfUncachedNodeThrowsInsteadOfTrapping() {
        XCTAssertThrowsError(try store.cacheNode(updateNodeWithValues: ["name": "x"],
                                                 identifier: UUID(),
                                                 entity: entity("SimpleEntity"))) { error in
            guard case MIOPersistentStoreError.cacheNodeNotFound = error else {
                return XCTFail("expected cacheNodeNotFound, got \(error)")
            }
        }
    }

    // MARK: Registration reference counting

    func testUnregisterEvictsOnlyWhenLastRegistrationGoes() throws {
        let id = UUID()
        try fetch("SimpleEntity", rows: [ row("SimpleEntity", id, name: "shared") ])

        let node = try store.cacheNode(withIdentifier: id, entity: entity("SimpleEntity"))!
        let objID = node.objectID

        // Two contexts hold the object.
        store.managedObjectContextDidRegisterObjects(with: [objID])
        store.managedObjectContextDidRegisterObjects(with: [objID])

        // First context lets go: the node must survive for the second one.
        store.managedObjectContextDidUnregisterObjects(with: [objID])
        XCTAssertNotNil(try store.cacheNode(withIdentifier: id, entity: entity("SimpleEntity")),
                        "a node still registered by another context must not be evicted")

        // Last registration goes away: now it can be evicted.
        store.managedObjectContextDidUnregisterObjects(with: [objID])
        XCTAssertNil(try store.cacheNode(withIdentifier: id, entity: entity("SimpleEntity")))
    }

    func testRegisterIgnoresTemporaryIDs() {
        let tempID = MIOCoreData.NSManagedObjectID(WithEntity: entity("SimpleEntity"), referenceObject: nil)
        tempID._persistentStore = store
        XCTAssertTrue(tempID.isTemporaryID)

        store.managedObjectContextDidRegisterObjects(with: [tempID])
        store.managedObjectContextDidUnregisterObjects(with: [tempID])

        XCTAssertEqual(store.nodesByCacheKey.count, 0)
        XCTAssertEqual(store.registrationCountByCacheKey.count, 0)
    }

    func testRegistrationBeforeNodeIsNotLost() throws {
        // A fault materialized from a bare permanent ID registers before any
        // row is cached (the node arrives at first fault or at save). The
        // count must be recorded anyway, or eviction accounting is wrong for
        // the node's whole lifetime.
        let id = UUID()
        let objID = store.newObjectID(for: entity("SimpleEntity"), referenceObject: id)

        store.managedObjectContextDidRegisterObjects(with: [objID])
        XCTAssertEqual(store.registrationCountByCacheKey[MPSCacheKey(entityName: "SimpleEntity", id: id)], 1,
                       "a registration without a cached row must still be counted")

        // The row arrives later.
        try fetch("SimpleEntity", rows: [ row("SimpleEntity", id, name: "late") ])
        XCTAssertNotNil(try store.cacheNode(withIdentifier: id, entity: entity("SimpleEntity")))

        // The early registration is what keeps the eviction balanced.
        store.managedObjectContextDidUnregisterObjects(with: [objID])
        XCTAssertNil(try store.cacheNode(withIdentifier: id, entity: entity("SimpleEntity")),
                     "the pre-node registration must count toward eviction")
        XCTAssertEqual(store.registrationCountByCacheKey.count, 0)
    }

    func testDeleteSaveDropsStaleRegistrationCounts() throws {
        let id = UUID()
        let obj = insertSimpleEntity(id: id, name: "doomed")
        try moc.save()

        // Another context still holds a registration when the delete-save
        // lands: the row and its counts go with the save, and the outstanding
        // unregister becomes a harmless no-op.
        let objID = try store.cacheNode(withIdentifier: id, entity: entity("SimpleEntity"))!.objectID
        store.managedObjectContextDidRegisterObjects(with: [objID])

        moc.delete(obj)
        try moc.save()

        XCTAssertNil(try store.cacheNode(withIdentifier: id, entity: entity("SimpleEntity")))
        XCTAssertNil(store.registrationCountByCacheKey[MPSCacheKey(entityName: "SimpleEntity", id: id)],
                     "a delete-save must drop the registration counts with the row")
        store.managedObjectContextDidUnregisterObjects(with: [objID])   // must not trap or resurrect anything
        XCTAssertEqual(store.registrationCountByCacheKey.count, 0)
    }

    // MARK: Subentity inserts register the whole hierarchy

    func testInsertSaveOfSubentityCachesEveryHierarchyLevel() throws {
        let id = UUID()
        let obj = MIOCoreData.NSManagedObject(entity: entity("DerivedEntity"), insertInto: moc)
        obj.setValue(id, forKey: "identifier")
        obj.setValue("child", forKey: "name")

        try moc.save()

        let derivedNode = try store.cacheNode(withIdentifier: id, entity: entity("DerivedEntity"))
        let baseNode    = try store.cacheNode(withIdentifier: id, entity: entity("BaseEntity"))
        XCTAssertNotNil(derivedNode)
        XCTAssertNotNil(baseNode)
        XCTAssertTrue(derivedNode === baseNode, "hierarchy levels must share one node instance")
    }
}

#endif
