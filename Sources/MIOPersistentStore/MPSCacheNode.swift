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
    var _attributeValues:[String:Any]
    var _relationshipValues:[String:Any]
    var _version:UInt64 = 0
    var _objectID:NSManagedObjectID

    open var version: UInt64 { return _version }
    open var referenceID:String { get { return _entity.name! + "://" + _identifier.uuidString.uppercased() } }
    open var objectID:NSManagedObjectID { get { return _objectID } }

    /// `parsedValues` marks values that already went through MPSParser
    /// (typed values, relationships normalized to UUID / [UUID]), so the
    /// reference normalization pass is skipped. Values coming from
    /// `changedValues()` on save still carry NSManagedObject references and
    /// need it.
    init(identifier:UUID, entity:NSEntityDescription, withValues values:[String:Any], version:UInt64, objectID:NSManagedObjectID, parsedValues: Bool = false){
        _identifier = identifier
        _entity = entity
        _version = version
        _objectID = objectID
        _attributeValues = [:]
        _relationshipValues = [:]
        super.init()
        merge_values(values, parsedValues: parsedValues)
    }

    func update(withValues values:[String:Any], version: UInt64, parsedValues: Bool = false) {
        merge_values(values, parsedValues: parsedValues)
        _node = nil
        _version = version
    }

    /// Single pass over the incoming values: relationship values go to
    /// `_relationshipValues` (normalized to reference IDs unless the caller
    /// already did it), everything else to `_attributeValues`. An NSNull
    /// attribute removes the stored value, matching the old behavior where
    /// NSNull was kept in `_values` but filtered out of the store node.
    private func merge_values(_ values:[String:Any], parsedValues: Bool) {
        for (key, v) in values {
            if let rel = _entity.propertiesByName[key] as? NSRelationshipDescription {
                _relationshipValues[key] = parsedValues ? v : MPSCacheNode.reference_values(v, relationship: rel)
            }
            else if v is NSNull {
                _attributeValues.removeValue(forKey: key)
            }
            else {
                _attributeValues[key] = v
            }
        }
    }

    static func reference_values(_ value:Any, relationship rel:NSRelationshipDescription) -> Any {

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

        if rel.isToMany == false {
            return reference(from: value)
        }

        if value is Set<NSManagedObject> {
            return (value as! Set<NSManagedObject>).map { reference( from: $0 ) }
        }
        else if value is Set<NSManagedObjectID> {
            return (value as! Set<NSManagedObjectID>).map { reference( from: $0 ) }
        }
        else if value is Set<String> {
            return (value as! Set<String>).map { reference( from: $0 ) }
        }
        else if value is Set<UUID> {
            return value
        }
        else if value is Array<NSManagedObject> {
            return (value as! Array<NSManagedObject>).map { reference( from: $0 ) }
        }
        else if value is Array<NSManagedObjectID> {
            return (value as! Array<NSManagedObjectID>).map { reference( from: $0 ) }
        }
        else if value is Array<String> {
            return (value as! Array<String>).map { reference( from: $0 ) }
        }

        return value
    }

    var _node:NSIncrementalStoreNode?
    func storeNode() throws -> NSIncrementalStoreNode {
        if _node != nil { return _node! }
        _node = NSIncrementalStoreNode(objectID: _objectID, withValues: _attributeValues, version: _version)
        return _node!
    }

    func attributeValues() -> [String:Any] {
        return _attributeValues
    }

    func value(forRelationship relationship: NSRelationshipDescription) throws -> Any? {
        return _relationshipValues[relationship.name]
    }

    func invalidate(){
        _version = 0
    }
}
