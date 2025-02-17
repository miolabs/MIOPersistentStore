//
//  MPSCacheNode.swift
//  
//
//  Created by Javier Segura Perez on 05/10/2020.
//

import Foundation
import MIOCoreData


open class MPSCacheNode : NSObject
{
    static func referenceID(withIdentifier identifier:UUID, entity:NSEntityDescription) -> String {
        return entity.name! + "://" + identifier.uuidString.uppercased()
    }
    
    let _identifier:UUID
    let _entity:NSEntityDescription
    var _values:[String:Any]
    var _version:UInt64 = 0
    var _objectID:NSManagedObjectID
 
    open var version: UInt64 { return _version }
    open var referenceID:String { get { return _entity.name! + "://" + _identifier.uuidString.uppercased() } }
    open var objectID:NSManagedObjectID { get { return _objectID } }
    
    init(identifier:UUID, entity:NSEntityDescription, withValues values:[String:Any], version:UInt64, objectID:NSManagedObjectID){
        _identifier = identifier
        _values = MPSCacheNode.parse_values(values, entity: entity)
        _version = version
        _entity = entity
        _objectID = objectID
    }
    
    func update(withValues values:[String:Any], version: UInt64) {
        let parse_values = MPSCacheNode.parse_values(values, entity: _entity)
        _values.merge(parse_values, uniquingKeysWith: { (_, new) in new } )
        _node = nil
        _attributeValues = nil
        _version = version
    }
    
    static func parse_values(_ values:[String:Any], entity:NSEntityDescription) -> [String:Any] {
        
        func reference(from value:Any) -> Any {
            if let objID = value as? NSManagedObjectID {
                return (objID.persistentStore as! NSIncrementalStore).referenceObject(for: objID)
            }
            else if let obj = value as? NSManagedObject {
                return reference(from: obj.objectID )
            }
            else if let id = value as? String {
                return UUID(uuidString: id ) ?? NSNull()
            }
            else if let uuid = value as? UUID {
                return uuid
            }
            
            return NSNull()
        }
        
        var new_values:[String:Any] = [:]
        
        for (key, v) in values {
            
            if let rel = entity.propertiesByName[key] as? NSRelationshipDescription {
                if rel.isToMany == false {
                    new_values[key] = reference(from: v)
                }
                else {
                    if v is Set<NSManagedObject> {
                        new_values[key] = (v as! Set<NSManagedObject>).map { reference( from: $0 ) }
                    }
                    else if v is Set<NSManagedObjectID> {
                        new_values[key] = (v as! Set<NSManagedObjectID>).map { reference( from: $0 ) }
                    }
                    else if v is Set<String> {
                        new_values[key] = (v as! Set<String>).map { reference( from: $0 ) }
                    }
                    else if v is Set<UUID> {
                        new_values[key] = v //(v as! Set<UUID>).map { reference( from: $0 ) }
                    }
                    else if v is Array<NSManagedObject> {
                        new_values[key] = (v as! Array<NSManagedObject>).map { reference( from: $0 ) }
                    }
                    else if v is Array<NSManagedObjectID> {
                        new_values[key] = (v as! Array<NSManagedObjectID>).map { reference( from: $0 ) }
                    }
                    else if v is Array<String> {
                        new_values[key] = (v as! Array<String>).map { reference( from: $0 ) }
                    }
                    else if v is Array<UUID> {
                        new_values[key] = v //(v as! Array<UUID>).map { reference( from: $0 ) }
                    }
                }
            }
            else {
                new_values[key] = v
            }
        }
        
        return new_values
    }
    
    var _node:NSIncrementalStoreNode?
    func storeNode() throws -> NSIncrementalStoreNode {
        if _node != nil { return _node! }
        _node = NSIncrementalStoreNode(objectID: _objectID, withValues: attributeValues(), version: _version)
        return _node!
    }
        
    var _attributeValues:[String:Any]?
    func attributeValues() -> [String:Any] {
        if _attributeValues != nil { return _attributeValues! }
        
        _attributeValues = [:]
        for (key, _) in _entity.attributesByName {
            if let value = _values[key] {
                if value is NSNull { continue }
                _attributeValues![key] = value
            }
        }
        
        return _attributeValues!
    }
    
    func value(forRelationship relationship: NSRelationshipDescription) throws -> Any? {
        return _values[relationship.name]
    }
    
    func invalidate(){
        _version = 0
    }
}
