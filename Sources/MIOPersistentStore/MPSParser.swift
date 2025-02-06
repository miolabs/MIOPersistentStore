//
//  File.swift
//  
//
//  Created by Javier Segura Perez on 28/8/23.
//

import Foundation
import MIOCoreData
import MIOCore

// MARK - Parser methods

extension MIOPersistentStore
{
    
    func updateObjects(items:[Any], for entity:NSEntityDescription, relationships:[String]?) throws -> ([NSManagedObjectID], [NSManagedObjectID], [NSManagedObjectID]) {
        
        var objects:[NSManagedObjectID] = []
        let insertedObjects = NSMutableSet()
        let updatedObjects = NSMutableSet()
        let relationshipNodes = NSMutableDictionary()
        relationShipsNodes(relationships: relationships, nodes: relationshipNodes)
        
        for i in items {
            let values = i as! [String : Any]
            try updateObject(values:values, fetchEntity:entity, objectID:nil, relationshipNodes: relationshipNodes, objectIDs:&objects, insertedObjectIDs:insertedObjects, updatedObjectIDs:updatedObjects)
        }
        
        return (objects, insertedObjects.allObjects as! [NSManagedObjectID], updatedObjects.allObjects as! [NSManagedObjectID])
    }

    func updateObject(values:[String:Any], fetchEntity:NSEntityDescription, objectID:NSManagedObjectID?, relationshipNodes:NSMutableDictionary?, objectIDs:inout [NSManagedObjectID], insertedObjectIDs:NSMutableSet, updatedObjectIDs:NSMutableSet) throws {
        
        var entity = fetchEntity
        let entityValues: [String:Any] = values
        let entityName = values["classname"] as! String // ?? fetchEntity.name!
        if entityName != fetchEntity.name {
            entity = fetchEntity.managedObjectModel.entitiesByName[entityName]!
        }
            
        // Check the objects inside values
        let parsedValues = try checkRelationships( values:entityValues, entity: entity, relationshipNodes: relationshipNodes, objectIDs: &objectIDs, insertedObjectIDs: insertedObjectIDs, updatedObjectIDs: updatedObjectIDs )
        
        guard let identifier = identifierForItem( parsedValues, entityName: fetchEntity.name! ) else {
            throw MIOPersistentStoreError.identifierIsNull()
        }
        
        let version = versionForItem( values, entityName: fetchEntity.name! )
        
        // Check if the server is deleting the object and ignoring
        //        if store.cacheNode(deletingNodeAtServerID:serverID, entity:entity) == true {
        //            return
        //        }
        
        var node = try cacheNode( withIdentifier: identifier, entity: entity )
        if node == nil {
            // --- NSLog("New version: " + entity.name! + " (\(version))");
            node = try cacheNode( newNodeWithValues: parsedValues, identifier: identifier, version: version, entity: entity, objectID: objectID )
            insertedObjectIDs.add(node!.objectID)
        }
        else if version > node!.version {
            // --- NSLog("Update version: \(entity.name!) (\(node!.version) -> \(version))")
            try cacheNode( updateNodeWithValues: parsedValues, identifier: identifier, version: version, entity: entity )
            updatedObjectIDs.add( node!.objectID )
        }

        objectIDs.append( node!.objectID )
        
        // Look for parent entity
//        var check:NSEntityDescription? = entity
//        while check != nil {
//            if check!.name == entity.name { objectIDs.append( node!.objectID ); break }
//            check = check?.superentity
//        }
    }

