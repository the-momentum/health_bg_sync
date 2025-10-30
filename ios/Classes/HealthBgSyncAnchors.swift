import Foundation
import HealthKit

extension HealthBgSyncPlugin {

    // MARK: - Keys (per-endpoint)
    internal func endpointKey() -> String {
        guard let s = endpoint?.absoluteString, !s.isEmpty else { return "endpoint.none" }
        // Simple safe key for UserDefaults (no CryptoKit)
        let safe = s.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return "ep.\(safe)"
    }

    internal func anchorKey(for type: HKSampleType) -> String { "anchor.\(endpointKey()).\(type.identifier)" }
    internal func fullDoneKey() -> String { "fullDone.\(endpointKey())" }

    // Identifier-based variants (to store anchors without needing HKSampleType in memory)
    internal func anchorKey(typeIdentifier: String, endpointKey: String) -> String {
        return "anchor.\(endpointKey).\(typeIdentifier)"
    }

    internal func saveAnchorData(_ data: Data, typeIdentifier: String, endpointKey: String) {
        defaults.set(data, forKey: anchorKey(typeIdentifier: typeIdentifier, endpointKey: endpointKey))
    }

    // MARK: - Anchors
    internal func loadAnchor(for type: HKSampleType) -> HKQueryAnchor? {
        guard let data = defaults.data(forKey: anchorKey(for: type)) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    internal func saveAnchor(_ anchor: HKQueryAnchor, for type: HKSampleType) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) {
            defaults.set(data, forKey: anchorKey(for: type))
        }
    }

    internal func resetAllAnchors() {
        for t in trackedTypes { defaults.removeObject(forKey: anchorKey(for: t)) }
        defaults.set(false, forKey: fullDoneKey())
    }

    // MARK: - Initial sync plan
    internal func initialSyncKickoff(completion: @escaping ()->Void) {
        let fullDone = defaults.bool(forKey: fullDoneKey())
        if fullDone {
            // Endpoint already completed full export → do incremental only
            print("✅ Full export already done, performing incremental sync only")
            syncAll(fullExport: false, completion: completion)
        } else {
            // First time for this endpoint → perform full export
            // Note: fullDone will be marked true AFTER successful upload (in URLSessionDelegate)
            print("🔄 First time sync for this endpoint, performing full export")
            syncAll(fullExport: true, completion: completion)
        }
    }
}
