import Foundation
import HealthKit

extension HealthBgSyncPlugin {

    // MARK: - Outbox model
    internal struct OutboxItem: Codable {
        let typeIdentifier: String
        let endpointKey: String
        let payloadPath: String
        let anchorPath: String?
        let wasFullExport: Bool?
    }

    internal func outboxDir() -> URL {
        let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return (base ?? FileManager.default.temporaryDirectory).appendingPathComponent("health_outbox", isDirectory: true)
    }

    internal func ensureOutboxDir() {
        try? FileManager.default.createDirectory(at: outboxDir(), withIntermediateDirectories: true)
    }

    internal func newPath(_ name: String, ext: String) -> URL {
        ensureOutboxDir()
        return outboxDir().appendingPathComponent("\(name).\(ext)")
    }

    // MARK: - Background upload with persistence
    internal func enqueueBackgroundUpload(
        payload: [String: Any],
        type: HKSampleType,
        candidateAnchor: HKQueryAnchor?,
        endpoint: URL,
        token: String,
        completion: @escaping ()->Void
    ) {
        // 1) payload → file
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { completion(); return }
        let id = UUID().uuidString
        let payloadURL = newPath("payload_\(id)", ext: "json")
        do { try data.write(to: payloadURL, options: Data.WritingOptions.atomic) } catch { completion(); return }

        // 2) candidate anchor → file (optional)
        var anchorURL: URL? = nil
        if let cand = candidateAnchor,
           let ad = try? NSKeyedArchiver.archivedData(withRootObject: cand, requiringSecureCoding: true) {
            let u = newPath("anchor_\(id)", ext: "bin")
            try? ad.write(to: u, options: Data.WritingOptions.atomic)
            anchorURL = u
        }

        // 3) manifest (item) → file
        let item = OutboxItem(
            typeIdentifier: type.identifier,
            endpointKey: endpointKey(),
            payloadPath: payloadURL.path,
            anchorPath: anchorURL?.path,
            wasFullExport: nil
        )
        let itemURL = newPath("item_\(id)", ext: "json")
        if let md = try? JSONEncoder().encode(item) { try? md.write(to: itemURL, options: Data.WritingOptions.atomic) }

        // 4) request
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        // 5) background upload (from file)
        let task = session.uploadTask(with: req, fromFile: payloadURL)
        task.taskDescription = [itemURL.path, payloadURL.path, anchorURL?.path ?? ""].joined(separator: "|")
        task.resume()

        completion()
    }
    
    // MARK: - Combined upload for all data types
    internal func enqueueCombinedUpload(
        payload: [String: Any],
        anchors: [String: HKQueryAnchor],
        endpoint: URL,
        token: String,
        wasFullExport: Bool = false,
        completion: @escaping (Bool)->Void
    ) {
        // 1) payload → file
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { 
            print("❌ Failed to serialize payload to JSON")
            completion(false)
            return 
        }
        
        let id = UUID().uuidString
        let payloadURL = newPath("combined_payload_\(id)", ext: "json")
        
        do { 
            try data.write(to: payloadURL, options: Data.WritingOptions.atomic)
            let fileSizeMB = Double(data.count) / (1024 * 1024)
            print("✅ Created payload file: \(String(format: "%.2f", fileSizeMB)) MB (\(data.count) bytes)")
        } catch { 
            print("❌ Failed to write payload file: \(error.localizedDescription)")
            completion(false)
            return 
        }

        // 2) anchors → file (for all types) - serialize as binary data
        var anchorsURL: URL? = nil
        if !anchors.isEmpty {
            // Create a dictionary to store anchor data
            var anchorsData: [String: Data] = [:]
            for (typeId, anchor) in anchors {
                if let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) {
                    anchorsData[typeId] = data
                }
            }
            
            // Serialize the dictionary as binary data
            if let serializedData = try? NSKeyedArchiver.archivedData(withRootObject: anchorsData, requiringSecureCoding: true) {
                let u = newPath("combined_anchors_\(id)", ext: "bin")
                try? serializedData.write(to: u, options: Data.WritingOptions.atomic)
                anchorsURL = u
            }
        }

        // 3) manifest (item) → file
        let item = OutboxItem(
            typeIdentifier: "combined", // Special identifier for combined data
            endpointKey: endpointKey(),
            payloadPath: payloadURL.path,
            anchorPath: anchorsURL?.path,
            wasFullExport: wasFullExport
        )
        let itemURL = newPath("combined_item_\(id)", ext: "json")
        if let md = try? JSONEncoder().encode(item) { try? md.write(to: itemURL, options: Data.WritingOptions.atomic) }

        // 4) Read file into memory for immediate upload
        guard let payloadData = try? Data(contentsOf: payloadURL) else {
            print("❌ Failed to read payload file")
            completion(false)
            return
        }
        
        // 5) Create request with data as body for immediate upload
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = payloadData
        req.setValue("\(payloadData.count)", forHTTPHeaderField: "Content-Length")
        
        print("📤 Starting immediate upload to \(endpoint.absoluteString) (payload: \(payloadData.count) bytes)")
        
        // Use dataTask for immediate execution with completion handler
        let task = foregroundSession.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else { return }
            