    func checkRelationships(values : [String : Any], entity:NSEntityDescription, relationshipNodes : NSMutableDictionary?, objectIDs:inout [NSManagedObjectID], insertedObjectIDs:NSMutableSet, updatedObjectIDs:NSMutableSet) throws -> [String : Any] {
        
        var parsedValues: [ String: Any ] = [ "classname": values[ "classname" ] as! String ]
        
        for (key, prop) in entity.propertiesByName
        {
            // TODO: Transfrom key from UserInfo
            let serverKey = key
            let value = values[serverKey]
            if value == nil || value is NSNull { continue }
            
            if let attr = prop as? NSAttributeDescription
            {
                func check_type_and_not_null_value( _ value: Any?, block: @escaping (Any) throws -> Any? ) throws -> Any {
                    if value == nil {
                        throw MIOPersistentStoreError.invalidValueType(entityName:entity.name!, key: key, value: value)
                    }
                    
                    guard let v = try block( value! ) else {
                        throw MIOPersistentStoreError.invalidValueType(entityName:entity.name!, key: key, value: value)
                    }
                    return v
                }
                
                switch attr.attributeType {
                case .dateAttributeType:
                    if let date = value as? Date { parsedValues[key] = date; continue }
                    parsedValues[key] = try check_type_and_not_null_value( value as? String ) { try parse_date( $0 as! String ) }
                
                case .UUIDAttributeType:
                    if let uuid = value as? UUID { parsedValues[key] = uuid; continue }
                    parsedValues[key] = try check_type_and_not_null_value( value as? String ) { UUID(uuidString: $0 as! String ) }
                
                case .transformableAttributeType:
                    if let dict = value as? [String:Any] { parsedValues[key] = dict; continue }
                    parsedValues[key] = try check_type_and_not_null_value( value as? String) {
                        try JSONSerialization.jsonObject( with: ( $0 as! String ).data( using: .utf8 )!, options: [ .allowFragments ] )
                    }
                
                case .booleanAttributeType,
                     .decimalAttributeType,
                     .doubleAttributeType,
                     .floatAttributeType,
                     .integer16AttributeType,
                     .integer32AttributeType,
                     .integer64AttributeType:

                    //if let number = value as? NSNumber { parsedValues[key] = number; continue }
                    switch attr.attributeType {
                    case .booleanAttributeType: parsedValues[key] = try check_type_and_not_null_value( value ) { MIOCoreBoolValue( $0 ) }
                    case .decimalAttributeType: parsedValues[key] = try check_type_and_not_null_value( value ) { MCDecimalValue( $0 ) }
                    case .doubleAttributeType: parsedValues[key] = try check_type_and_not_null_value( value ) { MIOCoreFloatValue( $0 ) }
                    case .floatAttributeType: parsedValues[key] = try check_type_and_not_null_value( value ) { MIOCoreFloatValue( $0 ) }
                    case .integer16AttributeType: parsedValues[key] = try check_type_and_not_null_value( value ) { MIOCoreInt16Value( $0 ) }
                    case .integer32AttributeType: parsedValues[key] = try check_type_and_not_null_value( value ) { MIOCoreInt32Value( $0 ) }
                    case .integer64AttributeType: parsedValues[key] = try check_type_and_not_null_value( value ) { MIOCoreInt64Value( $0 ) }
                    default: break
                    }
                    
                case .stringAttributeType:
                    if let str = value as? String { parsedValues[key] = str; continue }
                    if let str = value as? NSString { parsedValues[key] = str; continue }
                    throw MIOPersistentStoreError.invalidValueType( entityName: entity.name!, key: key, value: value )
                    
                default: throw MIOPersistentStoreError.invalidValueType( entityName: entity.name!, key: key, value: value )
                }
            }
            else if let rel = prop as? NSRelationshipDescription
            {
                if rel.isToMany == false {
                    guard let uuid = value as? UUID ?? ( value is String ? UUID(uuidString: value as! String) : nil ) else {
                        throw MIOPersistentStoreError.invalidValueType( entityName: rel.name, key: serverKey, value: value )
                    }
                                        
                    parsedValues[key] = uuid
                }
                else
                {
                    if let uuids = value as? [UUID] { parsedValues[key] = uuids; continue }
                    
                    var array = [UUID]()
                    guard let rel_values = value as? [String] else {
                        throw MIOPersistentStoreError.invalidValueType( entityName: rel.name, key: serverKey, value: value )
                    }
                    
                    for id in rel_values {
                        guard let uuid = UUID( uuidString: id ) else {
                            throw MIOPersistentStoreError.invalidValueType( entityName: rel.name, key: serverKey, value: id )
                        }
                        array.append( uuid )
                    }
                    parsedValues[key] = array
                }
            }
             
        }
                
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
            }
        }
    }
}
