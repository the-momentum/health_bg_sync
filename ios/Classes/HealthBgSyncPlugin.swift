import Flutter
import UIKit
import HealthKit
import BackgroundTasks

public class HealthBgSyncPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, URLSessionDelegate, URLSessionTaskDelegate {

    // MARK: - Configuration State
    internal var baseUrl: String?
    internal var customSyncUrl: String?
    
    // MARK: - User State (loaded from Keychain)
    internal var userId: String? { HealthBgSyncKeychain.getUserId() }
    internal var accessToken: String? { HealthBgSyncKeychain.getAccessToken() }
    
    // MARK: - HealthKit State
    internal let healthStore = HKHealthStore()
    internal var session: URLSession!
    internal var foregroundSession: URLSession!
    internal var trackedTypes: [HKSampleType] = []
    internal var chunkSize: Int = 1000
    internal var backgroundChunkSize: Int = 100
    internal var recordsPerChunk: Int = 10000
    
    // Debouncing
    private var pendingSyncWorkItem: DispatchWorkItem?
    private let syncDebounceQueue = DispatchQueue(label: "health_sync_debounce")
    private var observerBgTask: UIBackgroundTaskIdentifier = .invalid
    
    // Sync flags
    internal var isInitialSyncInProgress = false
    private var isSyncing: Bool = false
    private let syncLock = NSLock()

    // Per-user state (anchors)
    internal let defaults = UserDefaults(suiteName: "com.healthbgsync.state") ?? .standard

    // Observer queries
    internal var activeObserverQueries: [HKObserverQuery] = []

    // Background session
    internal let bgSessionId = "com.healthbgsync.upload.session"

    // BGTask identifiers
    internal let refreshTaskId  = "com.healthbgsync.task.refresh"
    internal let processTaskId  = "com.healthbgsync.task.process"

    internal static var bgCompletionHandler: (() -> Void)?
    
    // Log event sink
    private var logEventSink: FlutterEventSink?
    private var logEventChannel: FlutterEventChannel?

    // MARK: - API Endpoints
    
    /// Endpoint to upload health data for the current user
    internal var syncEndpoint: URL? {
        guard let userId = userId else { return nil }
        
        // Use custom URL if provided (replace {userId} or {user_id} placeholders)
        if let customUrl = customSyncUrl {
            let urlString = customUrl
                .replacingOccurrences(of: "{userId}", with: userId)
                .replacingOccurrences(of: "{user_id}", with: userId)
            return URL(string: urlString)
        }
        
        // Default endpoint
        guard let baseUrl = baseUrl else { return nil }
        return URL(string: "\(baseUrl)/sdk/users/\(userId)/sync/apple/healthion")
    }

