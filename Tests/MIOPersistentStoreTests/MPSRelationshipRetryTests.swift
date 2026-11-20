//
//  MPSRelationshipRetryTests.swift
//  MIOPersistentStoreTests
//
//  End-to-end through the managed object: a to-one resolves to its
//  destination without fetching it, so a destination the store cannot load
//  (the delegate returned no row, or the delegate request itself failed)
//  shows up when the destination is READ. That read must be nil for that
//  read only: the destination stays a fault, the next access goes back to the
//  store — one more delegate fetch — and resolves once the row is there.
//
//  Before this was pinned, a single failed fetch (a DB hiccup, a row the
//  delegate query could not return) read as nil for the rest of the object's
//  life. It was first pinned on the relationship read, when the to-one
//  fetched its destination eagerly; the destination is lazy now, so the same
//  guarantee is pinned on the destination's own load.
//
//  A genuine nil (the owner row carries no value) is an answer: it is
//  resolved once and never re-asked.
//

#if !APPLE_CORE_DATA

import XCTest
import Foundation
import MIOCore
import MIOCoreData
@testable import MIOPersistentStore

// MARK: - Test model (self-contained copy — do not share across test files)

private let retryModelXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<model type="com.apple.IDECoreDataModeler.DataModel" documentVersion="1.0">
    <entity name="RetryOwnerEntity" representedClassName="RetryOwnerEntity" syncable="YES">
        <attribute name="identifier" attributeType="UUID"/>
        <attribute name="name" attributeType="String" optional="YES"/>
        <relationship name="target" optional="YES" maxCount="1" deletionRule="Nullify" destinationEntity="RetryTargetEntity"/>
    </entity>
    <entity name="RetryTargetEntity" representedClassName="RetryTargetEntity" syncable="YES">
        <attribute name="identifier" attributeType="UUID"/>
    </entity>
