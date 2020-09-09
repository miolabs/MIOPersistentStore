//
//  File.swift
//  
//
//  Created by Javier Segura Perez on 15/05/2020.
//

import Foundation
import MIOCoreData

import MIOCore
public typealias NSPredicate = MIOPredicate


public enum MPSRequestConnectionType
{
    case Synchronous
    case ASynchronous
}

open class MPSRequest : NSObject
{
    open var type:MPSRequestConnectionType { get { return .Synchronous } }
    
    open var fetchedItems:[Any]?
    
    open var entityName:String
    open var entity:NSEntityDescription
    open var predicate:NSPredicate?
    open var sortDescriptors: [NSSortDescriptor]?
    open var limit: Int?
    open var offset: Int?
    
    public init(With entity:NSEntityDescription){
        self.entity = entity
        self.entityName = entity.name!
        super.init()
    }
    
    open func execute() throws {}
}
