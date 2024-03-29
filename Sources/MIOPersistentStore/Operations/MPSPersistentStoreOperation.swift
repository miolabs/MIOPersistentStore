//
//  MWSPersistentStoreOperation.swift
//  
//
//  Created by Javier Segura Perez on 24/09/2020.
//

import Foundation

import MIOCore
#if APPLE_CORE_DATA
import CoreData
#else
import MIOCoreData
#endif


enum MPSError : Error
{
    case invalidType(_ key:String, _ value:Any?, _ functionName: String = #function)
}

extension MPSError: LocalizedError
{
    public var errorDescription: String? {
        switch self {
        case let .invalidType(key, value, functionName):
            return "[MIOPersistentStore] Received Invalid value \(value ?? "null") for key \(key)"
        }
    }
}


class MPSPersistentStoreOperation: Operation
{
    private var _identifier:String!
    var identifier:String {
        get { return _identifier }
    }
    
    var store:MIOPersistentStore
    weak var moc: NSManagedObjectContext?
    
    //TODO:Check
    public var dbTableName : String { return "" } //request.tableName }
    
    var request:MPSRequest
    var entity:NSEntityDescription
    var relationshipKeyPathsForPrefetching:[String]
    var serverID:String?
        
    var saveCount = 0
    var dependencyIDs:[String] = []
    
    var responseResult = false
    var responseCode:Int = 0
    var responseData:Any?
    var responseError:Error?
            
    var objectIDs = [NSManagedObjectID]()
    var insertedObjectIDs = [NSManagedObjectID]()
    var updatedObjectIDs = [NSManagedObjectID]()
    var deletedObjectIDs = [NSManagedObjectID]()
    
    var requestCount = 0
    
    private var _uploading = false;
    var uploading:Bool {
        set {
            willChangeValue(forKey: "isExecuting")
            _uploading = newValue
            didChangeValue(forKey: "isExecuting")
        }
        get {
            return _uploading
        }
    }

    private var _uploaded = false;
    var uploaded:Bool {
        set {
            willChangeValue(forKey: "isFinished")
            _uploaded = newValue
            didChangeValue(forKey: "isFinished")
        }
        get {
            return _uploaded
        }
    }
    
    override func cancel() {
        willChangeValue(forKey: "isFinished")
        super.cancel()
        didChangeValue(forKey: "isFinished")
    }
        
    init(store:MIOPersistentStore, request:MPSRequest, entity:NSEntityDescription, relationshipKeyPathsForPrefetching:[String]?, identifier:String?) {
        _identifier = identifier ?? UUID().uuidString.uppercased()
        self.store = store
        self.request = request
        self.entity = entity
        self.relationshipKeyPathsForPrefetching = relationshipKeyPathsForPrefetching ?? [String]()
        super.init()
    }
    
    convenience init(store:MIOPersistentStore, request:MPSRequest, entity:NSEntityDescription, relationshipKeyPathsForPrefetching:[String]?) {
        self.init(store: store, request: request, entity: entity, relationshipKeyPathsForPrefetching: relationshipKeyPathsForPrefetching, identifier: nil)
    }
    
    override func start() {
        
        assert(self.uploading == false, "MWSPersistenStoreUploadOperation: Trying to start again on an executing operation")
        
        if self.isCancelled {
            return
        }
        
        self.requestCount += 1
        
        _uploaded = false
        self.uploading = true
    
//        request.send { (result, code, data) in
//            self.parseData(result:result, code: code, data: data)
//
//            self.uploading = false
//            self.uploaded = true
//        }
        
        do {
            try request.execute()
            //self.responseResult = request.resultItems
            try parseData(result: true, code: 200, data: request.resultItems, error: nil )
        } catch {
            NSLog( error.localizedDescription )
            try? parseData(result: false, code: -1, data: nil, error: error )
        }
        
        self.uploading = false
        self.uploaded = true
    }
    
    override var isAsynchronous: Bool {
        return true
    }
    
    override var isExecuting: Bool{
        return self.uploading
    }
    
    override var isFinished: Bool{
        return self.uploaded || self.isCancelled
    }
    
    func parseData(result:Bool, code:Int, data:Any?, error: Error?) throws {
        //let response = (self.store.delegate?.webStore(store: self.webStore, requestDidFinishWithResult:result, code: code, data: data))!
        let response = MPSRequestResponse(result: result, items: data, timestamp: TimeInterval())

        self.responseCode = code
        self.responseData = data
        self.responseError = error
        self.responseResult = response.result

        //self.store.didParseDataInOperation(self, result: data)
        
        try responseDidReceive(response: response)
    }

    // Function to override
    func responseDidReceive(response:MPSRequestResponse) throws {}
    
    // MARK - Parser methods
    