</model>
"""

class RetryOwnerEntity: MIOCoreData.NSManagedObject {}
class RetryTargetEntity: MIOCoreData.NSManagedObject {}

private func MPSRetryTestModel() -> MIOCoreData.NSManagedObjectModel
{
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MPSRetryTestModel-\(ProcessInfo.processInfo.processIdentifier).xml")
    if FileManager.default.fileExists(atPath: url.path) == false {
        try! retryModelXML.data(using: .utf8)!.write(to: url)
    }
    return MIOCoreData.NSManagedObjectModel(contentsOf: url)!
}

// MARK: - Delegate mock

fileprivate struct MockDelegateError: Error {}

fileprivate class MockFetchRequest: MPSFetchRequest
{
    let rows: [[String:Any]]
    let error: Error?

    init(entity: MIOCoreData.NSEntityDescription, rows: [[String:Any]], error: Error?) {
        self.rows = rows
        self.error = error
        super.init(entity: entity)
    }

    override func execute() throws {
        if let error = error { throw error }
        resultItems = [ "entities": rows, "relationShipEntities": [] ]
    }
}

fileprivate class MockStoreDelegate: NSObject, MIOPersistentStoreDelegate
{
    /// Rows the next fetch request will return.
    var nextRows: [[String:Any]] = []
    /// Thrown by the next fetch request's execute(), then cleared.
    var nextError: Error? = nil
    /// Every delegate fetch increments this.
    var fetchCount = 0

    func store(store: MIOPersistentStore, fetchRequest: MIOCoreData.NSFetchRequest<MIOCoreData.NSManagedObject>, identifier: UUID?) -> MPSRequest? {
        fetchCount += 1
        let error = nextError
        nextError = nil
        return MockFetchRequest(entity: fetchRequest.entity!, rows: nextRows, error: error)
    }

    func store(store: MIOPersistentStore, saveRequest: MIOCoreData.NSSaveChangesRequest) -> MPSRequest? {
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

final class MPSRelationshipRetryTests: XCTestCase
{
    fileprivate var container: MIOCoreData.NSPersistentContainer!
    fileprivate var store: MIOPersistentStore!
    fileprivate var storeDelegate: MockStoreDelegate!
    fileprivate var moc: MIOCoreData.NSManagedObjectContext!

    override func setUp() {
        super.setUp()

        MIOCoreData.NSPersistentStoreCoordinator.registerStoreClass(MIOPersistentStore.self, forStoreType: MIOPersistentStore.storeType)
        _MIOCoreRegisterClass(type: RetryOwnerEntity.self, forKey: "RetryOwnerEntity")
        _MIOCoreRegisterClass(type: RetryTargetEntity.self, forKey: "RetryTargetEntity")

        let description = MIOCoreData.NSPersistentStoreDescription(url: URL(string: "mps-retry-test://\(UUID().uuidString)")!)
        description.type = MIOPersistentStore.storeType

        container = MIOCoreData.NSPersistentContainer(name: "RetryTestDB", managedObjectModel: MPSRetryTestModel())
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

    private func ownerRow(_ id: UUID, target: UUID? = nil) -> [String:Any] {
        var row: [String:Any] = [ "classname": "RetryOwnerEntity", "identifier": id.uuidString, "name": "owner", "version": 1 ]
        if let target = target { row["target"] = target.uuidString }
        return row
    }

    private func targetRow(_ id: UUID) -> [String:Any] {
        return [ "classname": "RetryTargetEntity", "identifier": id.uuidString, "version": 1 ]
    }

    /// Fetches the owner row through the store and materializes it as a
    /// managed object, exactly like a context fetch does.
    private func fetchOwner(_ row: [String:Any]) throws -> MIOCoreData.NSManagedObject {
        storeDelegate.nextRows = [row]
        let request = MIOCoreData.NSFetchRequest<MIOCoreData.NSManagedObject>(entityName: "RetryOwnerEntity")
        request.entity = entity("RetryOwnerEntity")
        request.resultType = .managedObjectResultType
        return try store.fetchObjects(fetchRequest: request, with: moc)[0] as! MIOCoreData.NSManagedObject
    }

    // MARK: Tests

    /// The to-one itself: the destination, with no delegate fetch
    private func target(of owner: MIOCoreData.NSManagedObject, fetchesBefore: Int) throws -> MIOCoreData.NSManagedObject {
        let target = try XCTUnwrap(owner.value(forKey: "target") as? MIOCoreData.NSManagedObject)
        XCTAssertEqual(storeDelegate.fetchCount, fetchesBefore, "resolving a to-one must not fetch its destination")
        XCTAssertFalse(owner.hasFault(forRelationshipNamed: "target"))
        return target
    }

    func testMissingDestinationRowReadsNilOnceThenResolvesWhenTheRowIsFetchable() throws {
        let ownerID = UUID(), targetID = UUID()
        let owner = try fetchOwner(ownerRow(ownerID, target: targetID))
        let fetchesBefore = storeDelegate.fetchCount
        let target = try target(of: owner, fetchesBefore: fetchesBefore)

        // First load: the delegate cannot produce the destination row.
        storeDelegate.nextRows = []
        XCTAssertNil(target.value(forKey: "identifier"), "an unloadable destination reads as nil for this read")
        XCTAssertEqual(storeDelegate.fetchCount - fetchesBefore, 1)
        XCTAssertTrue(target.isFault, "the failed load must leave the destination a fault")

        // The row is there now: the next read goes back to the store.
        storeDelegate.nextRows = [ targetRow(targetID) ]
        XCTAssertEqual(target.value(forKey: "identifier") as? UUID, targetID)
        XCTAssertEqual(storeDelegate.fetchCount - fetchesBefore, 2, "the next access must fetch through the delegate again")
        XCTAssertFalse(target.isFault)

        // Loaded: served from the snapshot from now on.
        _ = target.value(forKey: "identifier")
        XCTAssertEqual(storeDelegate.fetchCount - fetchesBefore, 2)
    }

    func testDelegateErrorReadsNilOnceThenResolvesOnTheNextRead() throws {
        let ownerID = UUID(), targetID = UUID()
        let owner = try fetchOwner(ownerRow(ownerID, target: targetID))
        let fetchesBefore = storeDelegate.fetchCount
        let target = try target(of: owner, fetchesBefore: fetchesBefore)

        // The delegate request itself fails (DB error, timeout...).
        storeDelegate.nextRows = [ targetRow(targetID) ]
        storeDelegate.nextError = MockDelegateError()
        XCTAssertNil(target.value(forKey: "identifier"), "a failed delegate request reads as nil for this read")
        XCTAssertEqual(storeDelegate.fetchCount - fetchesBefore, 1)
        XCTAssertTrue(target.isFault)

        // Healthy again: the same read resolves.
        XCTAssertEqual(target.value(forKey: "identifier") as? UUID, targetID)
        XCTAssertEqual(storeDelegate.fetchCount - fetchesBefore, 2)
        XCTAssertFalse(target.isFault)
    }

    func testNilRelationshipIsResolvedOnceAndNeverRefetched() throws {
        let owner = try fetchOwner(ownerRow(UUID()))
        let fetchesBefore = storeDelegate.fetchCount

        XCTAssertNil(owner.value(forKey: "target"))
        XCTAssertEqual(storeDelegate.fetchCount, fetchesBefore, "a nil to-one needs no delegate fetch")
        XCTAssertFalse(owner.hasFault(forRelationshipNamed: "target"), "a genuine nil is an answer, not a failure")

        XCTAssertNil(owner.value(forKey: "target"))
        XCTAssertEqual(storeDelegate.fetchCount, fetchesBefore, "a genuine nil must not be re-asked")
    }
}

#endif
