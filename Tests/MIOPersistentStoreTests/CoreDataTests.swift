//
//  CoreDataTests.swift
//
//
//  Created by Javier Segura Perez on 04/10/2020.
//
//  MIOPersistentStore must behave the same under Apple's Core Data and under
//  our own (MIOCoreData): these tests are one body compiled against either.
//  Objects are saved through the delegate into an in-memory "server" and read
//  back from it by a second store that has nothing cached.
//
//  Our Core Data:    swift test --filter CoreDataTests
//  Apple Core Data:  swift test -Xswiftc -DAPPLE_CORE_DATA --filter CoreDataTests
//

import XCTest
import Foundation

@testable import MIOPersistentStore

// MARK: - The Core Data in use

#if APPLE_CORE_DATA
import CoreData

typealias ManagedObject              = CoreData.NSManagedObject
typealias ManagedObjectContext       = CoreData.NSManagedObjectContext
typealias ManagedObjectModel         = CoreData.NSManagedObjectModel
typealias EntityDescription          = CoreData.NSEntityDescription
typealias FetchRequest               = CoreData.NSFetchRequest
typealias SaveChangesRequest         = CoreData.NSSaveChangesRequest
typealias PersistentContainer        = CoreData.NSPersistentContainer
typealias PersistentStoreCoordinator = CoreData.NSPersistentStoreCoordinator
typealias PersistentStoreDescription = CoreData.NSPersistentStoreDescription
typealias AttributeDescription       = CoreData.NSAttributeDescription
typealias RelationshipDescription    = CoreData.NSRelationshipDescription
typealias AttributeType              = CoreData.NSAttributeType
#else
import MIOCore
import MIOCoreData

typealias ManagedObject              = MIOCoreData.NSManagedObject
typealias ManagedObjectContext       = MIOCoreData.NSManagedObjectContext
typealias ManagedObjectModel         = MIOCoreData.NSManagedObjectModel
typealias EntityDescription          = MIOCoreData.NSEntityDescription
typealias FetchRequest               = MIOCoreData.NSFetchRequest
typealias SaveChangesRequest         = MIOCoreData.NSSaveChangesRequest
typealias PersistentContainer        = MIOCoreData.NSPersistentContainer
typealias PersistentStoreCoordinator = MIOCoreData.NSPersistentStoreCoordinator
typealias PersistentStoreDescription = MIOCoreData.NSPersistentStoreDescription
typealias AttributeDescription       = MIOCoreData.NSAttributeDescription
typealias RelationshipDescription    = MIOCoreData.NSRelationshipDescription
typealias AttributeType              = MIOCoreData.NSAttributeType
#endif

// MARK: - Model: the entities of TestModel.xcdatamodeld (Client, Document, DocumentLine)
// `swift test` does not compile .xcdatamodeld files, so each Core Data gets
// the same model the way it can load it: Apple built in code, ours parsed
// from the xcdatamodel XML.

#if APPLE_CORE_DATA

fileprivate func attribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
    let attr = NSAttributeDescription()
    attr.name = name
    attr.attributeType = type
    attr.isOptional = true
    return attr
}

fileprivate func relationship(_ name: String, to destination: NSEntityDescription, toMany: Bool) -> NSRelationshipDescription {
    let rel = NSRelationshipDescription()
    rel.name = name
    rel.destinationEntity = destination
    rel.minCount = 0
    rel.maxCount = toMany ? 0 : 1
    rel.isOptional = true
    rel.deleteRule = .nullifyDeleteRule
    return rel
}

fileprivate func entity(_ name: String) -> NSEntityDescription {
    let entity = NSEntityDescription()
    entity.name = name
    entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
    return entity
}