    func updateObjects(items:[Any], for entity:NSEntityDescription, relationships:[String]?) throws -> ([NSManagedObjectID], [NSManagedObjectID], [NSManagedObjectID]) {
        
        let objects = NSMutableSet()
        let insertedObjects = NSMutableSet()
        let updatedObjects = NSMutableSet()
        let relationshipNodes = NSMutableDictionary()
        relationShipsNodes(relationships: relationships, nodes: relationshipNodes)
        
        for i in items {
            let values = i as! [String : Any]
            try updateObject(values:values, fetchEntity:entity, objectID:nil, relationshipNodes: relationshipNodes, objectIDs:objects, insertedObjectIDs:insertedObjects, updatedObjectIDs:updatedObjects)
        }
        
        return (objects.allObjects as! [NSManagedObjectID], insertedObjects.allObjects as! [NSManagedObjectID], updatedObjects.allObjects as! [NSManagedObjectID])
    }

    func updateObject(values:[String:Any], fetchEntity:NSEntityDescription, objectID:NSManagedObjectID?, relationshipNodes:NSMutableDictionary?, objectIDs:NSMutableSet, insertedObjectIDs:NSMutableSet, updatedObjectIDs:NSMutableSet) throws {
        
        var entity = fetchEntity
        let entityValues: [String:Any] = values
        let entityName = values["classname"] as! String // ?? fetchEntity.name!
        if entityName != fetchEntity.name {
            entity = fetchEntity.managedObjectModel.entitiesByName[entityName]!

            guard let _ = store.identifierForItem(values, entityName: entityName) else {
                throw MIOPersistentStoreError.identifierIsNull()
            }
            // TODO: remove this fix when entity core get all merged values from all derivated classes
//            let fr =  NSFetchRequest<NSManagedObject>(entityName: entityName)
//            fr.entity = entity
//            let new_request = store.delegate!.store(store: store, fetchRequest: fr, serverID: identifierString)!
//
//            try new_request.execute( )
//
//            entityValues = new_request.resultItems!.first as! [String:Any]
        }
//        if fetchEntity.subentities.first == nil {
//            entityName = fetchEntity.name!
//        }
//        
        
//        
//        if entity.name != entityName {
//            let ctx = (webStore.delegate?.mainContextForWebStore(store: webStore))!
//            entity = NSEntityDescription.entity(forEntityName: entityName, in: ctx)!
//        }
        
        // Check the objects inside values
        let parsedValues = try checkRelationships( values:entityValues, entity: entity, relationshipNodes: relationshipNodes, objectIDs: objectIDs, insertedObjectIDs: insertedObjectIDs, updatedObjectIDs: updatedObjectIDs )
        
        guard let identifier = store.identifierForItem( parsedValues, entityName: fetchEntity.name! ) else {
            throw MIOPersistentStoreError.identifierIsNull()
        }
        
        let version = store.versionForItem( values, entityName: fetchEntity.name! )
        
        // Check if the server is deleting the object and ignoring
//        if store.cacheNode(deletingNodeAtServerID:serverID, entity:entity) == true {
//            return
//        }
                        
        var node = store.cacheNode( withIdentifier: identifier, entity: entity )
        if node == nil {
            // --- NSLog("New version: " + entity.name! + " (\(version))");
            node = store.cacheNode( newNodeWithValues: parsedValues, identifier: identifier, version: version, entity: entity, objectID: objectID )
            insertedObjectIDs.add(node!.objectID)
        }
        else if version > node!.version {
            // --- NSLog("Update version: \(entity.name!) (\(node!.version) -> \(version))")
            store.cacheNode( updateNodeWithValues: parsedValues, identifier: identifier, version: version, entity: entity )
            updatedObjectIDs.add( node!.objectID )
        }
        
        objectIDs.add( node!.objectID )
    }
    
