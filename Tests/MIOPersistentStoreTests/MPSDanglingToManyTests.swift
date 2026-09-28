//
//  MPSDanglingToManyTests.swift
//  MIOPersistentStoreTests
//
//  A to-many list can hold the ID of a row that no longer exists (a hard
//  delete that did not clean every list). The member fetch succeeds and simply
//  does not return that row. Before this was pinned the store threw
//  identifierIsNull for the whole relationship: the list read as empty, and
//  every add or remove on it was refused (MIOCoreData relationshipNotLoaded)
//  — or, before that guard, saved "add x, remove every member".
//
//  Contract pinned here:
//  - a dangling member is left out; the live members read normally and the
//    relationship is resolved
//  - a member fetch that FAILS still throws (the relationship stays faulted
//    and the next access retries)
//  - after such a read, a change to the list saves, and the store's stored
//    IDs still hold the dangling one, so the save's diff removes it
//

#if !APPLE_CORE_DATA

import XCTest
import Foundation
import MIOCore
import MIOCoreData
@testable import MIOPersistentStore

// MARK: - Test model (self-contained copy — do not share across test files)

private let danglingModelXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<model type="com.apple.IDECoreDataModeler.DataModel" documentVersion="1.0">
    <entity name="DanglingOwnerEntity" representedClassName="DanglingOwnerEntity" syncable="YES">
        <attribute name="identifier" attributeType="UUID"/>
        <relationship name="members" optional="YES" toMany="YES" deletionRule="Nullify" destinationEntity="DanglingMemberEntity" inverseName="owner" inverseEntity="DanglingMemberEntity"/>
    </entity>
    <entity name="DanglingMemberEntity" representedClassName="DanglingMemberEntity" syncable="YES">
        <attribute name="identifier" attributeType="UUID"/>
        <relationship name="owner" optional="YES" maxCount="1" deletionRule="Nullify" destinationEntity="DanglingOwnerEntity" inverseName="members" inverseEntity="DanglingOwnerEntity"/>
    </entity>
