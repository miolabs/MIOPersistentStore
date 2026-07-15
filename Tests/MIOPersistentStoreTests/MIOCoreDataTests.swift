//
//  MIOCoreDataTests.swift
//  
//
//  Created by Javier Segura Perez on 04/10/2020.
//

#if !APPLE_CORE_DATA

import XCTest
import MIOCoreData
import MIOPersistentStore


fileprivate func TestManagedObjectModel() -> MIOCoreData.NSManagedObjectModel
{
    return MPSTestManagedObjectModel()
}

fileprivate func TestManagedObjectConext() -> MIOCoreData.NSManagedObjectContext
{
    MIOCoreData.NSPersistentStoreCoordinator.registerStoreClass(MIOPersistentStore.self, forStoreType: MIOPersistentStore.storeType)
    
    let url = URL(string: "dltest")
    let description = MIOCoreData.NSPersistentStoreDescription(url:url!)
    description.type = MIOPersistentStore.storeType

    let container = MIOCoreData.NSPersistentContainer(name: "TestDB", managedObjectModel:TestManagedObjectModel())
    container.persistentStoreDescriptions = [description]
    
    container.loadPersistentStores(completionHandler: { (storeDescription, error) in
        if let error = error as NSError? {
            NSLog(error.localizedDescription)
            fatalError("Unresolved error \(error), \(error.userInfo)")
        }
    })
    
    return container.viewContext
}


final class MIOCoreDataTests: XCTestCase
{
    func testCreateObject() {
        let moc = TestManagedObjectConext()
        
        //let doc = NSEntityDescription.insertNewObject(forEntityName: "Document", into: moc)
    }
}

#endif


