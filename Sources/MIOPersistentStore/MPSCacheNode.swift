//
//  MPSCacheNode.swift
//
//
//  Created by Javier Segura Perez on 05/10/2020.
//

import Foundation
import MIOCore
import MIOCoreData
import MIOCoreLogger


/// Cache dictionary key: hashes two words (entity name reference + UUID)
/// instead of the ~50-char referenceID string the cache used to be keyed by.
struct MPSCacheKey : Hashable
{
    let entityName: String
    let id: UUID
}

open class MPSCacheNode : NSObject
{
    static func referenceID(withIdentifier identifier:UUID, entity:NSEntityDescription) -> String {
        // UUID.uuidString is already uppercase on Darwin and corelibs-foundation.
        return entity.name! + "://" + identifier.uuidString
    }

    let _identifier:UUID
    let _entity:NSEntityDescription
    var _version:UInt64 = 0
    var _objectID:NSManagedObjectID

    let cacheKey: MPSCacheKey
    private let _referenceID: String

    /// Values exactly as they were received — native Swift types from the DB
    /// driver, JSON strings from web/sync sources, or NSManagedObject
    /// references from changedValues() on save. Conversion to Core Data
    /// values is deferred until the object is faulted.
    var _rawValues:[String:Any]

    // Converted values, built lazily on first fault and dropped on update.
    private var _attributeValues:[String:Any]?
    private var _relationshipValues:[String:Any]?
    private var _node:NSIncrementalStoreNode?
    private let _lock = NSLock()

    open var version: UInt64 { return _version }
    open var referenceID:String { get { return _referenceID } }
    open var objectID:NSManagedObjectID { get { return _objectID } }

    init(identifier:UUID, entity:NSEntityDescription, withValues values:[String:Any], version:UInt64, objectID:NSManagedObjectID){
        _identifier = identifier
        _entity = entity
        _version = version
        _objectID = objectID
        _rawValues = values
        cacheKey = MPSCacheKey( entityName: entity.name!, id: identifier )
        _referenceID = MPSCacheNode.referenceID( withIdentifier: identifier, entity: entity )
    }

    func update(withValues values:[String:Any], version: UInt64) {
        _lock.lock(); defer { _lock.unlock() }
        _rawValues.merge(values, uniquingKeysWith: { (_, new) in new } )
        _attributeValues = nil
        _relationshipValues = nil
        _node = nil
        _version = version
    }

    /// Converts the raw values eagerly. Called at ingest time when
    /// MPS_VALIDATE_VALUES is set, so unconvertible attribute values log their
    /// warning at fetch time instead of at first fault (malformed relationship
    /// values still throw).
    func validateValues() throws {
        _lock.lock(); defer { _lock.unlock() }
        try convert_values_if_needed()
    }

    func storeNode() throws -> NSIncrementalStoreNode {
        _lock.lock(); defer { _lock.unlock() }
        try convert_values_if_needed()
        if _node == nil {
            _node = NSIncrementalStoreNode(objectID: _objectID, withValues: _attributeValues!, version: _version)
        }
        return _node!
    }

    func value(forRelationship relationship: NSRelationshipDescription) throws -> Any? {
        _lock.lock(); defer { _lock.unlock() }
        try convert_values_if_needed()
        return _relationshipValues![relationship.name]
    }

    func invalidate(){
        _version = 0
    }

    // MARK: - Lazy conversion

    /// One pass over the entity properties: attributes to their Core Data
    /// value class, relationship values to UUID reference IDs. NSNull and
    /// absent keys are skipped — the store node treats missing attributes
    /// as nil, and nil relationships resolve to NSNull on read.
    private func convert_values_if_needed() throws {
        Log.debug( "convert_values_if_needed. \(_entity.name!)" )
        
        if _attributeValues != nil { return }

        var attrs:[String:Any] = [:]
        var rels:[String:Any] = [:]

        if let classname = _rawValues["classname"] { attrs["classname"] = classname }

        for (key, prop) in _entity.propertiesByName {
            guard let value = _rawValues[key] else { continue }
            if value is NSNull { continue }

            if let attr = prop as? NSAttributeDescription {
                // Unconvertible values degrade to nil (missing key) and only warn.
                if let converted = MPSCacheNode.convert(attribute: value, attr, entityName: _entity.name!) {
                    attrs[key] = converted
                }
            }
            else if let rel = prop as? NSRelationshipDescription {
                rels[key] = try MPSCacheNode.convert(relationship: value, rel, entityName: _entity.name!)
            }
        }

        _attributeValues = attrs
        _relationshipValues = rels
    }

    /// Converts a raw value to its Core Data value class. A value that cannot
    /// be converted degrades to nil — logged as a warning — so one bad column
    /// never fails the whole object.
    // The type table lives in the canonical converter
    // (NSAttributeDescription.coreDataValue(from:) in MIOCoreData); this
    // wrapper keeps the cache policy: a value that cannot be converted is
    // logged and dropped to nil instead of failing the whole fetch.
    static func convert(attribute value: Any, _ attr: NSAttributeDescription, entityName: String) -> Any? {
        do {
            return try attr.coreDataValue(from: value)
        }
        catch {
            Log.warning( "Can't convert \(entityName).\(attr.name) to \(attr.attributeType): '\(value)' (\(type(of: value))) — returning nil" )
            return nil
        }
    }

    static func convert(relationship value: Any, _ rel: NSRelationshipDescription, entityName: String) throws -> Any {

        func reference(from value:Any) -> Any? {
            if let objID = value as? NSManagedObjectID {
                return (objID.persistentStore as! NSIncrementalStore).referenceObject(for: objID)
            }
            else if let obj = value as? NSManagedObject {
                return reference(from: obj.objectID )
            }
            else if let uuid = value as? UUID {
                return uuid
            }
            else if let id = value as? String {
                return UUID(uuidString: id )
            }
            return nil
        }

        func invalid() -> MIOPersistentStoreError {
            return MIOPersistentStoreError.invalidValueType( entityName: entityName, key: rel.name, value: value )
        }

        if rel.isToMany == false {
            guard let ref = reference(from: value) else { throw invalid() }
            return ref
        }

        if let uuids = value as? [UUID] { return uuids }

        var references:[Any] = []
        if let set = value as? Set<NSManagedObject>        { references = Array( set ) }
        else if let set = value as? Set<NSManagedObjectID> { references = Array( set ) }
        else if let set = value as? Set<String>            { references = Array( set ) }
        else if let set = value as? Set<UUID>              { return Array( set ) }
        else if let array = value as? [Any]                { references = array }
        else { throw invalid() }

        return try references.map {
            guard let ref = reference(from: $0) else { throw invalid() }
            return ref
        }
    }
}