nonisolated(unsafe) fileprivate let testModel: ManagedObjectModel = {
    let client = entity("Client")
    let document = entity("Document")
    let line = entity("DocumentLine")

    let clientDocuments = relationship("documents", to: document, toMany: true)
    let documentClient  = relationship("client", to: client, toMany: false)
    clientDocuments.inverseRelationship = documentClient
    documentClient.inverseRelationship = clientDocuments

    let documentLines = relationship("lines", to: line, toMany: true)
    let lineDocument  = relationship("document", to: document, toMany: false)
    documentLines.inverseRelationship = lineDocument
    lineDocument.inverseRelationship = documentLines

    client.properties = [attribute("identifier", .UUIDAttributeType), attribute("name", .stringAttributeType),
                         attribute("phone", .stringAttributeType), clientDocuments]
    document.properties = [attribute("identifier", .UUIDAttributeType), attribute("name", .stringAttributeType),
                           documentClient, documentLines]
    line.properties = [attribute("identifier", .UUIDAttributeType), attribute("concept", .stringAttributeType),
                       attribute("quantity", .decimalAttributeType), lineDocument]

    let model = NSManagedObjectModel()
    model.entities = [client, document, line]
    return model
}()

#else

private let testModelXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<model type="com.apple.IDECoreDataModeler.DataModel" documentVersion="1.0">
    <entity name="Client" syncable="YES">
        <attribute name="identifier" optional="YES" attributeType="UUID" usesScalarValueType="NO"/>
        <attribute name="name" optional="YES" attributeType="String"/>
        <attribute name="phone" optional="YES" attributeType="String"/>
        <relationship name="documents" optional="YES" toMany="YES" deletionRule="Nullify" destinationEntity="Document" inverseName="client" inverseEntity="Document"/>
    </entity>
    <entity name="Document" syncable="YES">
        <attribute name="identifier" optional="YES" attributeType="UUID" usesScalarValueType="NO"/>
        <attribute name="name" optional="YES" attributeType="String"/>
        <relationship name="client" optional="YES" maxCount="1" deletionRule="Nullify" destinationEntity="Client" inverseName="documents" inverseEntity="Client"/>
        <relationship name="lines" optional="YES" toMany="YES" deletionRule="Nullify" destinationEntity="DocumentLine" inverseName="document" inverseEntity="DocumentLine"/>
    </entity>
    <entity name="DocumentLine" syncable="YES">
        <attribute name="concept" optional="YES" attributeType="String"/>
        <attribute name="identifier" optional="YES" attributeType="UUID" usesScalarValueType="NO"/>
        <attribute name="quantity" optional="YES" attributeType="Decimal" defaultValueString="0.0"/>
        <relationship name="document" optional="YES" maxCount="1" deletionRule="Nullify" destinationEntity="Document" inverseName="lines" inverseEntity="Document"/>
    </entity>
