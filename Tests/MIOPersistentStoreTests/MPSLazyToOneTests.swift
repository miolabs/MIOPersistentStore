//
//  MPSLazyToOneTests.swift
//  MIOPersistentStoreTests
//
//  A to-one resolves to the destination's object ID and nothing else, under
//  both Core Datas. The row is fetched when something reads the destination.
//
//  The store used to fetch the destination row to answer the relationship.
//  Apple's Core Data asks for every to-one of an object when its fault fires,
//  so that fetch materialized the destination, which fired the destination's
//  fault, which asked for ITS to-ones, and so on: reading one attribute of N
//  objects cost one delegate request per object of the whole to-one graph (a
//  list of licenses pulled every client, address and phone number, one
//  request each). Under our own Core Data it cost one request per to-one
//  read, used or not.
//
//  A destination entity with subentities needs its concrete class to be
//  handed out as an object. The owner's row says it ("<name>.classname"), so
//  that one is lazy too. Only when the row does not say it is the
//  destination fetched to find out.
//
//  One body compiled against either Core Data (typealiases in CoreDataTests.swift):
//  Our Core Data:    swift test --filter MPSLazyToOneTests
//  Apple Core Data:  swift test -Xswiftc -DAPPLE_CORE_DATA --filter MPSLazyToOneTests
//

import XCTest
import Foundation
@testable import MIOPersistentStore

// MARK: - Model: Owner -> Target -> Leaf, Owner -> Shape (abstract parent of Circle), Owner ->> Leaf (items)

#if APPLE_CORE_DATA
import CoreData

private func attribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
    let attr = NSAttributeDescription()
    attr.name = name
    attr.attributeType = type
    attr.isOptional = true
    return attr
}

private func toOne(_ name: String, _ destination: NSEntityDescription) -> NSRelationshipDescription {
    let rel = NSRelationshipDescription()
    rel.name = name
    rel.destinationEntity = destination
    rel.minCount = 0
    rel.maxCount = 1
    rel.isOptional = true
    rel.deleteRule = .nullifyDeleteRule
    return rel
}

private func entity(_ name: String) -> NSEntityDescription {
    let entity = NSEntityDescription()
    entity.name = name
    entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
    return entity
}

nonisolated(unsafe) private let lazyToOneModel: ManagedObjectModel = {
    let leaf = entity("LazyLeaf")
    leaf.properties = [attribute("identifier", .UUIDAttributeType), attribute("name", .stringAttributeType)]

    let target = entity("LazyTarget")
    target.properties = [attribute("identifier", .UUIDAttributeType), attribute("name", .stringAttributeType),
                         toOne("leaf", leaf)]

    let shape = entity("LazyShape")
    shape.isAbstract = true
    shape.properties = [attribute("identifier", .UUIDAttributeType), attribute("name", .stringAttributeType)]
    let circle = entity("LazyCircle")
    shape.subentities = [circle]

    let items = toOne("items", leaf)
    items.maxCount = 0

    let owner = entity("LazyOwner")
    owner.properties = [attribute("identifier", .UUIDAttributeType), attribute("name", .stringAttributeType),
                        toOne("target", target), toOne("shape", shape), items]

    let model = NSManagedObjectModel()
    model.entities = [owner, target, leaf, shape, circle]
    return model
}()

#else
import MIOCore
import MIOCoreData

private let lazyToOneModelXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<model type="com.apple.IDECoreDataModeler.DataModel" documentVersion="1.0">
    <entity name="LazyOwner" syncable="YES">
        <attribute name="identifier" optional="YES" attributeType="UUID"/>
        <attribute name="name" optional="YES" attributeType="String"/>
        <relationship name="target" optional="YES" maxCount="1" deletionRule="Nullify" destinationEntity="LazyTarget"/>
        <relationship name="shape" optional="YES" maxCount="1" deletionRule="Nullify" destinationEntity="LazyShape"/>
        <relationship name="items" optional="YES" toMany="YES" deletionRule="Nullify" destinationEntity="LazyLeaf"/>
    </entity>
    <entity name="LazyTarget" syncable="YES">
        <attribute name="identifier" optional="YES" attributeType="UUID"/>
        <attribute name="name" optional="YES" attributeType="String"/>
        <relationship name="leaf" optional="YES" maxCount="1" deletionRule="Nullify" destinationEntity="LazyLeaf"/>
    </entity>
    <entity name="LazyLeaf" syncable="YES">
        <attribute name="identifier" optional="YES" attributeType="UUID"/>
        <attribute name="name" optional="YES" attributeType="String"/>
    </entity>
    <entity name="LazyShape" isAbstract="YES" syncable="YES">
        <attribute name="identifier" optional="YES" attributeType="UUID"/>
        <attribute name="name" optional="YES" attributeType="String"/>
    </entity>
    <entity name="LazyCircle" parentEntity="LazyShape" syncable="YES"/>