    // MARK: - Flutter registration
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "health_bg_sync", binaryMessenger: registrar.messenger())
        let instance = HealthBgSyncPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        
        let logChannel = FlutterEventChannel(name: "health_bg_sync/logs", binaryMessenger: registrar.messenger())
        instance.logEventChannel = logChannel
        logChannel.setStreamHandler(instance)
    }

    public static func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        HealthBgSyncPlugin.bgCompletionHandler = handler
    }

    // MARK: - Init
    override init() {
        super.init()
        
        let bgCfg = URLSessionConfiguration.background(withIdentifier: bgSessionId)
        bgCfg.isDiscretionary = false
        bgCfg.waitsForConnectivity = true
        self.session = URLSession(configuration: bgCfg, delegate: self, delegateQueue: nil)
        
        let fgCfg = URLSessionConfiguration.default
        fgCfg.timeoutIntervalForRequest = 120
        fgCfg.timeoutIntervalForResource = 600
        fgCfg.waitsForConnectivity = false
        self.foregroundSession = URLSession(configuration: fgCfg, delegate: nil, delegateQueue: OperationQueue.main)

        if #available(iOS 13.0, *) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskId, using: nil) { [weak self] task in
                self?.handleAppRefresh(task: task as! BGAppRefreshTask)
            }
            BGTaskScheduler.shared.register(forTaskWithIdentifier: processTaskId, using: nil) { [weak self] task in
                self?.handleProcessing(task: task as! BGProcessingTask)
            }
        }
    }

    // MARK: - MethodChannel
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {

        case "configure":
            handleConfigure(call: call, result: result)

        case "signIn":
            handleSignIn(call: call, result: result)
            
        case "signOut":
            handleSignOut(result: result)
            
        case "restoreSession":
            handleRestoreSession(result: result)
            
        case "isSessionValid":
            result(HealthBgSyncKeychain.hasSession())
            
        case "isSyncActive":
            result(HealthBgSyncKeychain.isSyncActive())
            
        case "getStoredCredentials":
            let credentials: [String: Any?] = [
                "userId": HealthBgSyncKeychain.getUserId(),
                "accessToken": HealthBgSyncKeychain.getAccessToken(),
                "customSyncUrl": HealthBgSyncKeychain.getCustomSyncUrl(),
                "isSyncActive": HealthBgSyncKeychain.isSyncActive()
            ]
            result(credentials)

        case "requestAuthorization":
            handleRequestAuthorization(call: call, result: result)

        case "syncNow":
            self.syncAll(fullExport: false) { result(nil) }

        case "startBackgroundSync":
            handleStartBackgroundSync(result: result)

        case "stopBackgroundSync":
            self.stopBackgroundDelivery()
            self.cancelAllBGTasks()
            HealthBgSyncKeychain.setSyncActive(false)
            result(nil)

        case "resetAnchors":
            self.resetAllAnchors()
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    // MARK: - Configure
    private func handleConfigure(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let baseUrl = args["baseUrl"] as? String else {
            result(FlutterError(code: "bad_args", message: "Missing baseUrl", details: nil))
            return
        }
        
        // Clear Keychain if app was reinstalled
        HealthBgSyncKeychain.clearKeychainIfReinstalled()
        
        self.baseUrl = baseUrl
        
        // Use provided customSyncUrl, or restore from storage
        if let providedCustomUrl = args["customSyncUrl"] as? String {
            self.customSyncUrl = providedCustomUrl
            HealthBgSyncKeychain.saveCustomSyncUrl(providedCustomUrl)
        } else if let storedCustomUrl = HealthBgSyncKeychain.getCustomSyncUrl() {
            self.customSyncUrl = storedCustomUrl
        }
        
        // Restore tracked types if available
        if let storedTypes = HealthBgSyncKeychain.getTrackedTypes() {
            self.trackedTypes = mapTypes(storedTypes)
            logMessage("📋 Restored \(trackedTypes.count) tracked types")
        }
        
        if let customUrl = self.customSyncUrl {
            logMessage("✅ Configured: customSyncUrl=\(customUrl)")
        } else {
            logMessage("✅ Configured: baseUrl=\(baseUrl)")
        }
        
        // Auto-start sync if was previously active and session exists
        if HealthBgSyncKeychain.isSyncActive() && HealthBgSyncKeychain.hasSession() && !trackedTypes.isEmpty {
            logMessage("🔄 Auto-restoring background sync...")
            DispatchQueue.main.async { [weak self] in
                self?.autoRestoreSync()
            }
        }
        
        result(nil)
    }
    
    // MARK: - Auto Restore Sync
    private func autoRestoreSync() {
        guard userId != nil, accessToken != nil else {
            logMessage("⚠️ Cannot auto-restore: no session")
            return
        }
        
        self.startBackgroundDelivery()
        self.scheduleAppRefresh()
        self.scheduleProcessing()
        
        logMessage("✅ Background sync auto-restored")
    }
    
    // MARK: - Sign In (with userId and accessToken)
    private func handleSignIn(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let userId = args["userId"] as? String,
              let accessToken = args["accessToken"] as? String else {
            result(FlutterError(code: "bad_args", message: "Missing userId or accessToken", details: nil))
            return
        }
        
        // Save to Keychain
        HealthBgSyncKeychain.saveCredentials(userId: userId, accessToken: accessToken)
        
        logMessage("✅ Signed in: userId=\(userId)")
        
        // Retry pending outbox items
        self.retryOutboxIfPossible()
        
        result(nil)
    }
    
    // MARK: - Sign Out
    private func handleSignOut(result: @escaping FlutterResult) {
        logMessage("🔓 Signing out")
        
        stopBackgroundDelivery()
        cancelAllBGTasks()
        
        // Clear Keychain
        HealthBgSyncKeychain.clearAll()
        
        result(nil)
    }
    
    // MARK: - Restore Session
    private func handleRestoreSession(result: @escaping FlutterResult) {
        if HealthBgSyncKeychain.hasSession(),
           let userId = HealthBgSyncKeychain.getUserId() {
            logMessage("📱 Session restored: userId=\(userId)")
            result(userId)
        } else {
            result(nil)
        }
    }
    
    // MARK: - Request Authorization
    private func handleRequestAuthorization(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let types = args["types"] as? [String] else {
            result(FlutterError(code: "bad_args", message: "Missing types", details: nil))
            return
        }
        
        self.trackedTypes = mapTypes(types)
        
        // Save tracked types for restoration after restart
        HealthBgSyncKeychain.saveTrackedTypes(types)
        
        logMessage("📋 Requesting auth for \(trackedTypes.count) types")
        
        requestAuthorization { ok in
            result(ok)
        }
    }
    
    // MARK: - Start Background Sync
    private func handleStartBackgroundSync(result: @escaping FlutterResult) {
        guard userId != nil, accessToken != nil else {
            result(FlutterError(code: "not_signed_in", message: "Not signed in", details: nil))
            return
        }
        
        self.startBackgroundDelivery()
        
        self.initialSyncKickoff { started in
            if started {
                self.logMessage("✅ Sync started")
            } else {
                self.logMessage("❌ Sync failed to start")
                self.isInitialSyncInProgress = false
            }
        }
        
        self.scheduleAppRefresh()
        self.scheduleProcessing()
        
        let canStart = HKHealthStore.isHealthDataAvailable() &&
                      self.syncEndpoint != nil &&
                      self.accessToken != nil &&
                      !self.trackedTypes.isEmpty
        
        // Save sync active state for restoration after restart
        if canStart {
            HealthBgSyncKeychain.setSyncActive(true)
        }
        
        result(canStart)
    }
    
    // MARK: - Get Access Token
    internal func getAccessToken() -> String? {
        return accessToken
    }

    // MARK: - Authorization
    internal func requestAuthorization(completion: @escaping (Bool)->Void) {
        guard HKHealthStore.isHealthDataAvailable() else { 
            DispatchQueue.main.async { completion(false) }
            return 
        }
        
        let toRead = Set(trackedTypes.filter { !($0 is HKCorrelationType) })
        
        healthStore.requestAuthorization(toShare: nil, read: toRead) { ok, _ in
            DispatchQueue.main.async { completion(ok) }
        }
    }

    // MARK: - Sync
    internal func syncAll(fullExport: Bool, completion: @escaping ()->Void) {
        guard !trackedTypes.isEmpty else { completion(); return }
        
        guard accessToken != nil else {
            logMessage("❌ No access token for sync")
            completion()
            return
        }
        collectAllData(fullExport: fullExport, completion: completion)
    }
    
    // MARK: - Debounced sync
    internal func triggerCombinedSync() {
        if isInitialSyncInProgress {
            logMessage("⏭️ Skipping - initial sync in progress")
            return
        }
        
        if observerBgTask == .invalid {
            observerBgTask = UIApplication.shared.beginBackgroundTask(withName: "health_combined_sync") {
                self.logMessage("⚠️ Background task expired")
                UIApplication.shared.endBackgroundTask(self.observerBgTask)
                self.observerBgTask = .invalid
            }
        }
        
        pendingSyncWorkItem?.cancel()
        
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.syncAll(fullExport: false) {
                if self.observerBgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(self.observerBgTask)
                    self.observerBgTask = .invalid
                }
            }
        }
        
        pendingSyncWorkItem = workItem
        syncDebounceQueue.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }
    
    // MARK: - Data collection
    internal func collectAllData(fullExport: Bool, completion: @escaping ()->Void) {
        collectAllData(fullExport: fullExport, isBackground: false, completion: completion)
    }
    
    internal func collectAllData(fullExport: Bool, isBackground: Bool, completion: @escaping ()->Void) {
        syncLock.lock()
        if isSyncing {
            logMessage("⚠️ Sync in progress, skipping")
            syncLock.unlock()
            completion()
            return
        }
        isSyncing = true
        syncLock.unlock()
        
        guard HKHealthStore.isHealthDataAvailable() else {
            logMessage("❌ HealthKit not available")
            syncLock.lock()
            isSyncing = false
            isInitialSyncInProgress = false
            syncLock.unlock()
            completion()
            return
        }
        
        logMessage("🔄 Collecting data (fullExport: \(fullExport))")
        
        let allSamples = NSMutableArray()
        let allAnchors = NSMutableDictionary()
        let group = DispatchGroup()
        let lock = NSLock()
        
        for type in trackedTypes {
            group.enter()
            let anchor = fullExport ? nil : loadAnchor(for: type)
            
            let query = HKAnchoredObjectQuery(type: type, predicate: nil, anchor: anchor, limit: HKObjectQueryNoLimit) {
                [weak self] _, samplesOrNil, deletedObjects, newAnchor, error in
                guard let self = self else { 
                    group.leave()
                    return 
                }
                
                if let error = error {
                    self.logMessage("❌ \(type.identifier): \(error.localizedDescription)")
                    group.leave()
                    return 
                }
                
                let samples = samplesOrNil ?? []
                self.logMessage("✅ \(type.identifier): \(samples.count)")
                
                lock.lock()
                allSamples.addObjects(from: samples)
                if let newAnchor = newAnchor {
                    allAnchors[type.identifier] = newAnchor
                }
                lock.unlock()
                group.leave()
            }
            
            healthStore.execute(query)
        }
        
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { 
                completion()
                return 
            }
            
            logMessage("✅ Total: \(allSamples.count) samples")
            
            self.syncLock.lock()
            self.isSyncing = false
            self.isInitialSyncInProgress = false
            self.syncLock.unlock()
            
            guard allSamples.count > 0 else { 
                self.logMessage("ℹ️ No samples")
                completion()
                return 
            }
            
            guard let token = self.accessToken, let endpoint = self.syncEndpoint else { 
                self.logMessage("❌ No token or endpoint")
                completion()
                return 
            }
            
            let samples = allSamples.compactMap { $0 as? HKSample }
            var anchors: [String: HKQueryAnchor] = [:]
            for (key, value) in allAnchors {
                if let keyString = key as? String, let anchor = value as? HKQueryAnchor {
                    anchors[keyString] = anchor
                }
            }
            
            let chunks = samples.chunked(into: self.recordsPerChunk)
            self.logMessage("📦 \(chunks.count) chunk(s)")
            
            if chunks.isEmpty {
                completion()
                return
            }
            
            self.sendChunksSequentially(
                chunks: chunks,
                anchors: anchors,
                endpoint: endpoint,
                token: token,
                fullExport: fullExport,
                chunkIndex: 0,
                totalChunks: chunks.count,
                completion: completion
            )
        }
    }
    
    // MARK: - Send chunks
    internal func sendChunksSequentially(
        chunks: [[HKSample]],
        anchors: [String: HKQueryAnchor],
        endpoint: URL,
        token: String,
        fullExport: Bool,
        chunkIndex: Int,
        totalChunks: Int,
        completion: @escaping ()->Void
    ) {
        guard chunkIndex < chunks.count else {
            completion()
            return
        }
        
        let chunk = chunks[chunkIndex]
        let isLastChunk = (chunkIndex == chunks.count - 1)
        
        logMessage("📤 Chunk \(chunkIndex + 1)/\(totalChunks)")
        
        let payload = self.serializeCombined(samples: chunk, anchors: isLastChunk ? anchors : [:])
        let wasFullExport = fullExport && isLastChunk
        
        self.enqueueCombinedUpload(payload: payload, anchors: isLastChunk ? anchors : [:], endpoint: endpoint, token: token, wasFullExport: wasFullExport) { [weak self] success in
            guard let self = self else {
                completion()
                return
            }
            
            if success {
                self.logMessage("✅ Chunk \(chunkIndex + 1) sent")
                self.sendChunksSequentially(
                    chunks: chunks,
                    anchors: anchors,
                    endpoint: endpoint,
                    token: token,
                    fullExport: fullExport,
                    chunkIndex: chunkIndex + 1,
                    totalChunks: totalChunks,
                    completion: completion
                )
            } else {
                self.logMessage("❌ Chunk \(chunkIndex + 1) failed")
                completion()
            }
        }
    }

    internal func syncType(_ type: HKSampleType, fullExport: Bool, completion: @escaping ()->Void) {
        let anchor = fullExport ? nil : loadAnchor(for: type)
        
        let query = HKAnchoredObjectQuery(type: type, predicate: nil, anchor: anchor, limit: chunkSize) {
            [weak self] _, samplesOrNil, deletedObjects, newAnchor, error in
            guard let self = self else { completion(); return }
            guard error == nil else { completion(); return }

            let samples = samplesOrNil ?? []
            guard !samples.isEmpty else { completion(); return }
            
            guard let token = self.accessToken, let endpoint = self.syncEndpoint else { 
                completion()
                return 
            }

            let payload = self.serialize(samples: samples, type: type)
            self.enqueueBackgroundUpload(payload: payload, type: type, candidateAnchor: newAnchor, endpoint: endpoint, token: token) {
                if samples.count == self.chunkSize {
                    self.syncType(type, fullExport: false, completion: completion)
                } else {
                    completion()
                }
            }
        }
        healthStore.execute(query)
    }
    
    // MARK: - Logging
    internal func logMessage(_ message: String) {
        print(message)
        
        if let sink = logEventSink {
            DispatchQueue.main.async { [weak self] in
                sink(message)
            }
        }
    }
    
    // MARK: - FlutterStreamHandler
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        logEventSink = events
        return nil
    }
    
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        logEventSink = nil
        return nil
    }
}

// MARK: - Array extension
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
