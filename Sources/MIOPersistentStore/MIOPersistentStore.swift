//
//  MIOPersistentStore.swift
//  MIOWebServices
//
//  Created by GodShadow on 26/11/2017.
//  Copyright © 2017 MIO Research Labs. All rights reserved.
//

import Foundation
import MIOCore
import MIOCoreData
import MIOCoreLogger

// Identity contract: the store's referenceObject IS the row's identifiable
// database value. DualLink uses a UUID stored in an "identifier" attribute —
// that column name is only a default, overridable per entity through
// identifierKeyForEntity below. (The UUID typing of this protocol is the
// remaining DualLink-ism; generalizing it to numeric or other key types is a
// deliberate breaking change deferred until a non-UUID consumer exists.)
public protocol MIOPersistentStoreDelegate : NSObjectProtocol
{
    func store(store:MIOPersistentStore, fetchRequest:NSFetchRequest<NSManagedObject>, identifier:UUID?) -> MPSRequest?
    func store(store:MIOPersistentStore, saveRequest:NSSaveChangesRequest) -> MPSRequest?

    func store(store: MIOPersistentStore, identifierForObject object:NSManagedObject) -> UUID?
    func store(store: MIOPersistentStore, identifierFromItem item:[String:Any], fetchEntityName: String) -> UUID?
    func store(store: MIOPersistentStore, versionFromItem item:[String:Any], fetchEntityName: String) -> UInt64

    /// Name of the attribute that carries the identifiable value for rows of
    /// this entity. Defaults to "identifier" (the DualLink convention).
    func store(store: MIOPersistentStore, identifierKeyForEntity entity: NSEntityDescription) -> String
}

extension MIOPersistentStoreDelegate
{
    public func store(store: MIOPersistentStore, identifierKeyForEntity entity: NSEntityDescription) -> String {
        return "identifier"
    }
}

