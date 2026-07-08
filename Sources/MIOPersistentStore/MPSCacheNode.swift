//
//  MPSCacheNode.swift
//
//
//  Created by Javier Segura Perez on 05/10/2020.
//

import Foundation
import MIOCore
import MIOCoreData


open class MPSCacheNode : NSObject
{
    static func referenceID(withIdentifier identifier:UUID, entity:NSEntityDescription) -> String {
        return entity.name! + "://" + identifier.uuidString.uppercased()
    }

    let _identifier:UUID
    let _entity:NSEntityDescription
    var _version:UInt64 = 0
    var _objectID:NSManagedObjectID

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
    open var referenceID:String { get { return _entity.name! + "://" + _identifier.uuidString.uppercased() } }
    open var objectID:NSManagedObjectID { get { return _objectID } }

    init(identifier:UUID, entity:NSEntityDescription, withValues values:[String:Any], version:UInt64, objectID:NSManagedObjectID){
        _identifier = identifier
        _entity = entity
        _version = version
        _objectID = objectID
        _rawValues = values
    }

    func update(withValues values:[String:Any], version: UInt64) {
        _lock.lock(); defer { _lock.unlock() }
        _rawValues.merge(values, uniquingKeysWith: { (_, new) in new } )
        _attributeValues = nil
        _relationshipValues = nil
        _node = nil
        _version = version
    }

    /// Converts the raw values eagerly. Called at ingest time in DEBUG so
    /// malformed values (bad JSON, invalid UUID/date strings) surface at
    /// fetch time instead of at first fault.
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
        if _attributeValues != nil { return }

        var attrs:[String:Any] = [:]
        var rels:[String:Any] = [:]

        if let classname = _rawValues["classname"] { attrs["classname"] = classname }

        for (key, prop) in _entity.propertiesByName {
            guard let value = _rawValues[key] else { continue }
            if value is NSNull { continue }

            if let attr = prop as? NSAttributeDescription {
                attrs[key] = try MPSCacheNode.convert(attribute: value, attr, entityName: _entity.name!)
            }
            else if let rel = prop as? NSRelationshipDescription {
                rels[key] = try MPSCacheNode.convert(relationship: value, rel, entityName: _entity.name!)
            }
        }

        _attributeValues = attrs
        _relationshipValues = rels
    }

    static func convert(attribute value: Any, _ attr: NSAttributeDescription, entityName: String) throws -> Any {

        func check_value( _ block: (Any) throws -> Any? ) throws -> Any {
            guard let v = try block( value ) else {
                throw MIOPersistentStoreError.invalidValueType(entityName: entityName, key: attr.name, value: value)
            }
            return v
        }

        switch attr.attributeType {
        case .dateAttributeType:
            if let date = value as? Date { return date }
            return try check_value { $0 is String ? try parse_date( $0 as! String ) : nil }

        case .UUIDAttributeType:
            if let uuid = value as? UUID { return uuid }
            return try check_value { $0 is String ? UUID(uuidString: $0 as! String ) : nil }

        case .transformableAttributeType:
            // Only web/sync sources deliver transformables as JSON text; the
            // DB driver hands over the parsed graph (dictionary, array or
            // fragment), which passes through as-is.
            if let str = value as? String {
                return try check_value { _ in
                    try JSONSerialization.jsonObject( with: str.data( using: .utf8 )!, options: [ .allowFragments ] )
                }
            }
            return value

        case .booleanAttributeType:   return try check_value { MIOCoreBoolValue( $0 ) }
        case .decimalAttributeType:   return try check_value { MCDecimalValue( $0 ) }
        case .doubleAttributeType:    return try check_value { MIOCoreFloatValue( $0 ) }
        case .floatAttributeType:     return try check_value { MIOCoreFloatValue( $0 ) }
        case .integer16AttributeType: return try check_value { MIOCoreInt16Value( $0 ) }
        case .integer32AttributeType: return try check_value { MIOCoreInt32Value( $0 ) }
        case .integer64AttributeType: return try check_value { MIOCoreInt64Value( $0 ) }

        case .stringAttributeType:
            if let str = value as? String { return str }
            if let str = value as? NSString { return str }
            throw MIOPersistentStoreError.invalidValueType( entityName: entityName, key: attr.name, value: value )

        default:
            throw MIOPersistentStoreError.invalidValueType( entityName: entityName, key: attr.name, value: value )
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