</model>
"""

// Our Core Data instantiates fetched objects through the class registry,
// by entity name
fileprivate final class ClientObject: ManagedObject {}
fileprivate final class DocumentObject: ManagedObject {}
fileprivate final class DocumentLineObject: ManagedObject {}

nonisolated(unsafe) fileprivate let testModel: ManagedObjectModel = {
    _MIOCoreRegisterClass(type: ClientObject.self, forKey: "Client")
    _MIOCoreRegisterClass(type: DocumentObject.self, forKey: "Document")
    _MIOCoreRegisterClass(type: DocumentLineObject.self, forKey: "DocumentLine")

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MPSDocumentModel-\(ProcessInfo.processInfo.processIdentifier).xml")
    try! testModelXML.data(using: .utf8)!.write(to: url)
    return ManagedObjectModel(contentsOf: url)!
}()

#endif


// MARK: - The "server": rows by entity name

fileprivate final class TestServer
{
    var itemsByEntity: [String: [[String:Any]]] = [:]
}

fileprivate class TestFetchRequest : MPSFetchRequest
{
    let server: TestServer
    let identifier: UUID?

    init(fetchRequest: FetchRequest<ManagedObject>, identifier: UUID?, server: TestServer) {
        self.server = server
        self.identifier = identifier
        super.init(fetchRequest: fetchRequest)
    }

    override func execute() throws {
        var rows = server.itemsByEntity[entityName] ?? []
        if let identifier {
            rows = rows.filter { $0["identifier"] as? String == identifier.uuidString.uppercased() }
        }
        // The tests only sort by one String attribute
        if let sort = sortDescriptors?.first, let key = sort.key {
            rows.sort {
                let a = $0[key] as? String ?? "", b = $1[key] as? String ?? ""
                return sort.ascending ? a < b : a > b
            }
        }
        resultItems = [ "entities": rows, "relationShipEntities": [] ]
    }
}

fileprivate class TestSaveRequest : MPSRequest
{
    let server: TestServer
    let insertedItems: [(entityName: String, values: [String:Any])]

    init(server: TestServer, insertedItems: [(entityName: String, values: [String:Any])]) {
        self.server = server
        self.insertedItems = insertedItems
    }

    override func execute() throws {
        for item in insertedItems {
            server.itemsByEntity[item.entityName, default: []].append(item.values)
        }
    }
}


final class CoreDataTests: XCTestCase, MIOPersistentStoreDelegate
{
    fileprivate var server: TestServer!
    /// Kept alive for the whole test: the context does not retain its container
    fileprivate var containers: [PersistentContainer] = []

    override func setUp() {
        super.setUp()
        server = TestServer()
        containers = []
    }

    /// A context on a new store, with nothing cached, talking to `server`
    fileprivate func newManagedObjectContext() -> ManagedObjectContext {
        PersistentStoreCoordinator.registerStoreClass(MIOPersistentStore.self, forStoreType: MIOPersistentStore.storeType)

        let description = PersistentStoreDescription(url: URL(string: "dltest://\(UUID().uuidString)")!)
        description.type = MIOPersistentStore.storeType

        let container = PersistentContainer(name: "TestDB", managedObjectModel: testModel)
        container.persistentStoreDescriptions = [description]

        container.loadPersistentStores(completionHandler: { (storeDescription, error) in
            if let error = error as NSError? {
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }
        })

        (container.persistentStoreCoordinator.persistentStores[0] as! MIOPersistentStore).delegate = self
        containers.append(container)

        return container.viewContext
    }

    //
    // MIO Persistent Store Delegate methods
    //

    func store(store: MIOPersistentStore, fetchRequest: FetchRequest<ManagedObject>, identifier: UUID?) -> MPSRequest? {
        return TestFetchRequest(fetchRequest: fetchRequest, identifier: identifier, server: server)
    }

    func store(store: MIOPersistentStore, saveRequest: SaveChangesRequest) -> MPSRequest? {
        let inserted = (saveRequest.insertedObjects ?? Set()).map {
            (entityName: $0.entity.name!, values: serializeValues(store, fromObject: $0))
        }
        return TestSaveRequest(server: server, insertedItems: inserted)
    }

    func store(store: MIOPersistentStore, identifierForObject object: ManagedObject) -> UUID? {
        return object.value(forKey: "identifier") as? UUID
    }

    func store(store: MIOPersistentStore, identifierFromItem item: [String : Any], fetchEntityName: String) -> UUID? {
        guard let identifier = item["identifier"] as? String else { return nil }
        return UUID(uuidString: identifier)
    }

    func store(store: MIOPersistentStore, versionFromItem item: [String : Any], fetchEntityName: String) -> UInt64 {
        return item["version"] as? UInt64 ?? 1
    }

    func serializeValues(_ store:MIOPersistentStore, fromObject object: ManagedObject, onlyChanges:Bool = true) -> [String:Any] {

        let objectValues = object.changedValues()

        var values:[String:Any] = [ "classname": object.entity.name! ]

        for p in object.entity.properties {

            if p is AttributeDescription {
                let attr = p as! AttributeDescription
                guard let value = objectValues[attr.name] else {
                    continue
                }

                values[attr.name] = parseValue(value: value, type: attr.attributeType)
            }
            else if p is RelationshipDescription {
                let rel = p as! RelationshipDescription

                if rel.isToMany == false {
                    guard let obj = objectValues[rel.name] as? ManagedObject else {
                        continue
                    }

                    if let identifier = obj.value(forKey: "identifier") as? UUID {
                        values[rel.name] = identifier.uuidString.uppercased( )
                    }
                }
                else {

                    guard let objects = objectValues[rel.name] as? Set<ManagedObject> else {
                        continue
                    }

                    var relationIDs:[String] = []
                    for obj in objects {
                        if let identifier = obj.value(forKey: "identifier") as? UUID {
                            relationIDs.append(identifier.uuidString.uppercased( ))
                        }
                    }

                    values[rel.name] = relationIDs
                }

            }
        }

        return values
    }

    func parseValue(value:Any, type:AttributeType) -> Any {

        switch type
        {
            case .UUIDAttributeType:
                return (value as! UUID).uuidString.uppercased( )

            case .dateAttributeType:
                return ISO8601DateFormatter().string(from: value as! Date)

            default:
                return value
        }
    }

    //
    // Helpers
    //

    @discardableResult
    fileprivate func insertDocument(name: String, into moc: ManagedObjectContext) -> ManagedObject {
        let doc = ManagedObject(entity: testModel.entitiesByName["Document"]!, insertInto: moc)
        doc.setValue(UUID(), forKey: "identifier")
        doc.setValue(name, forKey: "name")
        return doc
    }

    @discardableResult
    fileprivate func insertLine(concept: String, quantity: Decimal, document: ManagedObject, into moc: ManagedObjectContext) -> ManagedObject {
        let line = ManagedObject(entity: testModel.entitiesByName["DocumentLine"]!, insertInto: moc)
        line.setValue(UUID(), forKey: "identifier")
        line.setValue(concept, forKey: "concept")
        line.setValue(quantity as NSDecimalNumber, forKey: "quantity")
        line.setValue(document, forKey: "document")
        return line
    }

    //
    // Tests
    //

    func testCreateObject() throws {
        let moc = newManagedObjectContext()

        insertDocument(name: "001", into: moc)
        try moc.save()

        XCTAssertEqual(server.itemsByEntity.count, 1)
        XCTAssertEqual(server.itemsByEntity["Document"]?.count, 1)
        XCTAssertEqual(server.itemsByEntity["Document"]?.first?["name"] as? String, "001")
    }

    func testCreateObjectsWithRelationship() throws {
        let moc = newManagedObjectContext()

        let doc = insertDocument(name: "002", into: moc)
        let line = insertLine(concept: "Test Concept", quantity: 10, document: doc, into: moc)
        try moc.save()

        XCTAssertEqual(server.itemsByEntity.count, 2)
        XCTAssertEqual(server.itemsByEntity["Document"]?.count, 1)
        XCTAssertEqual(server.itemsByEntity["DocumentLine"]?.count, 1)

        let docID  = (doc.value(forKey: "identifier") as! UUID).uuidString
        let lineID = (line.value(forKey: "identifier") as! UUID).uuidString
        XCTAssertEqual(server.itemsByEntity["DocumentLine"]?.first?["document"] as? String, docID)
        XCTAssertEqual(server.itemsByEntity["Document"]?.first?["lines"] as? [String], [lineID])
    }

    func testFetchObject() throws {
        let writer = newManagedObjectContext()
        insertDocument(name: "001", into: writer)
        let doc = insertDocument(name: "002", into: writer)
        insertLine(concept: "Test Concept", quantity: 10, document: doc, into: writer)
        try writer.save()

        // A second store has nothing cached: everything it reads comes from the server
        let moc = newManagedObjectContext()

        let request = FetchRequest<ManagedObject>(entityName: "Document")
        request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]

        let objects = try moc.fetch(request)
        XCTAssertEqual(objects.count, 2)

        let doc1 = objects[0]
        XCTAssertEqual(doc1.value(forKey: "name") as? String, "001")

        let doc2 = objects[1]
        XCTAssertEqual(doc2.value(forKey: "name") as? String, "002")

        let lines = doc2.value(forKey: "lines") as? Set<ManagedObject>
        XCTAssertEqual(lines?.count, 1)

        let line = try XCTUnwrap(lines?.first)
        XCTAssertEqual(line.value(forKey: "concept") as? String, "Test Concept")
        XCTAssertEqual(line.value(forKey: "quantity") as? NSDecimalNumber, 10)
        XCTAssertEqual((line.value(forKey: "document") as? ManagedObject)?.objectID, doc2.objectID)
    }
}

