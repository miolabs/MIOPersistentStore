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
        let entityName = values["classname"] as! String // ?? fetchEntity.name!
        if entityName != fetchEntity.name {
            entity = fetchEntity.managedObjectModel.entitiesByName[entityName]!
        }

        guard let identifier = identifierForItem( values, entityName: fetchEntity.name! ) else {
            throw MIOPersistentStoreError.identifierIsNull()
        }

        let version = versionForItem( values, entityName: fetchEntity.name! )

        // Check if the server is deleting the object and ignoring
        //        if store.cacheNode(deletingNodeAtServerID:serverID, entity:entity) == true {
        //            return
        //        }

        // The node keeps the values as received; conversion to Core Data
        // values happens lazily when the object is faulted.
        var node = try cacheNode( withIdentifier: identifier, entity: entity )
        if node == nil {
            // --- NSLog("New version: " + entity.name! + " (\(version))");
            node = try cacheNode( newNodeWithValues: values, identifier: identifier, version: version, entity: entity, objectID: objectID )
            insertedObjectIDs.add(node!.objectID)
        }
        else if version > node!.version {
            // --- NSLog("Update version: \(entity.name!) (\(node!.version) -> \(version))")
            try cacheNode( updateNodeWithValues: values, identifier: identifier, version: version, entity: entity )
            updatedObjectIDs.add( node!.objectID )
        }

        objectIDs.append( node!.objectID )

        #if DEBUG
        // Surface malformed values (bad JSON, invalid UUID/date strings) at
        // fetch time while developing. Production defers the conversion to
        // the first fault of each object.
        try node!.validateValues()
        #endif

        // Look for parent entity
//        var check:NSEntityDescription? = entity
//        while check != nil {
//            if check!.name == entity.name { objectIDs.append( node!.objectID ); break }
//            check = check?.superentity
//        }
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
