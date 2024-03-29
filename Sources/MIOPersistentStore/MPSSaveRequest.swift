//
//  MPSSaveRequest.swift
//  
//
//  Created by Javier Segura Perez on 18/7/22.
//

import Foundation

#if APPLE_CORE_DATA
import CoreData
#else
import MIOCore
import MIOCoreData
#endif


open class MPSSaveRequest : MPSRequest
{
    public var insertedObjects:Set<NSManagedObject>
    public var updatedObjects :Set<NSManagedObject>
    public var deletedObjects :Set<NSManagedObject>
    
    public init( saveRequest: NSSaveChangesRequest ) {
        insertedObjects = saveRequest.insertedObjects ?? Set()
        updatedObjects  = saveRequest.updatedObjects  ?? Set()
        deletedObjects  = saveRequest.deletedObjects  ?? Set()
        
        super.init()
    }    
}
