import Foundation

extension HealthBgSyncPlugin {

    // MARK: - URLSession delegate
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        print("📡 URLSession delegate called for task \(task.taskIdentifier)")
        
        guard let desc = task.taskDescription else { 
            print("⚠️ No taskDescription found")
            return 
        }
        let parts = desc.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let itemPath = parts.count > 0 ? parts[0] : ""
        let payloadPath = parts.count > 1 ? parts[1] : ""
        let anchorPath = parts.count > 2 ? parts[2] : ""
        
        print("📡 Task description: itemPath=\(itemPath.isEmpty ? "empty" : "found"), payloadPath=\(payloadPath.isEmpty ? "empty" : "found")")

        defer {
            if !payloadPath.isEmpty { try? FileManager.default.removeItem(atPath: payloadPath) }
            if error == nil, !itemPath.isEmpty { try? FileManager.default.removeItem(atPath: itemPath) }
        }

        // Transport error → keep manifest + anchor for retry
        if let error = error {
            let nsError = error as NSError
            // Don't log cancelled requests (error -999) as they're normal
            if nsError.code != NSURLErrorCancelled {
                print("⛔️ background upload failed: \(error.localizedDescription)")
            }
            return
        }

        // Log response details
        if let http = task.response as? HTTPURLResponse {
            print("📥 HTTP Response for task \(task.taskIdentifier): Status \(http.statusCode)")
            if let url = http.url {
                print("📥 Response URL: \(url.absoluteString)")
            }

            // Log response body if available
            if let data = backgroundDataBuffer[task.taskIdentifier] {
                if let responseString = String(data: data, encoding: .utf8) {
                    print("📥 Response Body: \(responseString)")
                }
                backgroundDataBuffer.removeValue(forKey: task.taskIdentifier)
            }
        } else {
            print("⚠️ No HTTP response received for task \(task.taskIdentifier)")
        }
        
        // Only treat 2xx as success (HEAD/redirects can happen in background)
        if let http = task.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            print("⛔️ upload HTTP \(http.statusCode) — keep item for retry")
            return
        }

        // SUCCESS: save anchor BASED ON MANIFEST — no need to have trackedTypes in memory
        if !itemPath.isEmpty,
           let itemData = try? Data(contentsOf: URL(fileURLWithPath: itemPath)),
           let item = try? JSONDecoder().decode(OutboxItem.self, from: itemData) {
            
            // Handle combined anchors differently
            if item.typeIdentifier == "combined" {
                // For combined uploads, save all anchors
                if !anchorPath.isEmpty,
                   let anchorData = try? Data(contentsOf: URL(fileURLWithPath: anchorPath)),
                   let anchorsDict = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSDictionary.self, NSString.self, NSData.self], from: anchorData) as? [String: Data] {
                    for (typeId, anchorData) in anchorsDict {
                        saveAnchorData(anchorData, typeIdentifier: typeId, userKey: item.userKey)
                    }
                    print("✅ Saved anchors for \(anchorsDict.count) types after successful upload")
                }
                
                // Mark full export as done if this was a full export
                if item.wasFullExport == true {
                    let fullDoneKey = "fullDone.\(item.userKey)"
                    let defaults = UserDefaults(suiteName: "com.healthbgsync.state") ?? .standard
                    defaults.set(true, forKey: fullDoneKey)
                    defaults.synchronize()
                    print("✅ Marked full export as complete for user: \(item.userKey)")
                }
            } else {
                // For single type uploads, save single anchor
                if !anchorPath.isEmpty,
                   let anchorData = try? Data(contentsOf: URL(fileURLWithPath: anchorPath)) {
                    saveAnchorData(anchorData, typeIdentifier: item.typeIdentifier, userKey: item.userKey)
                }
            }
            if !anchorPath.isEmpty {
                try? FileManager.default.removeItem(atPath: anchorPath)
            }
            
            print("✅ Upload successful for \(item.typeIdentifier)")
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        print("📡 urlSessionDidFinishEvents called")
        if let handler = HealthBgSyncPlugin.bgCompletionHandler {
            HealthBgSyncPlugin.bgCompletionHandler = nil
            handler()
        }
    }
    
    // Track upload progress
    public func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend) * 100
        if Int(progress) % 20 == 0 || progress > 99 {
            print("📤 Upload progress for task \(task.taskIdentifier): \(String(format: "%.1f", progress))% (\(totalBytesSent)/\(totalBytesExpectedToSend) bytes)")
        }
    }
    
    // Handle task completion with response
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let httpResponse = response as? HTTPURLResponse {
            print("📥 Received HTTP response: \(httpResponse.statusCode) for task \(dataTask.taskIdentifier)")
        }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if backgroundDataBuffer[dataTask.taskIdentifier] == nil {
            backgroundDataBuffer[dataTask.taskIdentifier] = data
        } else {
            backgroundDataBuffer[dataTask.taskIdentifier]?.append(data)
        }
    }
}