// @unchecked: the invalidValueType payload carries Any? for the offending
// value; errors are created and consumed for messaging only
public enum MIOPersistentStoreError : Error, @unchecked Sendable
{
    case noStoreURL(_ schema:String = "", functionName: String = #function)
    case invalidRequest(_ schema:String = "", functionName: String = #function)
    case identifierIsNull(_ schema:String = "", functionName: String = #function)
    case invalidValueType(_ schema:String = "", entityName:String, key:String, value:Any?, functionName: String = #function)
    case relationIdentifierNoExist(_ schema:String = "", entityName:String, relation:String, relationEntityName:String, id:String, functionName: String = #function)
    case delegateIsNull(_ schema:String = "", functionName: String = #function )
    case cacheNodeNotFound(_ schema:String = "", entityName:String, id:UUID, functionName: String = #function )
}

extension MIOPersistentStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .noStoreURL(schema, functionName):
            return "[MIOPersistentStoreError] \(schema) No store URL. \(functionName)"
        case let .invalidRequest(schema, functionName):
            return "[MIOPersistentStoreError] \(schema) Invalid request. \(functionName)"
        case let .identifierIsNull(schema, functionName):
            return "[MIOPersistentStoreError] \(schema) Identifier is null. \(functionName)"
        case let .invalidValueType(schema, entityName, key, value, functionName):
            return "[MIOPersistentStoreError] \(schema) Invalid value type. \(entityName).\(key): \(value ?? "null"). \(functionName)"
        case let .relationIdentifierNoExist(schema, entityName, relation, relationEntityName, id, functionName):
            return "[MIOPersistentStoreError] \(schema) Relation identifier not exist. \(entityName).\(relation)): \(relationEntityName)://\(id). \(functionName)"
        case let .delegateIsNull(schema, functionName):
            return "[MIOPersistentStoreError] \(schema) Delegate is null. \(functionName)"
        case let .cacheNodeNotFound(schema, entityName, id, functionName):
            return "[MIOPersistentStoreError] \(schema) No cache node for \(entityName)://\(id.uuidString). \(functionName)"
        }
    }
}


open class MIOPersistentStore: NSIncrementalStore
{
    public static let storeType:String = "MIOPersistentStore"
    // NSPersistentStoreDescription is a reference type the compiler cannot
    // prove Sendable; this instance is configured once here and treated as
    // immutable by every consumer
    nonisolated(unsafe) public static let storeDescription: NSPersistentStoreDescription = {
        let description = NSPersistentStoreDescription()
        description.type = MIOPersistentStore.storeType
        return description
    }()
    
    public override var type: String { return MIOPersistentStore.storeType }
    
    public var delegate: MIOPersistentStoreDelegate?
    var storeURL:URL?

    // Per-store serial queue guarding the node cache. Created once here — the
    // old MIOCoreQueue(label:) lookup paid a global-registry queue hop plus two
    // string allocations on every cache access.
    #if os(WASI)
    // WASI is single-threaded and has no Dispatch module: run queue bodies inline
    struct DispatchQueue {
        init(label: String) {}
        @discardableResult func sync<T>(execute body: () throws -> T) rethrows -> T { try body() }
    }
    #endif
    let cacheQueue: DispatchQueue

    nonisolated(unsafe) private static var instanceCount = 0   // countQueue-serialized
    private static let countQueue = DispatchQueue(label: "context.count")

    public required override init(persistentStoreCoordinator root: NSPersistentStoreCoordinator?, configurationName name: String?, at url: URL, options: [AnyHashable : Any]? = nil) {
        cacheQueue = DispatchQueue(label: "mps.\(url.absoluteString)")
        Self.countQueue.sync { Self.instanceCount += 1 }
        super.init(persistentStoreCoordinator: root, configurationName: name, at: url, options: options)
    }
    
    deinit {
        Self.countQueue.sync { Self.instanceCount -= 1 }
        Log.debug("MIOPersistentStore deinit - nodes: \(nodesByCacheKey.count), alive: \(Self.instanceCount)")
        nodesByCacheKey.removeAll()
    }
    
    // MARK: - NSIncrementalStore override
    
    public override func loadMetadata() throws {
        
        guard let storeURL = url else {
            throw MIOPersistentStoreError.noStoreURL()
        }
        
        self.storeURL = storeURL
        let metadata = [NSStoreUUIDKey: storeURL.absoluteString, NSStoreTypeKey: MIOPersistentStore.storeType]
        self.metadata = metadata
    }
    
    public override func execute(_ request: NSPersistentStoreRequest, with context: NSManagedObjectContext?) throws -> Any {
        
        switch request {
            
        case let fetchRequest as NSFetchRequest<NSManagedObject>:
            let obs = try fetchObjects(fetchRequest: fetchRequest, with: context!)
            return obs
            
        case let saveRequest as NSSaveChangesRequest:
            try saveObjects(request: saveRequest, with: context!)
            return NSNull()
            
        default:
            throw MIOPersistentStoreError.invalidRequest()
        }
    }
    
    public override func newValuesForObject(with objectID: NSManagedObjectID, with context: NSManagedObjectContext) throws -> NSIncrementalStoreNode {

        // Temporary (unsaved) objects exist only in the context: the store has
        // no cache node and the DB has no row until save, so a fetch is doomed.
        if objectID.isTemporaryID {
            Log.warning( "newValuesForObject asked for a temporary object of \(objectID.entity.name ?? "?") — unsaved objects live in the context, not the store" )
            return NSIncrementalStoreNode( objectID: objectID, withValues: [:], version: 0 )
        }

        let identifier = referenceObject( for: objectID ) as! UUID

        var node = try cacheNode( withIdentifier: identifier, entity: objectID.entity )
        if node == nil {
            node = try cacheNode(newNodeWithValues: [:], identifier: identifier, version: 0, entity: objectID.entity, objectID: objectID)
        }
        
        if node!.version == 0 {
            Log.debug( "MIOPersistenStore:newValuesForObject:with:with: fetchObject \(objectID.entity.name!) \(identifier)" )
            let ret = try fetchObject( withIdentifier:identifier, entityName: objectID.entity.name!, context:context )
            Log.debug( "MIOPersistenStore:newValuesForObject:with:with: fetchObject \(objectID.entity.name!) \(identifier) :\(String(describing: ret))" )
        }
        
        let storeNode = try node!.storeNode()
        return storeNode
    }
    
    public override func newValue(forRelationship relationship: NSRelationshipDescription, forObjectWith objectID: NSManagedObjectID, with context: NSManagedObjectContext?) throws -> Any {

        // Same invariant as newValuesForObject: an unsaved object cannot be
        // resolved by the store — its relationships live in the context's
        // pending changes until save.
        if objectID.isTemporaryID {
            Log.warning( "newValue(forRelationship: \(relationship.name)) asked for a temporary object of \(objectID.entity.name ?? "?")" )
            return relationship.isToMany ? [NSManagedObjectID]() : NSNull()
        }

        let identifier = referenceObject(for: objectID) as! UUID

        var node = try cacheNode( withIdentifier: identifier, entity: objectID.entity )
        if node == nil {
            node = try cacheNode(newNodeWithValues: [:], identifier: identifier, version: 0, entity: objectID.entity, objectID: objectID)
        }
        
        if node!.version == 0 {
            //let delegate = ( context!.persistentStoreCoordinator!.persistentStores[0] as! MIOPersistentStore ).delegate!
            //print("\(delegate): newValue -> fetchObject: \(objectID.entity.name!).\(relationship.name) -> \(relationship.destinationEntity!.name!)://\(identifier)")
            Log.debug( "MIOPersistenStore:newValue:forRelationship:forObjectWith:with: fetchObject \(objectID.entity.name!) \(identifier)" )
            let ret = try fetchObject( withIdentifier:identifier, entityName: objectID.entity.name!, context:context! )
            Log.debug( "MIOPersistenStore:newValue:forRelationship:forObjectWith:with: fetchObject \(objectID.entity.name!) \(identifier) : \(String(describing: ret))" )
        }
        
        let value = try node!.value( forRelationship: relationship )
        
        if relationship.isToMany == false {
            guard let relIdentifier = value as? UUID else { return NSNull() }
            
            var relNode = try cacheNode( withIdentifier: relIdentifier, entity: relationship.destinationEntity! )
            if relNode == nil {
                //let delegate = ( context!.persistentStoreCoordinator!.persistentStores[0] as! MIOPersistentStore ).delegate!
                //print("\(delegate): newValue -> fetchObject: \(objectID.entity.name!).\(relationship.name) -> \(relationship.destinationEntity!.name!)://\(identifier)")
                Log.debug( "MIOPersistenStore:newValue:forRelationship:forObjectWith:with: fetchObject \(relationship.destinationEntity!.name!) \(relIdentifier)" )
                let ret = try fetchObject( withIdentifier:relIdentifier, entityName: relationship.destinationEntity!.name!, context:context! )
                Log.debug( "MIOPersistenStore:newValue:forRelationship:forObjectWith:with: fetchObject \(objectID.entity.name!) \(identifier) : \(String(describing: ret))" )
                relNode = try cacheNode(withIdentifier: relIdentifier, entity: relationship.destinationEntity!)
            }
            
            if relNode == nil {
                let delegate = ( context!.persistentStoreCoordinator!.persistentStores[0] as! MIOPersistentStore ).delegate!
                Log.critical("CD CACHE NODE NULL: \(delegate): \(objectID.entity.name!).\(relationship.name) -> \(relationship.destinationEntity!.name!)://\(relIdentifier)")
                throw MIOPersistentStoreError.identifierIsNull()
            }
            
            if relNode!.version == 0 {
                Log.debug( "MIOPersistenStore:newValue:forRelationship:forObjectWith:with: fetchObject \(relationship.destinationEntity!.name!) \(relIdentifier)" )
                let ret = try fetchObject( withIdentifier:relIdentifier, entityName: relationship.destinationEntity!.name!, context:context! )
                Log.debug( "MIOPersistenStore:newValue:forRelationship:forObjectWith:with: fetchObject \(relationship.destinationEntity!.name!) \(relIdentifier) : \(String(describing: ret))" )

            }
            
            return relNode!.objectID
        }
        else {
            if value is Set<NSManagedObject> {
                return (value as! Set<NSManagedObject>).map{ $0.objectID }
            }
            
            guard let relIdentifiers = value as? [UUID] else {
                return [UUID]()
            }
            
            var objectIDs:Set<NSManagedObjectID> = Set()
            var faultNodeIDs:[UUID] = []
            for relID in relIdentifiers {
                let relNode = try cacheNode( withIdentifier: relID, entity: relationship.destinationEntity! )
                if relNode == nil || relNode?.version == 0 { faultNodeIDs.append( relID ) }
                else { objectIDs.insert( relNode!.objectID ) }
            }
            
            if faultNodeIDs.isEmpty == false {
                Log.debug( "MIOPersistenStore:newValue:forRelationship:forObjectWith:with: fetchObject \(relationship.destinationEntity!.name!) \(faultNodeIDs)" )
                let ret = try fetchObjects(identifiers: faultNodeIDs, entityName: relationship.destinationEntity!.name!, context: context!)
                Log.debug( "MIOPersistenStore:newValue:forRelationship:forObjectWith:with: fetchObject \(relationship.destinationEntity!.name!) \(faultNodeIDs) : \(String(describing: ret))" )

                for relID in faultNodeIDs {
                    let relNode = try cacheNode(withIdentifier: relID, entity: relationship.destinationEntity!)
                    if relNode == nil {
                        let delegate = (context!.persistentStoreCoordinator!.persistentStores[0] as! MIOPersistentStore ).delegate!
                        Log.critical( "CD CACHE NODE NULL: \(delegate): \(objectID.entity.name!).\(relationship.name) -> \(relationship.destinationEntity!.name!)://\(relID)")
                        throw MIOPersistentStoreError.identifierIsNull()
                    }
                    
                    objectIDs.insert(relNode!.objectID)
                }
            }
            
            return Array( objectIDs )
        }
    }
    
    public func storedValues(forRelationship relationship: NSRelationshipDescription, forObjectWith objectID: NSManagedObjectID, with context: NSManagedObjectContext?) throws -> [Any]
    {
        if objectID.isTemporaryID { return [] }
        
        let identifier = referenceObject(for: objectID) as! UUID
        
        var node = try cacheNode( withIdentifier: identifier, entity: objectID.entity )
        if node == nil {
            node = try cacheNode(newNodeWithValues: [:], identifier: identifier, version: 0, entity: objectID.entity, objectID: objectID)
        }
        
        if node!.version == 0 {
            try fetchObject( withIdentifier:identifier, entityName: objectID.entity.name!, context:context! )
        }
        
        let value = try node!.value( forRelationship: relationship )

        if let set = value as? Set<NSManagedObject> {
            return set.map{ $0 }
        }
        
        if let uuids = value as? [UUID] {
            return uuids
        }

        return []
    }
    
    public override func obtainPermanentIDs(for array: [NSManagedObject]) throws -> [NSManagedObjectID] {
        return try array.map{ obj in
            guard let identifier = delegate?.store(store: self, identifierForObject: obj) else {
                throw MIOPersistentStoreError.identifierIsNull()
            }
            
            let objID = newObjectID( for: obj.entity, referenceObject: identifier )
            
            return objID
        }
    }
    
    public override func managedObjectContextDidRegisterObjects(with objectIDs: [NSManagedObjectID]) {
        // Apple contract: this pair is a reference count on the row cache —
        // "the objects with these IDs are in use in a context". Only permanent
        // IDs ever arrive here; temporary (unsaved) objects exist only in the
        // context until save and the store is never notified about them. The
        // node itself is created by the save or fetch request, never here (the
        // callback carries no values). Nodes without a registration (e.g.
        // side-loaded relationship rows) just stay at count zero.
        for objID in objectIDs {
            if objID.isTemporaryID { continue }
            guard let identifier = referenceObject(for: objID) as? UUID else { continue }
            let key = MPSCacheKey( entityName: objID.entity.name!, id: identifier )
            cacheQueue.sync {
                registrationCountByCacheKey[key, default: 0] += 1
                if nodesByCacheKey[key] == nil {
                    // This callback cannot throw, so a warning is the loudest
                    // signal available. Legitimate for faults materialized
                    // from a bare permanent ID (the node arrives at first
                    // fault or at save) — any other case is a caching hole
                    // that will surface as cacheNodeNotFound at save time.
                    Log.warning( "Registered \(key.entityName)://\(identifier.uuidString) before its row is cached" )
                }
            }
        }
    }

    public override func managedObjectContextDidUnregisterObjects(with objectIDs: [NSManagedObjectID]) {
        // Evict only when the last registration goes away: the cache is shared
        // by every context on this store, and the old unconditional delete
        // pulled nodes out from under contexts that still held the object.
        // A key without a count entry was already force-evicted by a
        // delete-save — nothing to do.
        for objID in objectIDs {
            guard let identifier = referenceObject(for: objID) as? UUID else { continue }
            let key = MPSCacheKey( entityName: objID.entity.name!, id: identifier )
            var evict = false
            cacheQueue.sync {
                guard let count = registrationCountByCacheKey[key] else { return }
                if count <= 1 {
                    registrationCountByCacheKey.removeValue(forKey: key)
                    evict = true
                }
                else {
                    registrationCountByCacheKey[key] = count - 1
                }
            }
            if evict {
                try? cacheNode( deleteNodeAtIdentifier: identifier, entity: objID.entity )
            }
        }
    }
    
    // MARK: - Cache Nodes in memory
    var nodesByCacheKey = [MPSCacheKey:MPSCacheNode]()

    /// Registration reference counts (Apple's didRegister/didUnregister pair),
    /// kept separate from the nodes on purpose: a context can legitimately
    /// register an object whose row is not cached yet — a permanent ID
    /// materialized as a fault gets its node at first fault or at save — so
    /// the bookkeeping must never depend on node existence, or those counts
    /// would be silently lost. Guarded by cacheQueue.
    var registrationCountByCacheKey = [MPSCacheKey:Int]()

    func cacheNode(withIdentifier identifier:UUID, entity:NSEntityDescription) throws -> MPSCacheNode? {

        let key = MPSCacheKey( entityName: entity.name!, id: identifier )
        var node:MPSCacheNode?
        cacheQueue.sync {
            node = nodesByCacheKey[key]
        }
        return node
    }

    func cacheNode(newNodeWithValues values:[String:Any], identifier: UUID, version:UInt64, entity:NSEntityDescription, objectID:NSManagedObjectID?) throws -> MPSCacheNode {

        let id = identifier
        let objID = objectID ?? newObjectID( for: entity, referenceObject: id )
        let node = MPSCacheNode( identifier:id, entity: entity, withValues: values, version: version, objectID: objID )

        cacheQueue.sync {
            nodesByCacheKey[node.cacheKey] = node
        }

        if entity.superentity != nil {
            try cacheParentNode( node: node, identifier: identifier, entity: entity.superentity! )
        }

        return node
    }

    func cacheParentNode(node: MPSCacheNode, identifier: UUID, entity:NSEntityDescription) throws {

        let key = MPSCacheKey( entityName: entity.name!, id: identifier )

        cacheQueue.sync {
            nodesByCacheKey[key] = node
        }

        if entity.superentity != nil {
            try cacheParentNode(node: node, identifier: identifier, entity: entity.superentity!)
        }
    }

    func cacheNode(updateNodeWithValues values:[String:Any], identifier:UUID, version:UInt64? = nil, entity:NSEntityDescription) throws {

        let key = MPSCacheKey( entityName: entity.name!, id: identifier )

        try cacheQueue.sync {
            // A missing node means a save/registration hole somewhere else —
            // surface it as a request error, never kill the process.
            guard let node = nodesByCacheKey[key] else {
                throw MIOPersistentStoreError.cacheNodeNotFound( entityName: entity.name!, id: identifier )
            }
            let v = version ?? node.version
            node.update(withValues: values, version: v)
        }
    }

    func cacheNode(deleteNodeAtIdentifier identifier:UUID, entity:NSEntityDescription) throws {
        let key = MPSCacheKey( entityName: entity.name!, id: identifier )

        _ = cacheQueue.sync {
            nodesByCacheKey.removeValue(forKey: key)
            // A force-delete (delete-save) drops the registration count with
            // the row: stale counts must not block eviction of a re-created
            // node, and outstanding unregisters for this key become no-ops.
            registrationCountByCacheKey.removeValue(forKey: key)
        }

        if entity.superentity != nil {
            try cacheNode(deleteNodeAtIdentifier: identifier, entity: entity.superentity!)
        }
    }
        
    public func refresh(object: NSManagedObject, context: NSManagedObjectContext) throws {
                        
        let identifier = referenceObject(for: object.objectID) as! UUID
        let node = try cacheNode(withIdentifier: identifier, entity: object.entity)
        if node != nil { node!.invalidate() }

        try fetchObject( withIdentifier: identifier, entityName: object.objectID.entity.name!, context: context )

        // Objects stay realized after a save, so refetching the node is not
        // enough: a realized object keeps answering from its snapshot, which
        // never contained DB-assigned columns (autoinc, DB defaults). Refault
        // so the next read materializes from the node fetched above.
        context.refresh( object, mergeChanges: false )
    }
        
    // MARK: - Fetching objects from server and cache
        
    @discardableResult
    func fetchObject(withIdentifier identifier:UUID, entityName:String, context:NSManagedObjectContext) throws -> Any? {
        return try fetchObjects( identifiers: [identifier], entityName: entityName, context: context )
    }
    
    @discardableResult func fetchObjects(identifiers:[UUID], entityName:String, context:NSManagedObjectContext) throws -> Any? {
        let r = NSFetchRequest<NSManagedObject>(entityName: entityName)
        r.entity = persistentStoreCoordinator?.managedObjectModel.entitiesByName[entityName]

        // The identifier column is the delegate's business, not a hardcoded
        // convention — "identifier" is only the default
        let identifierKey = r.entity != nil ? ( delegate?.store(store: self, identifierKeyForEntity: r.entity!) ?? "identifier" ) : "identifier"
        r.predicate = MIOPredicateWithFormat(format: "%K in %@", arguments: [ identifierKey, identifiers.map { $0.uuidString } ] )

        return try fetchObjects(fetchRequest:r, with:context)
    }
    
    public func fetchObjects(fetchRequest:NSFetchRequest<NSManagedObject>, with context:NSManagedObjectContext) throws -> [Any] {
        
        if delegate == nil {
            throw MIOPersistentStoreError.delegateIsNull( storeURL!.absoluteString )
        }
        
        guard let request = delegate?.store(store: self, fetchRequest: fetchRequest, identifier: nil) as? MPSFetchRequest else {
            throw MIOPersistentStoreError.invalidRequest()
        }
        
        try request.execute()
        
        Log.debug( "MIOPersistenStore:fetchObjects: \(fetchRequest.entityName!) -> \(String(describing: request.resultItems))" )
        
        guard let entities = request.resultItems?["entities"] as? [Any] else { throw MIOPersistentStoreError.invalidRequest("ESQUEMA AQUI")}
        
        guard let related_entities = request.resultItems?["relationShipEntities"] as? [Any] else { throw MIOPersistentStoreError.invalidRequest("ESQUEMA AQUI")}
        
        let object_ids = try updateObjects( items: entities, for: fetchRequest.entity! )
        _ = try updateObjects( items: related_entities, for: fetchRequest.entity! )

        switch fetchRequest.resultType {
        case .managedObjectIDResultType: return object_ids
        case .managedObjectResultType  : return try object_ids.map { try context.existingObject(with: $0) }
        default: return []
        }
    }


    // MARK: -  Saving objects in server and caché
    func saveObjects(request:NSSaveChangesRequest, with context:NSManagedObjectContext) throws {
        let dl_request = self.delegate?.store(store: self, saveRequest: request)
        try dl_request?.execute()

        // The save request is where the row cache is populated for new rows
        // (Apple's own stores do the same). Inserted objects already carry
        // their permanent reference — obtainPermanentIDs runs before execute.
        // Without a node here, the next save of the same object
        // (insert -> save -> update -> save) has nothing to update.
        for obj in request.insertedObjects ?? Set() {
            // A non-UUID reference is a temporary ID the context let through
            // (String, minted by NSManagedObjectID itself) — such an object
            // was never persisted, so there is nothing to cache or delete.
            // Skipping beats crashing the process mid-save.
            guard let id = referenceObject(for: obj.objectID) as? UUID else {
                Log.warning( "saveObjects: skipping inserted \(obj.entity.name ?? "?") with non-UUID reference object" )
                continue
            }
            if try cacheNode(withIdentifier: id, entity: obj.entity) != nil {
                // Identifier already known (e.g. fetched before an insert with
                // a client-supplied ID) — mutate the shared node instance.
                try cacheNode(updateNodeWithValues: obj.changedValues(), identifier: id, entity: obj.entity)
            }
            else {
                _ = try cacheNode(newNodeWithValues: obj.changedValues(), identifier: id, version: 1, entity: obj.entity, objectID: obj.objectID)
            }
        }

        for obj in request.updatedObjects ?? Set() {
            guard let id = referenceObject(for: obj.objectID) as? UUID else {
                Log.warning( "saveObjects: skipping updated \(obj.entity.name ?? "?") with non-UUID reference object" )
                continue
            }
            try cacheNode(updateNodeWithValues: obj.changedValues(), identifier: id, entity: obj.entity)
        }

        // Deleted rows leave the cache with the save itself, regardless of
        // how many registrations still point at them.
        for obj in request.deletedObjects ?? Set() {
            guard let id = referenceObject(for: obj.objectID) as? UUID else {
                Log.warning( "saveObjects: skipping deleted \(obj.entity.name ?? "?") with non-UUID reference object" )
                continue
            }
            try cacheNode(deleteNodeAtIdentifier: id, entity: obj.entity)
        }
    }

    func versionForItem(_ values: [String:Any], entityName: String) -> UInt64 {
        guard let version = delegate?.store(store: self, versionFromItem: values, fetchEntityName: entityName) else {
            return 1
        }
        
        return version
    }
    
    func identifierForItem(_ values: [String:Any], entityName:String) -> UUID? {
        return delegate?.store(store: self, identifierFromItem: values, fetchEntityName: entityName)
    }
    
}

