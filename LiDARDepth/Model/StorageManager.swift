//
//  FileManager.swift
//  LiDARDepth
//
//  Created by Yuxin (Myles) Liu on 3/14/24.
//  Copyright © 2024 Apple. All rights reserved.
//

import Foundation
import CoreData

extension Data {
     func append(fileURL: URL) throws {
         if let fileHandle = FileHandle(forWritingAtPath: fileURL.path) {
             defer {
                 fileHandle.closeFile()
             }
             fileHandle.seekToEndOfFile()
             fileHandle.write(self)
         }
         else {
             try write(to: fileURL, options: .atomic)
         }
     }
 }

extension String {
    func appendLineToURL(fileURL: URL) throws {
         try (self + "\n").appendToURL(fileURL: fileURL)
     }

     func appendToURL(fileURL: URL) throws {
         let data = self.data(using: String.Encoding.utf8)!
         try data.append(fileURL: fileURL)
     }
 }

class StorageManager: ObservableObject {
    let captureLogFileName = "capture_log"
    
    let captureLogContainer = NSPersistentContainer(name: "CaptureLog")
    
    // For clearing cache
    var isClearingCache: Bool
    
    init() {
        isClearingCache = false
    }
    
    func writeToTextFile(fileName: String, content: String, isOverWrite: Bool) {
        
        guard let documentDirectoryUrl = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let fileUrl = documentDirectoryUrl.appendingPathComponent(fileName)

        do {
            if (isOverWrite) {
                try content.write(to: fileUrl, atomically: false, encoding: .utf8)
            } else {
                try content.appendToURL(fileURL: fileUrl)
            }
        } catch {
            print(error.localizedDescription)
        }
    }
    
    func writeByteDataToFile(fileName: String, data: Data, isOverWrite: Bool) {
        
        guard let documentDirectoryUrl = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let fileUrl = documentDirectoryUrl.appendingPathComponent(fileName)
        
        do {
            if isOverWrite {
                try data.write(to: fileUrl, options: .atomic)
            } else {
                try data.append(fileURL: fileUrl)
            }
        } catch {
            print(error.localizedDescription)
        }
    }
    
    func writeByteDataToFile(fileURL: URL, data: Data, isOverWrite: Bool) {
        
        do {
            if isOverWrite {
                try data.write(to: fileURL, options: .atomic)
            } else {
                try data.append(fileURL: fileURL)
            }
        } catch {
            fatalError(error.localizedDescription)
        }
    }
    
    func registerNewCapture(captureName: String) {
        writeToTextFile(fileName: captureLogFileName, content: captureName + "\n", isOverWrite: false);
    }
    
    func getAllFileNames() -> [String.SubSequence] {
        guard let documentDirectoryUrl = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return []}
        let fileUrl = documentDirectoryUrl.appendingPathComponent(captureLogFileName)
        
        let captureLogString:String
        do {
            try captureLogString = String(contentsOf: fileUrl, encoding: .utf8)
        } catch {
//            fatalError(error.localizedDescription)
            return []
        }
        
        return captureLogString.split(separator: "\n")
    }
    
    func getAllDiskFileNames() -> [String] {
        let documentsDirectoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(at: documentsDirectoryURL, includingPropertiesForKeys: [])
        
        var fileNames:[String] = []
          
        while let url = enumerator?.nextObject() as? URL {
            fileNames.append(url.lastPathComponent)
        }
        
        return fileNames
    }
    
    func clearCache() {
        isClearingCache = true
        let documentsDirectoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(at: documentsDirectoryURL, includingPropertiesForKeys: [])
          
        while let url = enumerator?.nextObject() as? URL {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                // Handle deletion error (optional)
                print("Error deleting file at \(url.absoluteString): \(error)")
            }
        }
        
        isClearingCache = false
    }
}