</model>
"""

// Our Core Data instantiates fetched objects through the class registry,
// by entity name
fileprivate final class LazyOwnerObject: ManagedObject {}
fileprivate final class LazyTargetObject: ManagedObject {}
fileprivate final class LazyLeafObject: ManagedObject {}
fileprivate class LazyShapeObject: ManagedObject {}
fileprivate final class LazyCircleObject: LazyShapeObject {}

nonisolated(unsafe) private let lazyToOneModel: ManagedObjectModel = {
    _MIOCoreRegisterClass(type: LazyOwnerObject.self, forKey: "LazyOwner")
    _MIOCoreRegisterClass(type: LazyTargetObject.self, forKey: "LazyTarget")
    _MIOCoreRegisterClass(type: LazyLeafObject.self, forKey: "LazyLeaf")
    _MIOCoreRegisterClass(type: LazyShapeObject.self, forKey: "LazyShape")
    _MIOCoreRegisterClass(type: LazyCircleObject.self, forKey: "LazyCircle")

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MPSLazyToOneModel-\(ProcessInfo.processInfo.processIdentifier).xml")
    try! lazyToOneModelXML.data(using: .utf8)!.write(to: url)
    return ManagedObjectModel(contentsOf: url)!
}()

#endif

// MARK: - Delegate mock

fileprivate struct RowsDelegateError: Error {}

fileprivate class RowsFetchRequest: MPSFetchRequest
{
    let rows: [[String:Any]]
    let error: Error?

    init(fetchRequest: FetchRequest<ManagedObject>, rows: [[String:Any]], error: Error?) {
        self.rows = rows
        self.error = error
        super.init(fetchRequest: fetchRequest)
    }

    override func execute() throws {
        if let error { throw error }
        resultItems = [ "entities": rows, "relationShipEntities": [] ]
    }
}

fileprivate class RowsDelegate: NSObject, MIOPersistentStoreDelegate
{
    /// Rows a fetch of each entity returns
    var rows: [String: [[String:Any]]] = [:]
    /// Delegate fetches per entity name
    var fetchCount: [String: Int] = [:]
    /// Thrown by the next fetch request's execute(), then cleared
    var nextError: Error? = nil

    func store(store: MIOPersistentStore, fetchRequest: FetchRequest<ManagedObject>, identifier: UUID?) -> MPSRequest? {
        let name = fetchRequest.entityName!
        fetchCount[name, default: 0] += 1
        let error = nextError
        nextError = nil
        return RowsFetchRequest(fetchRequest: fetchRequest, rows: rows[name] ?? [], error: error)
    }

    func store(store: MIOPersistentStore, saveRequest: SaveChangesRequest) -> MPSRequest? {
        return MPSRequest()
    }

    func store(store: MIOPersistentStore, identifierForObject object: ManagedObject) -> UUID? {
        return object.value(forKey: "identifier") as? UUID
    }

    func store(store: MIOPersistentStore, identifierFromItem item: [String:Any], fetchEntityName: String) -> UUID? {
        return UUID(uuidString: item["identifier"] as! String)
    }

    func store(store: MIOPersistentStore, versionFromItem item: [String:Any], fetchEntityName: String) -> UInt64 {
        return 1
    }
}

// MARK: - Tests

final class MPSLazyToOneTests: XCTestCase
{
    fileprivate var container: PersistentContainer!
    fileprivate var delegate: RowsDelegate!
    fileprivate var moc: ManagedObjectContext!

    override func setUp() {
        super.setUp()

        PersistentStoreCoordinator.registerStoreClass(MIOPersistentStore.self, forStoreType: MIOPersistentStore.storeType)

        let description = PersistentStoreDescription(url: URL(string: "mps-lazy-to-one://\(UUID().uuidString)")!)
        description.type = MIOPersistentStore.storeType

        container = PersistentContainer(name: "LazyToOneDB", managedObjectModel: lazyToOneModel)
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in
            if let error = error { fatalError("Store failed to load: \(error)") }
        }

        delegate = RowsDelegate()
        (container.persistentStoreCoordinator.persistentStores[0] as! MIOPersistentStore).delegate = delegate
        moc = container.viewContext
    }

    private func row(_ classname: String, _ id: UUID, name: String, _ extra: [String:Any] = [:]) -> [String:Any] {
        var row: [String:Any] = [ "classname": classname, "identifier": id.uuidString, "name": name ]
        row.merge(extra) { _, new in new }
        return row
    }

    private func fetchOwners() throws -> [ManagedObject] {
        return try moc.fetch(FetchRequest<ManagedObject>(entityName: "LazyOwner"))
    }

    func testReadingAttributesDoesNotFetchToOneDestinations() throws {
        let targetA = UUID(), targetB = UUID(), leaf = UUID()
        delegate.rows["LazyOwner"] = [
            row("LazyOwner", UUID(), name: "a", ["target": targetA.uuidString]),
            row("LazyOwner", UUID(), name: "b", ["target": targetB.uuidString]),
        ]
        delegate.rows["LazyTarget"] = [
            row("LazyTarget", targetA, name: "ta", ["leaf": leaf.uuidString]),
            row("LazyTarget", targetB, name: "tb", ["leaf": leaf.uuidString]),
        ]
        delegate.rows["LazyLeaf"] = [ row("LazyLeaf", leaf, name: "leaf") ]

        let owners = try fetchOwners()
        XCTAssertEqual(Set(owners.compactMap { $0.value(forKey: "name") as? String }), ["a", "b"])

        XCTAssertEqual(delegate.fetchCount["LazyOwner"], 1)
        XCTAssertNil(delegate.fetchCount["LazyTarget"], "reading an owner's attributes must not fetch its to-one destination")
        XCTAssertNil(delegate.fetchCount["LazyLeaf"], "nor the destination's own to-ones")
    }

    func testDestinationIsFetchedWhenItIsRead() throws {
        let targetID = UUID(), leafID = UUID()
        delegate.rows["LazyOwner"]  = [ row("LazyOwner", UUID(), name: "a", ["target": targetID.uuidString]) ]
        delegate.rows["LazyTarget"] = [ row("LazyTarget", targetID, name: "ta", ["leaf": leafID.uuidString]) ]
        delegate.rows["LazyLeaf"]   = [ row("LazyLeaf", leafID, name: "leaf") ]

        let owner = try fetchOwners()[0]
        let target = owner.value(forKey: "target") as? ManagedObject
        // Not XCTAssertNotNil: it describes the object, and our Core Data's description reads its attributes
        XCTAssertTrue(target != nil)
        XCTAssertNil(delegate.fetchCount["LazyTarget"], "holding the destination is not reading it")

        XCTAssertEqual(target?.value(forKey: "name") as? String, "ta")
        XCTAssertEqual(delegate.fetchCount["LazyTarget"], 1)
        XCTAssertNil(delegate.fetchCount["LazyLeaf"], "the destination's to-ones stay unfetched too")

        let leaf = target?.value(forKey: "leaf") as? ManagedObject
        XCTAssertEqual(leaf?.value(forKey: "name") as? String, "leaf")
        XCTAssertEqual(delegate.fetchCount["LazyLeaf"], 1)
    }

    func testNilToOneReadsNilWithoutFetching() throws {
        delegate.rows["LazyOwner"] = [ row("LazyOwner", UUID(), name: "a") ]

        let owner = try fetchOwners()[0]
        XCTAssertNil(owner.value(forKey: "target"))
        XCTAssertNil(delegate.fetchCount["LazyTarget"])
    }

    func testDestinationWithSubentitiesKeepsItsConcreteClass() throws {
        let circleID = UUID()
        delegate.rows["LazyOwner"] = [ row("LazyOwner", UUID(), name: "a", ["shape": circleID.uuidString]) ]
        delegate.rows["LazyShape"] = [ row("LazyCircle", circleID, name: "round") ]

        let owner = try fetchOwners()[0]
        let shape = owner.value(forKey: "shape") as? ManagedObject
        XCTAssertEqual(shape?.entity.name, "LazyCircle", "the concrete entity comes from the row")
        XCTAssertEqual(shape?.value(forKey: "name") as? String, "round")
    }

    // MARK: A destination with subentities, its class declared by the owner's row

    private func shapeRelationship() -> RelationshipDescription {
        return lazyToOneModel.entitiesByName["LazyOwner"]!.relationshipsByName["shape"]!
    }

    func testDestinationWithSubentitiesIsLazyWhenTheRowSaysItsClass() throws {
        let circleID = UUID()
        delegate.rows["LazyOwner"]  = [ row("LazyOwner", UUID(), name: "a", ["shape": circleID.uuidString, "shape.classname": "LazyCircle"]) ]
        delegate.rows["LazyCircle"] = [ row("LazyCircle", circleID, name: "round") ]

        let owner = try fetchOwners()[0]
        XCTAssertEqual(owner.value(forKey: "name") as? String, "a")
        let shape = try XCTUnwrap(owner.value(forKey: "shape") as? ManagedObject)
        XCTAssertEqual(shape.entity.name, "LazyCircle", "the concrete entity comes from the owner's row")
        XCTAssertNil(delegate.fetchCount["LazyShape"], "nothing is fetched to find out the class")
        XCTAssertNil(delegate.fetchCount["LazyCircle"], "holding the destination is not reading it")

        XCTAssertEqual(shape.value(forKey: "name") as? String, "round")
        XCTAssertEqual(delegate.fetchCount["LazyCircle"], 1)
        XCTAssertNil(delegate.fetchCount["LazyShape"])
    }

    func testDeclaredClassThatIsNotADestinationIsIgnored() throws {
        let circleID = UUID()
        // LazyLeaf is not LazyShape nor one of its subentities
        delegate.rows["LazyOwner"] = [ row("LazyOwner", UUID(), name: "a", ["shape": circleID.uuidString, "shape.classname": "LazyLeaf"]) ]
        delegate.rows["LazyShape"] = [ row("LazyCircle", circleID, name: "round") ]

        let owner = try fetchOwners()[0]
        let shape = owner.value(forKey: "shape") as? ManagedObject
        XCTAssertEqual(shape?.entity.name, "LazyCircle", "the destination is fetched to find out, as when the row says nothing")
        XCTAssertEqual(delegate.fetchCount["LazyShape"], 1)
    }

    func testMissingDestinationWithDeclaredClassFailsLikeAnyOtherDestination() throws {
        let circleID = UUID()
        delegate.rows["LazyOwner"] = [ row("LazyOwner", UUID(), name: "a", ["shape": circleID.uuidString, "shape.classname": "LazyCircle"]) ]

        let owner = try fetchOwners()[0]
        let shape = try XCTUnwrap(owner.value(forKey: "shape") as? ManagedObject)

        XCTAssertNil(shape.value(forKey: "name"), "an unloadable destination reads as nil for this read")
        XCTAssertEqual(delegate.fetchCount["LazyCircle"], 1)
        settle()
        XCTAssertTrue(shape.isFault, "the failed load must leave the destination a fault")
        XCTAssertFalse(shape.isDeleted)

        delegate.rows["LazyCircle"] = [ row("LazyCircle", circleID, name: "round") ]
        XCTAssertEqual(shape.value(forKey: "name") as? String, "round")
        XCTAssertEqual(delegate.fetchCount["LazyCircle"], 2)
        XCTAssertFalse(shape.isFault)
    }

    func testSavingANewDestinationForgetsTheDeclaredClassOfTheOldOne() throws {
        let oldID = UUID(), newID = UUID()
        delegate.rows["LazyOwner"] = [ row("LazyOwner", UUID(), name: "a", ["shape": oldID.uuidString, "shape.classname": "LazyCircle"]) ]
        let owner = try fetchOwners()[0]
        XCTAssertEqual(owner.value(forKey: "name") as? String, "a")

        let replacement = ManagedObject(entity: lazyToOneModel.entitiesByName["LazyCircle"]!, insertInto: moc)
        replacement.setValue(newID, forKey: "identifier")
        replacement.setValue("new", forKey: "name")
        owner.setValue(replacement, forKey: "shape")
        try moc.save()

        // The save handed the store an object, not a row: the class the row
        // declared belonged to the old destination and no longer applies
        let store = container.persistentStoreCoordinator.persistentStores[0] as! MIOPersistentStore
        let node = try XCTUnwrap(store.cacheNode(withIdentifier: owner.value(forKey: "identifier") as! UUID, entity: owner.entity))
        XCTAssertNil(node.destinationEntity(forRelationship: shapeRelationship()))
    }

    // MARK: A destination that cannot be loaded
    //
    // Same failure under both Core Datas: the read is nil for that read only,
    // the destination stays a fault, and the next read goes back to the
    // delegate. Never a hollow object that reads nil for good, never an
    // exception.

    /// Our Core Data leaves the object a fault on the failed read itself.
    /// Apple's cannot, so the store turns it back into one on the context's
    /// queue: let that run.
    private func settle() {
        #if APPLE_CORE_DATA
        let settled = expectation(description: "context queue drained")
        moc.perform { settled.fulfill() }
        wait(for: [settled], timeout: 1)
        #endif
    }

    private func ownerWithTarget(_ targetID: UUID) throws -> ManagedObject {
        delegate.rows["LazyOwner"] = [ row("LazyOwner", UUID(), name: "a", ["target": targetID.uuidString]) ]
        let owner = try fetchOwners()[0]
        return try XCTUnwrap(owner.value(forKey: "target") as? ManagedObject)
    }

    func testMissingDestinationRowReadsNilOnceThenLoadsWhenTheRowIsThere() throws {
        let targetID = UUID()
        let target = try ownerWithTarget(targetID)

        // The link points at a row the server does not have
        XCTAssertNil(target.value(forKey: "name"), "an unloadable destination reads as nil for this read")
        XCTAssertEqual(delegate.fetchCount["LazyTarget"], 1)
        settle()
        XCTAssertTrue(target.isFault, "the failed load must leave the destination a fault")
        XCTAssertFalse(target.isDeleted)

        // The row is there now: the next read goes back to the delegate
        delegate.rows["LazyTarget"] = [ row("LazyTarget", targetID, name: "ta") ]
        XCTAssertEqual(target.value(forKey: "name") as? String, "ta")
        XCTAssertEqual(delegate.fetchCount["LazyTarget"], 2)
        XCTAssertFalse(target.isFault)

        // Loaded: no further fetch
        settle()
        XCTAssertEqual(target.value(forKey: "name") as? String, "ta")
        XCTAssertEqual(delegate.fetchCount["LazyTarget"], 2)
    }

    func testFailedRequestReadsNilOnceThenLoadsOnTheNextRead() throws {
        let targetID = UUID()
        let target = try ownerWithTarget(targetID)
        delegate.rows["LazyTarget"] = [ row("LazyTarget", targetID, name: "ta") ]

        // The delegate request itself fails (network, DB error, timeout...)
        delegate.nextError = RowsDelegateError()
        XCTAssertNil(target.value(forKey: "name"), "a failed request reads as nil for this read")
        XCTAssertEqual(delegate.fetchCount["LazyTarget"], 1)
        settle()
        XCTAssertTrue(target.isFault)
        XCTAssertFalse(target.isDeleted)

        // Healthy again: the same read loads it
        XCTAssertEqual(target.value(forKey: "name") as? String, "ta")
        XCTAssertEqual(delegate.fetchCount["LazyTarget"], 2)
        XCTAssertFalse(target.isFault)
    }

    // MARK: A to-many whose members cannot be fetched
    //
    // Same under both Core Datas: empty for that read, the relationship
    // stays a fault, the next read fetches again.

    private func count(_ value: Any?) -> Int? {
        if let set = value as? Set<ManagedObject> { return set.count }
        return (value as? NSSet)?.count
    }

    func testFailedToManyFetchReadsEmptyOnceThenLoadsOnTheNextRead() throws {
        let leafID = UUID()
        delegate.rows["LazyOwner"] = [ row("LazyOwner", UUID(), name: "a", ["items": [leafID.uuidString]]) ]
        delegate.rows["LazyLeaf"]  = [ row("LazyLeaf", leafID, name: "leaf") ]
        let owner = try fetchOwners()[0]
        XCTAssertEqual(owner.value(forKey: "name") as? String, "a")
        XCTAssertNil(delegate.fetchCount["LazyLeaf"], "members are fetched when the list is read")

        delegate.nextError = RowsDelegateError()
        XCTAssertEqual(count(owner.value(forKey: "items")), 0, "a failed fetch reads empty for this read")
        XCTAssertEqual(delegate.fetchCount["LazyLeaf"], 1)
        settle()
        XCTAssertTrue(owner.hasFault(forRelationshipNamed: "items"), "a failed fetch is not an answer: it stays faulted")

        XCTAssertEqual(count(owner.value(forKey: "items")), 1, "the next read fetches again")
        XCTAssertEqual(delegate.fetchCount["LazyLeaf"], 2)
    }
}
