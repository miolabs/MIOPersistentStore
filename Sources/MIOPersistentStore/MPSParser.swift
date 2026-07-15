//
//  File.swift
//  
//
//  Created by Javier Segura Perez on 28/8/23.
//

import Foundation
import MIOCoreData
import MIOCore

/// When the MPS_VALIDATE_VALUES environment variable is set to a truthy
/// value ("1", "true", "yes"), every row is converted eagerly at ingest so
/// malformed values (bad JSON, invalid UUID/date strings) surface at fetch
/// time. Off by default: conversion is deferred until the object is
/// faulted. Read once at startup.
let MPSValidateValuesOnIngest: Bool = MIOCoreBoolValue( MCEnvironmentVar( "MPS_VALIDATE_VALUES" ) ) ?? false

// MARK - Parser methods

extension MIOPersistentStore
{
    
    func updateObjects(items:[Any], for entity:NSEntityDescription) throws -> [NSManagedObjectID] {

        var objects:[NSManagedObjectID] = []
        objects.reserveCapacity( items.count )

        for i in items {
            let values = i as! [String : Any]
            try updateObject(values:values, fetchEntity:entity, objectID:nil, objectIDs:&objects)
        }

        return objects
    }

    func updateObject(values:[String:Any], fetchEntity:NSEntityDescription, objectID:NSManagedObjectID?, objectIDs:inout [NSManagedObjectID]) throws {

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
            node = try cacheNode( newNodeWithValues: values, identifier: identifier, version: version, entity: entity, objectID: objectID )
        }
        else if version > node!.version {
            try cacheNode( updateNodeWithValues: values, identifier: identifier, version: version, entity: entity )
        }

        objectIDs.append( node!.objectID )

        if MPSValidateValuesOnIngest {
            try node!.validateValues()
        }
    }
}