    private func checkRelationships(values : [String : Any], entity:NSEntityDescription, relationshipNodes : NSMutableDictionary?, objectIDs:NSMutableSet, insertedObjectIDs:NSMutableSet, updatedObjectIDs:NSMutableSet) throws -> [String : Any] {
        
        var parsedValues: [ String: Any ] = [ "classname": values[ "classname" ] as! String ]
        
        for key in entity.propertiesByName.keys {
            
            let prop = entity.propertiesByName[key]
            if prop is NSAttributeDescription {
                                         
                // TODO: Transfrom key from UserInfo
                let serverKey = key
                
                let newValue = values[serverKey]
                if newValue == nil { continue }
                
                if newValue is NSNull {
                    parsedValues[key] = newValue
                    continue
                }
                                
                let attr = prop as! NSAttributeDescription
                if attr.attributeType == .dateAttributeType {
                    if let date = newValue as? Date {
                        parsedValues[key] = date
                    }
                    else if let dateString = newValue as? String {
                        parsedValues[key] = try parse_date( dateString )
                    }
                    else {
                        throw MIOPersistentStoreError.invalidValueType(entityName:entity.name!, key: key, value: newValue!)
                    }
                }
                else if attr.attributeType == .UUIDAttributeType {
                    parsedValues[key] = newValue is String ? UUID(uuidString: newValue as! String ) : newValue  // (newValue as! UUID).uuidString.upperCased( )
                }
                else if attr.attributeType == .transformableAttributeType {
                    parsedValues[key] = try JSONSerialization.jsonObject( with: ( newValue as! String ).data( using: .utf8 )!, options: [ .allowFragments ] )
                }
                else if attr.attributeType == .decimalAttributeType {
                    let decimal = MIOCoreDecimalValue( newValue, nil )
                    parsedValues[key] = decimal != nil ? decimal! : NSNull()
                }
                else {
                    // check type
                    switch attr.attributeType {
                    case .booleanAttributeType,
                         .decimalAttributeType,
                         .doubleAttributeType,
                         .floatAttributeType,
                         .integer16AttributeType,
                         .integer32AttributeType,
                         .integer64AttributeType:
                        if !(newValue is NSNumber) {throw MPSError.invalidType(key, newValue) }
//                        assert(newValue is NSNumber, "[Black Magic] Received Number with incorrect type for key \(key)")
                        
                    case .stringAttributeType:
                        if !(newValue is NSString) {throw MPSError.invalidType(key, newValue) }
//                        assert(newValue is NSString, "[Black Magic] Received String with incorrect type for key \(key)")
                    
                    default:
                        throw MPSError.invalidType( key, newValue )
//                      assert(true)
                    }
                    parsedValues[key] = newValue
                }
            }
            else if prop is NSRelationshipDescription {
                
                //let serverKey = (webStore.delegate?.webStore(store: webStore, serverRelationshipName: key, forEntity: entity))!
                let serverKey = key
                
                if relationshipNodes?[key] == nil {
                    parsedValues[key] = values[serverKey]
                    continue
                }
                
                let relEntity = entity.relationshipsByName[key]!
                let value = values[serverKey]
                if value == nil { continue }
                
                if relEntity.isToMany == false {
                    let relKeyPathNode = relationshipNodes![key] as? NSMutableDictionary
                    if let serverValues = value as? [String:Any] {
                        try updateObject(values: serverValues, fetchEntity: relEntity.destinationEntity!, objectID: nil, relationshipNodes: relKeyPathNode, objectIDs: objectIDs, insertedObjectIDs: insertedObjectIDs, updatedObjectIDs: updatedObjectIDs)
                        //let serverID = webStore.delegate?.webStore(store: webStore, serverIDForItem: value!, entityName: relEntity.destinationEntity!.name!)
                        guard let identifierString = store.identifierForItem(value as! [String:Any], entityName: relEntity.destinationEntity!.name!) else {
                            throw MIOPersistentStoreError.identifierIsNull()
                        }
                        parsedValues[key] = identifierString
                    }
                }
                else {
                    
                    var array = [UUID]()
                    let relKeyPathNode = relationshipNodes![key] as? NSMutableDictionary
                    // let serverValues = (value as? [Any]) != nil ? value as!  [Any] : []
                    let serverValues = value as! [Any]
                    for relatedItem in serverValues {
                        
                        guard let ri = relatedItem as? [String:Any] else {
                            print("[MIOPersistentStoreOperation] item: \(relatedItem)")
                            throw MIOPersistentStoreError.invalidValueType( entityName: relEntity.name, key: serverKey, value: relatedItem )
                        }

                        guard let dst = relEntity.destinationEntity else {
                            print("[MIOPersistentStoreOperation] dst: \(String(describing: relEntity.destinationEntity))")
                            throw MIOPersistentStoreError.invalidValueType( entityName: relEntity.name, key: serverKey, value: relEntity.destinationEntity?.name ?? "relEntity.destinationEntity is nil" )
                        }

                        try updateObject(values: ri, fetchEntity: dst, objectID: nil, relationshipNodes: relKeyPathNode, objectIDs: objectIDs, insertedObjectIDs: insertedObjectIDs, updatedObjectIDs: updatedObjectIDs)
                        //let serverID = webStore.delegate?.webStore(store: webStore, serverIDForItem: relatedItem, entityName: relEntity.destinationEntity!.name!)
                        guard let identifier = store.identifierForItem(relatedItem as! [String:Any], entityName: relEntity.destinationEntity!.name!) else {
                            throw MIOPersistentStoreError.identifierIsNull()
                        }
                        array.append( identifier )
                    }
                    
                    parsedValues[key] = array
                }
            }
        }
        
        //parsedValues["relationshipIDs"] = relationshipsIDs
        return parsedValues
    }
    
    func relationShipsNodes(relationships:[String]?, nodes: NSMutableDictionary) {
        
        if relationships == nil {
            return
        }
        
        for keyPath in relationships! {
            let keys = keyPath.split(separator: ".")
            let key = String(keys[0])
            
            var values = nodes[key] as? NSMutableDictionary
            if values == nil {
                values = NSMutableDictionary()
                nodes[key] = values!
            }
            
            if (keys.count > 1) {
                let index = keyPath.index(keyPath.startIndex, offsetBy:key.count + 1)
                let subKeyPath = String(keyPath[index...])
                //var subNodes = [String:Any]()
                relationShipsNodes(relationships: [subKeyPath], nodes: values!)
                //                values?.merge(subNodes, uniquingKeysWith: { (OldValue, newValue) -> Any in
                //                    return newValue
                //                })
                //                nodes[key] = values!
            }
        }
        
    }

}