</model>
"""

class DanglingOwnerEntity: MIOCoreData.NSManagedObject {}
class DanglingMemberEntity: MIOCoreData.NSManagedObject {}

private func MPSDanglingTestModel() -> MIOCoreData.NSManagedObjectModel
{
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MPSDanglingTestModel-\(ProcessInfo.processInfo.processIdentifier).xml")
    if FileManager.default.fileExists(atPath: url.path) == false {
        try! danglingModelXML.data(using: .utf8)!.write(to: url)
    }
    return MIOCoreData.NSManagedObjectModel(contentsOf: url)!
}

// MARK: - Delegate mock

fileprivate struct DanglingDelegateError: Error {}

fileprivate class DanglingFetchRequest: MPSFetchRequest
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

fileprivate class DanglingStoreDelegate: NSObject, MIOPersistentStoreDelegate
{
    /// Rows the next fetch request will return.
    var nextRows: [[String:Any]] = []
    /// Thrown by the next fetch request's execute(), then cleared.
    var nextError: Error? = nil
    var saveRequests = 0

    func store(store: MIOPersistentStore, fetchRequest: MIOCoreData.NSFetchRequest<MIOCoreData.NSManagedObject>, identifier: UUID?) -> MPSRequest? {
        let error = nextError
        nextError = nil
        return DanglingFetchRequest(entity: fetchRequest.entity!, rows: nextRows, error: error)
    }

    func store(store: MIOPersistentStore, saveRequest: MIOCoreData.NSSaveChangesRequest) -> MPSRequest? {
        saveRequests += 1
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

final class MPSDanglingToManyTests: XCTestCase
{
    fileprivate var container: MIOCoreData.NSPersistentContainer!
    fileprivate var store: MIOPersistentStore!
    fileprivate var storeDelegate: DanglingStoreDelegate!
    fileprivate var moc: MIOCoreData.NSManagedObjectContext!

    override func setUp() {
        super.setUp()

        MIOCoreData.NSPersistentStoreCoordinator.registerStoreClass(MIOPersistentStore.self, forStoreType: MIOPersistentStore.storeType)
        _MIOCoreRegisterClass(type: DanglingOwnerEntity.self, forKey: "DanglingOwnerEntity")
        _MIOCoreRegisterClass(type: DanglingMemberEntity.self, forKey: "DanglingMemberEntity")

        let description = MIOCoreData.NSPersistentStoreDescription(url: URL(string: "mps-dangling-test://\(UUID().uuidString)")!)
        description.type = MIOPersistentStore.storeType

        container = MIOCoreData.NSPersistentContainer(name: "DanglingTestDB", managedObjectModel: MPSDanglingTestModel())
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in
            if let error = error { fatalError("Store failed to load: \(error)") }
        }

        store = (container.persistentStoreCoordinator.persistentStores[0] as! MIOPersistentStore)
        storeDelegate = DanglingStoreDelegate()
        store.delegate = storeDelegate
        moc = container.viewContext
    }

    // MARK: Helpers

    private func ownerRow(_ id: UUID, members: [UUID]) -> [String:Any] {
        return [ "classname": "DanglingOwnerEntity", "identifier": id.uuidString, "members": members.map { $0.uuidString }, "version": 1 ]
    }

    private func memberRow(_ id: UUID) -> [String:Any] {
        return [ "classname": "DanglingMemberEntity", "identifier": id.uuidString, "version": 1 ]
    }

    /// Fetches rows through the store and materializes them, like a context fetch.
    private func fetch(_ entityName: String, _ rows: [[String:Any]]) throws -> [MIOCoreData.NSManagedObject] {
        storeDelegate.nextRows = rows
        let request = MIOCoreData.NSFetchRequest<MIOCoreData.NSManagedObject>(entityName: entityName)
        request.entity = container.managedObjectModel.entitiesByName[entityName]
        request.resultType = .managedObjectResultType
        return try store.fetchObjects(fetchRequest: request, with: moc) as! [MIOCoreData.NSManagedObject]
    }

    private func ids(_ value: Any?) -> Set<UUID> {
        let members = value as? Set<MIOCoreData.NSManagedObject> ?? []
        return Set( members.compactMap { $0.value(forKey: "identifier") as? UUID } )
    }

    // MARK: Tests

    func testDanglingMemberIsLeftOutAndTheListReads() throws {
        let live1 = UUID(), dead = UUID(), live2 = UUID()
        let owner = try fetch("DanglingOwnerEntity", [ ownerRow(UUID(), members: [live1, dead, live2]) ])[0]

        // The member fetch succeeds and does not return the dead row
        storeDelegate.nextRows = [ memberRow(live1), memberRow(live2) ]
        XCTAssertEqual( ids(owner.value(forKey: "members")), [live1, live2] )
        XCTAssertFalse( owner.hasFault(forRelationshipNamed: "members"), "the list is resolved, not a failed read" )
    }

    func testEveryMemberDanglingReadsAsAnEmptyResolvedList() throws {
        let owner = try fetch("DanglingOwnerEntity", [ ownerRow(UUID(), members: [UUID(), UUID()]) ])[0]

        storeDelegate.nextRows = []
        XCTAssertEqual( ids(owner.value(forKey: "members")), [] )
        XCTAssertFalse( owner.hasFault(forRelationshipNamed: "members") )
    }

    func testFailedMemberFetchStillThrowsAndIsRetried() throws {
        let live = UUID()
        let owner = try fetch("DanglingOwnerEntity", [ ownerRow(UUID(), members: [live]) ])[0]

        storeDelegate.nextRows = [ memberRow(live) ]
        storeDelegate.nextError = DanglingDelegateError()
        XCTAssertEqual( ids(owner.value(forKey: "members")), [], "a failed fetch reads empty for this read" )
        XCTAssertTrue( owner.hasFault(forRelationshipNamed: "members"), "a failed fetch is not an answer: it stays faulted" )

        XCTAssertEqual( ids(owner.value(forKey: "members")), [live], "the next access fetches again" )
    }

    func testChangingAListThatHeldADanglingMemberSavesAndLetsTheDiffDropIt() throws {
        let live = UUID(), dead = UUID(), added = UUID()
        let owner = try fetch("DanglingOwnerEntity", [ ownerRow(UUID(), members: [live, dead]) ])[0]
        let newMember = try fetch("DanglingMemberEntity", [ memberRow(added) ])[0]

        storeDelegate.nextRows = [ memberRow(live) ]
        owner._addObject(newMember, forKey: "members")

        let pending = owner.changedValues()["members"] as? Set<MIOCoreData.NSManagedObject?> ?? []
        XCTAssertEqual( Set( pending.compactMap { $0?.value(forKey: "identifier") as? UUID } ), [live, added] )

        // The save diffs the pending set against these: the dead ID lands on the remove side
        let relationship = owner.entity.relationshipsByName["members"]!
        let stored = try store.storedValues(forRelationship: relationship, forObjectWith: owner.objectID, with: moc) as? [UUID] ?? []
        XCTAssertEqual( Set(stored), [live, dead] )

        // The list was read, so MIOCoreData does not refuse the change (relationshipNotLoaded)
        XCTAssertNoThrow( try moc.save() )
        XCTAssertEqual( storeDelegate.saveRequests, 1 )
    }
}

#endif
