import Foundation
import HealthKit

/// Lightweight sync state - stores only sent UUIDs, not the actual data
struct SyncState: Codable {
    let userKey: String
    let fullExport: Bool
    var sentUUIDs: Set<String>
    let createdAt: Date
    
    /// Anchors data (serialized) to save after all data is sent
    var anchorsData: [String: Data]?
}

extension HealthBgSyncPlugin {
    
    // MARK: - Sync State File
    
    internal func syncStateDir() -> URL {
        let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return (base ?? FileManager.default.temporaryDirectory).appendingPathComponent("health_sync_state", isDirectory: true)
    }
    
    internal func ensureSyncStateDir() {
        try? FileManager.default.createDirectory(at: syncStateDir(), withIntermediateDirectories: true)
    }
    
    internal func syncStateFilePath() -> URL {
        return syncStateDir().appendingPathComponent("state.json")
    }
    
    internal func anchorsFilePath() -> URL {
        return syncStateDir().appendingPathComponent("anchors.bin")
    }
    
    // MARK: - Save/Load Sync State
    
    internal func saveSyncState(_ state: SyncState) {
        ensureSyncStateDir()
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: syncStateFilePath(), options: .atomic)
        }
    }
    
    internal func loadSyncState() -> SyncState? {
        guard let data = try? Data(contentsOf: syncStateFilePath()),
              let state = try? JSONDecoder().decode(SyncState.self, from: data) else {
            return nil
        }
        
        // Verify state belongs to current user
        guard state.userKey == userKey() else {
            logMessage("⚠️ Sync state for different user, clearing")
            clearSyncSession()
            return nil
        }
        
        return state
    }
    
    internal func addSentUUIDs(_ uuids: [String]) {
        guard var state = loadSyncState() else { return }
        state.sentUUIDs.formUnion(uuids)
        saveSyncState(state)
    }
    
    internal func clearSyncSession() {
        try? FileManager.default.removeItem(at: syncStateFilePath())
        try? FileManager.default.removeItem(at: anchorsFilePath())
        logMessage("🧹 Cleared sync state")
    }
    
    // MARK: - Start New Sync State
    
    internal func startNewSyncState(fullExport: Bool, anchors: [String: HKQueryAnchor]) -> SyncState {
        // Save anchors to file
        var anchorsData: [String: Data] = [:]
        for (typeId, anchor) in anchors {
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) {
                anchorsData[typeId] = data
            }
        }
        
        if !anchorsData.isEmpty {
            if let serializedData = try? NSKeyedArchiver.archivedData(withRootObject: anchorsData, requiringSecureCoding: true) {
                ensureSyncStateDir()
                try? serializedData.write(to: anchorsFilePath(), options: .atomic)
            }
        }
        
        let state = SyncState(
            userKey: userKey(),
            fullExport: fullExport,
            sentUUIDs: [],
            createdAt: Date(),
            anchorsData: nil
        )
        
        saveSyncState(state)
        return state
    }
    
    // MARK: - Finalize Sync (save anchors)
    
    internal func finalizeSyncState() {
        guard let state = loadSyncState() else { return }
        
        // Load and save anchors
        if let anchorData = try? Data(contentsOf: anchorsFilePath()),
           let anchorsDict = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSDictionary.self, NSString.self, NSData.self], from: anchorData) as? [String: Data] {
            for (typeId, data) in anchorsDict {
                saveAnchorData(data, typeIdentifier: typeId, userKey: state.userKey)
            }
            logMessage("✅ Saved anchors for \(anchorsDict.count) types")
        }
        
        // Mark full export as complete if needed
        if state.fullExport {
            let fullDoneKey = "fullDone.\(state.userKey)"
            defaults.set(true, forKey: fullDoneKey)
            defaults.synchronize()
            logMessage("✅ Marked full export complete")
        }
        
        // Clear state
        clearSyncSession()
    }
    
    // MARK: - Check for Resumable Session
    
    internal func hasResumableSyncSession() -> Bool {
        guard let state = loadSyncState() else { return false }
        return !state.sentUUIDs.isEmpty
    }
    
    // MARK: - Filter Already Sent Samples
    
    internal func filterSentSamples(_ samples: [HKSample]) -> [HKSample] {
        guard let state = loadSyncState() else { return samples }
        
        let sentUUIDs = state.sentUUIDs
        if sentUUIDs.isEmpty { return samples }
        
        let filtered = samples.filter { !sentUUIDs.contains($0.uuid.uuidString) }
        let skipped = samples.count - filtered.count
        
        if skipped > 0 {
            logMessage("⏭️ Skipping \(skipped) already sent samples")
        }
        
        return filtered
    }
    
    // MARK: - Get Sync Status for Flutter
    
    internal func getSyncStatusDict() -> [String: Any] {
        if let state = loadSyncState() {
            return [
                "hasResumableSession": !state.sentUUIDs.isEmpty,
                "sentCount": state.sentUUIDs.count,
                "isFullExport": state.fullExport,
                "createdAt": ISO8601DateFormatter().string(from: state.createdAt)
            ]
        } else {
            return [
                "hasResumableSession": false,
                "sentCount": 0,
                "isFullExport": false,
                "createdAt": NSNull()
            ]
        }
    }
    
    // MARK: - Legacy compatibility (for old session files)
    
    internal func loadSyncSession() -> SyncState? {
        return loadSyncState()
    }
}