            // Handle response
            if let error = error {
                let nsError = error as NSError
                if nsError.code != NSURLErrorCancelled {
                    print("❌ Upload error: \(error.localizedDescription)")
                } else {
                    print("ℹ️ Upload was cancelled")
                }
                // Clean up on error
                try? FileManager.default.removeItem(atPath: payloadURL.path)
                completion(false)
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                print("📥 HTTP Response: \(httpResponse.statusCode) for \(endpoint.absoluteString)")
                
                if (200...299).contains(httpResponse.statusCode) {
                    print("✅ Upload successful (HTTP \(httpResponse.statusCode))")
                    
                    // Save anchors after successful upload (only on last chunk)
                    self.handleSuccessfulUpload(itemPath: itemURL.path, anchorPath: anchorsURL?.path, wasFullExport: wasFullExport)
                    
                    // Clean up payload file
                    try? FileManager.default.removeItem(atPath: payloadURL.path)
                    
                    // Notify success
                    completion(true)
                } else {
                    print("⛔️ Upload failed with HTTP \(httpResponse.statusCode)")
                    if let data = data, let responseString = String(data: data, encoding: .utf8) {
                        print("⛔️ Server response: \(String(responseString.prefix(200)))")
                    }
                    // Clean up on failure
                    try? FileManager.default.removeItem(atPath: payloadURL.path)
                    completion(false)
                }
            } else {
                print("⚠️ No HTTP response received")
                try? FileManager.default.removeItem(atPath: payloadURL.path)
                completion(false)
            }
        }
        
        task.resume()
        print("✅ Upload task resumed, task ID: \(task.taskIdentifier)")
        
        // Note: completion will be called from the dataTask completion handler
    }
    
    // MARK: - Handle successful upload
    internal func handleSuccessfulUpload(itemPath: String, anchorPath: String?, wasFullExport: Bool) {
        // Load item to get endpoint key
        guard let itemData = try? Data(contentsOf: URL(fileURLWithPath: itemPath)),
              let item = try? JSONDecoder().decode(OutboxItem.self, from: itemData) else {
            print("⚠️ Failed to read item file for anchor saving")
            return
        }
        
        // Save anchors if available
        if let anchorPath = anchorPath, !anchorPath.isEmpty {
            if item.typeIdentifier == "combined" {
                // For combined uploads, save all anchors
                if let anchorData = try? Data(contentsOf: URL(fileURLWithPath: anchorPath)),
                   let anchorsDict = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSDictionary.self, from: anchorData) as? [String: Data] {
                    for (typeId, anchorData) in anchorsDict {
                        saveAnchorData(anchorData, typeIdentifier: typeId, endpointKey: item.endpointKey)
                    }
                    print("✅ Saved anchors for \(anchorsDict.count) types after successful upload")
                }
            } else {
                // For single type uploads, save single anchor
                if let anchorData = try? Data(contentsOf: URL(fileURLWithPath: anchorPath)) {
                    saveAnchorData(anchorData, typeIdentifier: item.typeIdentifier, endpointKey: item.endpointKey)
                }
            }
            
            // Clean up anchor file
            try? FileManager.default.removeItem(atPath: anchorPath)
        }
        
        // Mark full export as done if this was a full export
        if wasFullExport {
            let fullDoneKey = "fullDone.\(item.endpointKey)"
            let defaults = UserDefaults(suiteName: "com.healthbgsync.state") ?? .standard
            defaults.set(true, forKey: fullDoneKey)
            defaults.synchronize()
            print("✅ Marked full export as complete for endpoint: \(item.endpointKey)")
        }
        
        // Clean up item file
        try? FileManager.default.removeItem(atPath: itemPath)
    }

    // Retry pending items after startup (when endpoint/token are available)
    internal func retryOutboxIfPossible() {
        guard let endpoint = self.endpoint, let token = self.token else { return }
        let dir = outboxDir()
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        
        // Handle both regular and combined items
        let regularItems = files.filter { $0.lastPathComponent.hasPrefix("item_") && $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix("combined_item_") }
        let combinedItems = files.filter { $0.lastPathComponent.hasPrefix("combined_item_") && $0.pathExtension == "json" }

        // Retry regular items
        for itemURL in regularItems {
            guard let data = try? Data(contentsOf: itemURL),
                  let item = try? JSONDecoder().decode(OutboxItem.self, from: data) else { continue }
            let payloadURL = URL(fileURLWithPath: item.payloadPath)
            guard FileManager.default.fileExists(atPath: payloadURL.path) else { continue }

            guard let payloadData = try? Data(contentsOf: payloadURL) else { continue }
            
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = payloadData
            req.setValue("\(payloadData.count)", forHTTPHeaderField: "Content-Length")

            let task = foregroundSession.dataTask(with: req) { data, response, error in
                if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                    // Save anchors and clean up on success
                    if let anchorPath = item.anchorPath, !anchorPath.isEmpty {
                        // Save anchor logic here if needed for retries
                    }
                    try? FileManager.default.removeItem(atPath: payloadURL.path)
                    try? FileManager.default.removeItem(atPath: itemURL.path)
                }
            }
            task.resume()
        }
        
        // Retry combined items
        for itemURL in combinedItems {
            guard let itemData = try? Data(contentsOf: itemURL),
                  let item = try? JSONDecoder().decode(OutboxItem.self, from: itemData) else { continue }
            let payloadURL = URL(fileURLWithPath: item.payloadPath)
            guard FileManager.default.fileExists(atPath: payloadURL.path),
                  let payloadData = try? Data(contentsOf: payloadURL) else { continue }

            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = payloadData
            req.setValue("\(payloadData.count)", forHTTPHeaderField: "Content-Length")

            let task = foregroundSession.dataTask(with: req) { data, response, error in
                if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                    // Handle successful retry - save anchors and clean up
                    self.handleSuccessfulUpload(itemPath: itemURL.path, anchorPath: item.anchorPath, wasFullExport: item.wasFullExport ?? false)
                    try? FileManager.default.removeItem(atPath: payloadURL.path)
                }
            }
            task.resume()
        }
    }
}
