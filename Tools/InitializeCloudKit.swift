// Backend maintenance helper. Run only with a Development-signed bundle for this container.
import Foundation
import CoreData
import CloudKit

let model = NSManagedObjectModel()
func attribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
    let value = NSAttributeDescription(); value.name = name; value.attributeType = type; value.isOptional = true; return value
}
let field = NSEntityDescription(); field.name = "FieldVersion"; field.managedObjectClassName = "NSManagedObject"
field.properties = [attribute("id",.UUIDAttributeType),attribute("owner",.UUIDAttributeType),attribute("kind",.stringAttributeType),attribute("field",.stringAttributeType),attribute("json",.stringAttributeType),attribute("timestamp",.dateAttributeType)]
let blob = NSEntityDescription(); blob.name = "AttachmentBlob"; blob.managedObjectClassName = "NSManagedObject"
let content = attribute("data",.binaryDataAttributeType); content.allowsExternalBinaryDataStorage = true
blob.properties = [attribute("path",.stringAttributeType),content]; model.entities = [field,blob]
let container = NSPersistentCloudKitContainer(name: "OwnList",managedObjectModel: model)
let location = FileManager.default.urls(for: .applicationSupportDirectory,in: .userDomainMask)[0].appendingPathComponent("OwnListSchemaSetup",isDirectory: true)
try FileManager.default.createDirectory(at: location,withIntermediateDirectories: true)
let description = NSPersistentStoreDescription(url: location.appendingPathComponent("Schema.sqlite"))
description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: "iCloud.com.gaoluchuan.ownlist")
description.setOption(true as NSNumber,forKey: NSPersistentHistoryTrackingKey)
container.persistentStoreDescriptions = [description]
container.loadPersistentStores { _,error in
    if let error { print("Store setup failed: \(error)"); exit(1) }
    DispatchQueue.global().async {
        do { try container.initializeCloudKitSchema(options: []); print("Development schema initialized. Deploy it in CloudKit Console before production synchronization."); exit(0) }
        catch { let e = error as NSError; print("Schema initialization failed: \(e.domain) \(e.code) \(e.localizedDescription)"); print("Reason: \(e.userInfo[NSLocalizedFailureReasonErrorKey] ?? e.userInfo[NSLocalizedDescriptionKey] ?? "unavailable")"); if let partial = e.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: NSError] { for (_,detail) in partial { print("Underlying CloudKit error: \(detail.domain) \(detail.code) \(detail.localizedDescription)") } }; let db = CKContainer(identifier: "iCloud.com.gaoluchuan.ownlist").privateCloudDatabase; db.save(CKRecordZone(zoneName: "com.apple.coredata.cloudkit.zone")) { _,error in if let error = error as NSError? { print("Zone setup: \(error.domain) \(error.code) \(error.localizedDescription)"); if let partial = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: NSError] { for (_,detail) in partial { print("Zone reason: \(detail.domain) \(detail.code) \(detail.localizedDescription)") } } }; exit(1) } }
    }
}
RunLoop.main.run()
