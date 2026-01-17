import Foundation
import HealthKit

/// Progress tracking per data type - memory efficient
struct TypeSyncProgress: Codable {
    let typeIdentifier: String
    var sentCount: Int
    var isComplete: Bool
    /// Anchor data to save after type is fully synced
    var pendingAnchorData: Data?
}

/// Lightweight sync state - tracks progress per type instead of all UUIDs
struct SyncState: Codable {
    let userKey: String
    let fullExport: Bool
    let createdAt: Date
    
    /// Progress per type - much more memory efficient than storing all UUIDs
    var typeProgress: [String: TypeSyncProgress]
    
    /// Total samples sent across all types
    var totalSentCount: Int
    
    /// Types that have been fully processed
    var completedTypes: Set<String>
    
    /// Index of current type being processed (for resume)
    var currentTypeIndex: Int
    
    // MARK: - Computed properties
    
    var hasProgress: Bool {
        return totalSentCount > 0 || !completedTypes.isEmpty
    }
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
    
    /// Update progress for a specific type after sending a chunk
    internal func updateTypeProgress(typeIdentifier: String, sentInChunk: Int, isComplete: Bool, anchorData: Data?) {
        guard var state = loadSyncState() else { return }
        
        var progress = state.typeProgress[typeIdentifier] ?? TypeSyncProgress(
            typeIdentifier: typeIdentifier,
            sentCount: 0,
            isComplete: false,
            pendingAnchorData: nil
        )
        
        progress.sentCount += sentInChunk
        progress.isComplete = isComplete
        if let anchorData = anchorData {
            progress.pendingAnchorData = anchorData
        }
        
        state.typeProgress[typeIdentifier] = progress
        state.totalSentCount += sentInChunk
        
        if isComplete {
            state.completedTypes.insert(typeIdentifier)
            // Save anchor immediately when type is complete
            if let anchorData = progress.pendingAnchorData {
                saveAnchorData(anchorData, typeIdentifier: typeIdentifier, userKey: state.userKey)
            }
        }
        
        saveSyncState(state)
    }
    
    /// Mark current type index for resume
    internal func updateCurrentTypeIndex(_ index: Int) {
        guard var state = loadSyncState() else { return }
        state.currentTypeIndex = index
        saveSyncState(state)
    }
    
    internal func clearSyncSession() {
        try? FileManager.default.removeItem(at: syncStateFilePath())
        try? FileManager.default.removeItem(at: anchorsFilePath())
        logMessage("🧹 Cleared sync state")
    }
    
    // MARK: - Start New Sync State
    
    internal func startNewSyncState(fullExport: Bool, types: [HKSampleType]) -> SyncState {
        let state = SyncState(
            userKey: userKey(),
            fullExport: fullExport,
            createdAt: Date(),
            typeProgress: [:],
            totalSentCount: 0,
            completedTypes: [],
            currentTypeIndex: 0
        )
        
        saveSyncState(state)
        return state
    }
    
    // MARK: - Finalize Sync (mark complete)
    
    internal func finalizeSyncState() {
        guard let state = loadSyncState() else { return }
        
        // Mark full export as complete if needed
        if state.fullExport {
            let fullDoneKey = "fullDone.\(state.userKey)"
            defaults.set(true, forKey: fullDoneKey)
            defaults.synchronize()
            logMessage("✅ Marked full export complete")
        }
        
        logMessage("✅ Sync complete: \(state.totalSentCount) samples across \(state.completedTypes.count) types")
        
        // Clear state
        clearSyncSession()
    }
    
    // MARK: - Check for Resumable Session
    
    internal func hasResumableSyncSession() -> Bool {
        guard let state = loadSyncState() else { return false }
        return state.hasProgress
    }
    
    /// Check if a specific type needs to be synced (not yet completed)
    internal func shouldSyncType(_ typeIdentifier: String) -> Bool {
        guard let state = loadSyncState() else { return true }
        return !state.completedTypes.contains(typeIdentifier)
    }
    
    /// Get the starting type index for resume
    internal func getResumeTypeIndex() -> Int {
        guard let state = loadSyncState() else { return 0 }
        return state.currentTypeIndex
    }
    
    // MARK: - Get Sync Status for Flutter
    
    internal func getSyncStatusDict() -> [String: Any] {
        if let state = loadSyncState() {
            return [
                "hasResumableSession": state.hasProgress,
                "sentCount": state.totalSentCount,
                "completedTypes": state.completedTypes.count,
                "isFullExport": state.fullExport,
                "createdAt": ISO8601DateFormatter().string(from: state.createdAt)
            ]
        } else {
            return [
                "hasResumableSession": false,
                "sentCount": 0,
                "completedTypes": 0,
                "isFullExport": false,
                "createdAt": NSNull()
            ]
        }
    }
    
    // MARK: - Legacy compatibility
    
    internal func loadSyncSession() -> SyncState? {
        return loadSyncState()
    }
}
