import Flutter
import UIKit
import HealthKit
import BackgroundTasks
import Network

@objc(HealthBgSyncPlugin) public class HealthBgSyncPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, URLSessionDelegate, URLSessionTaskDelegate, URLSessionDataDelegate {

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
    internal var recordsPerChunk: Int = 2000
    
    // Debouncing
    private var pendingSyncWorkItem: DispatchWorkItem?
    private let syncDebounceQueue = DispatchQueue(label: "health_sync_debounce")
    private var observerBgTask: UIBackgroundTaskIdentifier = .invalid
    
    // Sync flags
    internal var isInitialSyncInProgress = false
    private var isSyncing: Bool = false
    private let syncLock = NSLock()
    
    // Network monitoring
    private var networkMonitor: NWPathMonitor?
    private let networkMonitorQueue = DispatchQueue(label: "health_sync_network_monitor")
    private var wasDisconnected = false

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

    // Background response data buffer
    internal var backgroundDataBuffer: [Int: Data] = [:]
    private let bufferLock = NSLock()

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
    @objc public static func register(with registrar: FlutterPluginRegistrar) {
        NSLog("[HealthBgSyncPlugin] Registering plugin...")
        let channel = FlutterMethodChannel(name: "health_bg_sync", binaryMessenger: registrar.messenger())
        let instance = HealthBgSyncPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        
        let logChannel = FlutterEventChannel(name: "health_bg_sync/logs", binaryMessenger: registrar.messenger())
        instance.logEventChannel = logChannel
        logChannel.setStreamHandler(instance)
    }
    
    @objc public static func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
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
            self.stopNetworkMonitoring()
            self.cancelAllBGTasks()
            HealthBgSyncKeychain.setSyncActive(false)
            result(nil)

        case "resetAnchors":
            self.resetAllAnchors()
            result(nil)
            
        case "getSyncStatus":
            handleGetSyncStatus(result: result)
            
        case "resumeSync":
            handleResumeSync(result: result)
            
        case "clearSyncSession":
            self.clearSyncSession()
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    // MARK: - Get Sync Status
    private func handleGetSyncStatus(result: @escaping FlutterResult) {
        result(getSyncStatusDict())
    }
    
    // MARK: - Resume Sync
    private func handleResumeSync(result: @escaping FlutterResult) {
        guard hasResumableSyncSession() else {
            result(FlutterError(code: "no_session", message: "No resumable sync session", details: nil))
            return
        }
        
        // Just trigger normal sync - it will automatically filter out already sent samples
        self.syncAll(fullExport: false) {
            result(nil)
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
        self.startNetworkMonitoring()
        self.scheduleAppRefresh()
        self.scheduleProcessing()
        
        // Check for resumable sync session and resume if found
        if hasResumableSyncSession() {
            logMessage("📂 Found interrupted sync, will resume...")
            // Trigger sync - it will automatically detect and resume
            refreshTokenIfNeeded { [weak self] success in
                guard let self = self else { return }
                if success {
                    self.syncAll(fullExport: false) {
                        self.logMessage("✅ Resumed sync completed")
                    }
                } else {
                    self.logMessage("⚠️ Token refresh failed, will retry later")
                }
            }
        }
        
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
        
        // Save app credentials for token refresh (optional - only if provided)
        if let appId = args["appId"] as? String,
           let appSecret = args["appSecret"] as? String,
           let baseUrl = args["baseUrl"] as? String {
            HealthBgSyncKeychain.saveAppCredentials(appId: appId, appSecret: appSecret, baseUrl: baseUrl)
            logMessage("✅ App credentials saved for refresh")
        }
        
        // Save token expiry (60 minutes from now)
        let expiresAt = Date().addingTimeInterval(60 * 60)
        HealthBgSyncKeychain.saveTokenExpiry(expiresAt)
        
        logMessage("✅ Signed in: userId=\(userId)")
        
        // Retry pending outbox items
        self.retryOutboxIfPossible()
        
        result(nil)
    }
    
    // MARK: - Sign Out
    private func handleSignOut(result: @escaping FlutterResult) {
        logMessage("🔓 Signing out")
        
        stopBackgroundDelivery()
        stopNetworkMonitoring()
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
        self.startNetworkMonitoring()
        
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
    
    // MARK: - Helper: Get queryable types (filtering unsupported correlations)
    internal func getQueryableTypes() -> [HKSampleType] {
        // Filter out correlation types that cannot be used in authorization or queries
        // These should be accessed via their individual components instead
        let disallowedIdentifiers: Set<String> = [
            HKCorrelationTypeIdentifier.bloodPressure.rawValue
        ]
        
        return trackedTypes.filter { type in
            !disallowedIdentifiers.contains(type.identifier)
        }
    }
    
    // MARK: - Token Refresh
    internal func refreshTokenIfNeeded(completion: @escaping (Bool) -> Void) {
        // Check if token is expired
        guard HealthBgSyncKeychain.isTokenExpired() else {
            completion(true) 
            return
        }
        
        logMessage("🔄 Token expired, refreshing...")
        
        // Check if we have credentials to refresh
        guard HealthBgSyncKeychain.hasRefreshCredentials(),
              let appId = HealthBgSyncKeychain.getAppId(),
              let appSecret = HealthBgSyncKeychain.getAppSecret(),
              let baseUrl = HealthBgSyncKeychain.getBaseUrl(),
              let userId = HealthBgSyncKeychain.getUserId() else {
            logMessage("❌ Missing credentials for token refresh")
            completion(false)
            return
        }
        
        
        let urlString = "\(baseUrl)/api/v1/users/\(userId)/token"
        guard let url = URL(string: urlString) else {
            logMessage("❌ Invalid refresh URL")
            completion(false)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = ["app_id": appId, "app_secret": appSecret]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        let task = foregroundSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { completion(false); return }
            
            if let error = error {
                self.logMessage("❌ Token refresh failed: \(error.localizedDescription)")
                completion(false)
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newToken = json["access_token"] as? String else {
                self.logMessage("❌ Token refresh: invalid response")
                completion(false)
                return
            }
            
            
            let fullToken = newToken.hasPrefix("Bearer ") ? newToken : "Bearer \(newToken)"
            HealthBgSyncKeychain.saveCredentials(userId: userId, accessToken: fullToken)
            
            
            let expiresAt = Date().addingTimeInterval(60 * 60)
            HealthBgSyncKeychain.saveTokenExpiry(expiresAt)
            
            self.logMessage("✅ Token refreshed successfully")
            completion(true)
        }
        task.resume()
    }

    // MARK: - Authorization
    internal func requestAuthorization(completion: @escaping (Bool)->Void) {
        guard HKHealthStore.isHealthDataAvailable() else { 
            DispatchQueue.main.async { completion(false) }
            return 
        }
        
        let readTypes = Set(getQueryableTypes())
        
        logMessage("📡 Requesting read-only auth for \(readTypes.count) types")
        
        // Request only read permissions (no write/share)
        healthStore.requestAuthorization(toShare: nil, read: readTypes) { ok, _ in
            DispatchQueue.main.async { completion(ok) }
        }
    }

    // MARK: - Sync
    internal func syncAll(fullExport: Bool, completion: @escaping ()->Void) {
        guard !trackedTypes.isEmpty else { completion(); return }
        
        refreshTokenIfNeeded { [weak self] success in
            guard let self = self else { completion(); return }
            
            guard success else {
                self.logMessage("❌ Token refresh failed, cannot sync")
                completion()
                return
            }
            
            guard self.accessToken != nil else {
                self.logMessage("❌ No access token for sync")
                completion()
                return
            }
            self.collectAllData(fullExport: fullExport, completion: completion)
        }
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
        
        // Check if we're resuming an interrupted sync
        let existingState = loadSyncState()
        let isResuming = existingState != nil && !existingState!.sentUUIDs.isEmpty
        
        if isResuming {
            logMessage("🔄 Resuming interrupted sync (\(existingState!.sentUUIDs.count) already sent)")
        } else {
            logMessage("🔄 Collecting data (fullExport: \(fullExport))")
        }
        
        let queryableTypes = getQueryableTypes()
        
        let allSamples = NSMutableArray()
        let allAnchors = NSMutableDictionary()
        let group = DispatchGroup()
        let lock = NSLock()
        
        for type in queryableTypes {
            group.enter()
            let anchor = fullExport ? nil : loadAnchor(for: type)
            
            let query = HKAnchoredObjectQuery(type: type, predicate: nil, anchor: anchor, limit: HKObjectQueryNoLimit) {
                [weak self] _, samplesOrNil, deletedObjects, newAnchor, error in
                guard let self = self else { 
                    group.leave()
                    return 
                }
                
                if let error = error {
                    self.logMessage("❌ \(self.shortTypeName(type.identifier)): \(error.localizedDescription)")
                    group.leave()
                    return 
                }
                
                let samples = samplesOrNil ?? []
                if samples.count > 0 {
                    self.logMessage("  \(self.shortTypeName(type.identifier)): \(samples.count)")
                }
                
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
            
            var samples = allSamples.compactMap { $0 as? HKSample }
            logMessage("📊 Total from HealthKit: \(samples.count) samples")
            
            // Filter out already sent samples if resuming
            samples = self.filterSentSamples(samples)
            
            guard samples.count > 0 else { 
                self.logMessage("ℹ️ No new samples to send")
                // If we were resuming, finalize the sync
                if isResuming {
                    self.finalizeSyncState()
                }
                self.syncLock.lock()
                self.isSyncing = false
                self.isInitialSyncInProgress = false
                self.syncLock.unlock()
                completion()
                return 
            }
            
            guard let token = self.accessToken, let endpoint = self.syncEndpoint else { 
                self.logMessage("❌ No token or endpoint")
                self.syncLock.lock()
                self.isSyncing = false
                self.isInitialSyncInProgress = false
                self.syncLock.unlock()
                completion()
                return 
            }
            
            var anchors: [String: HKQueryAnchor] = [:]
            for (key, value) in allAnchors {
                if let keyString = key as? String, let anchor = value as? HKQueryAnchor {
                    anchors[keyString] = anchor
                }
            }
            
            // Start sync state if not resuming
            if !isResuming {
                _ = self.startNewSyncState(fullExport: fullExport, anchors: anchors)
            }
            
            let chunks = samples.chunked(into: self.recordsPerChunk)
            if chunks.count > 1 {
                self.logMessage("📦 Splitting into \(chunks.count) chunks")
            }
            
            if chunks.isEmpty {
                self.finalizeSyncState()
                self.syncLock.lock()
                self.isSyncing = false
                self.isInitialSyncInProgress = false
                self.syncLock.unlock()
                completion()
                return
            }
            
            self.sendChunksWithResume(
                chunks: chunks,
                anchors: anchors,
                endpoint: endpoint,
                token: token,
                fullExport: fullExport,
                chunkIndex: 0,
                totalChunks: chunks.count
            ) {
                self.syncLock.lock()
                self.isSyncing = false
                self.isInitialSyncInProgress = false
                self.syncLock.unlock()
                completion()
            }
        }
    }
    
    // MARK: - Send Chunks with UUID Tracking
    internal func sendChunksWithResume(
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
            // All done - finalize
            finalizeSyncState()
            completion()
            return
        }
        
        let chunk = chunks[chunkIndex]
        let isLastChunk = (chunkIndex == chunks.count - 1)
        
        // Count records and workouts in this chunk
        let workoutsCount = chunk.filter { $0 is HKWorkout }.count
        let recordsCount = chunk.count - workoutsCount
        var chunkDesc = "📤 Chunk \(chunkIndex + 1)/\(totalChunks): \(chunk.count) samples"
        if workoutsCount > 0 && recordsCount > 0 {
            chunkDesc += " (\(recordsCount) records, \(workoutsCount) workouts)"
        } else if workoutsCount > 0 {
            chunkDesc += " (\(workoutsCount) workouts)"
        }
        logMessage(chunkDesc)
        
        let payload = self.serializeCombined(samples: chunk, anchors: isLastChunk ? anchors : [:])
        
        // Extract UUIDs for this chunk
        let chunkUUIDs = chunk.map { $0.uuid.uuidString }
        
        self.enqueueCombinedUpload(payload: payload, anchors: isLastChunk ? anchors : [:], endpoint: endpoint, token: token, wasFullExport: fullExport && isLastChunk) { [weak self] success in
            guard let self = self else {
                completion()
                return
            }
            
            if success {
                // Mark these UUIDs as sent
                self.addSentUUIDs(chunkUUIDs)
                
                // Continue to next chunk
                self.sendChunksWithResume(
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
                self.logMessage("❌ Chunk \(chunkIndex + 1) failed, will resume later")
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
        NSLog("[HealthBgSync] %@", message)
        
        if let sink = logEventSink {
            DispatchQueue.main.async { [weak self] in
                sink(message)
            }
        }
    }
    
    /// Logs a summary of the payload (types and counts) without the full data
    internal func logPayloadSummary(_ data: Data, label: String) {
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let dataDict = jsonObject["data"] as? [String: Any] else {
            let sizeMB = Double(data.count) / (1024 * 1024)
            logMessage("\(label): \(String(format: "%.2f", sizeMB)) MB")
            return
        }
        
        var summary: [String] = []
        
        // Count records by type
        if let records = dataDict["records"] as? [[String: Any]] {
            var typeCounts: [String: Int] = [:]
            for record in records {
                if let type = record["type"] as? String {
                    // Extract short type name from full identifier
                    let shortType = type.replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
                        .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
                    typeCounts[shortType, default: 0] += 1
                }
            }
            if !typeCounts.isEmpty {
                let typesList = typeCounts.sorted { $0.value > $1.value }
                    .map { "\($0.key): \($0.value)" }
                    .joined(separator: ", ")
                summary.append("Records: \(records.count) [\(typesList)]")
            }
        }
        
        // Count workouts
        if let workouts = dataDict["workouts"] as? [[String: Any]], !workouts.isEmpty {
            var workoutTypes: [String: Int] = [:]
            for workout in workouts {
                if let type = workout["type"] as? String {
                    workoutTypes[type, default: 0] += 1
                }
            }
            let workoutsList = workoutTypes.sorted { $0.value > $1.value }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: ", ")
            summary.append("Workouts: \(workouts.count) [\(workoutsList)]")
        }
        
        let sizeMB = Double(data.count) / (1024 * 1024)
        let sizeStr = String(format: "%.2f MB", sizeMB)
        
        if summary.isEmpty {
            logMessage("\(label): \(sizeStr)")
        } else {
            logMessage("\(label): \(sizeStr) - \(summary.joined(separator: ", "))")
        }
    }
    
    // MARK: - Network Monitoring
    
    internal func startNetworkMonitoring() {
        // Don't start if already running
        guard networkMonitor == nil else { return }
        
        networkMonitor = NWPathMonitor()
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            
            let isConnected = path.status == .satisfied
            
            if isConnected {
                // Network is available
                if self.wasDisconnected {
                    self.wasDisconnected = false
                    self.logMessage("📶 Network restored")
                    self.tryResumeAfterNetworkRestored()
                }
            } else {
                // Network is not available
                if !self.wasDisconnected {
                    self.wasDisconnected = true
                    self.logMessage("📵 Network lost")
                }
            }
        }
        
        networkMonitor?.start(queue: networkMonitorQueue)
        logMessage("📡 Network monitoring started")
    }
    
    internal func stopNetworkMonitoring() {
        networkMonitor?.cancel()
        networkMonitor = nil
        wasDisconnected = false
    }
    
    /// Called when upload fails - marks network as disconnected so we can auto-resume
    internal func markNetworkError() {
        wasDisconnected = true
    }
    
    /// Try to resume sync after network is restored
    private func tryResumeAfterNetworkRestored() {
        // Wait a bit for network to stabilize
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            
            // Check if we have an interrupted sync to resume
            guard self.hasResumableSyncSession() else {
                self.logMessage("ℹ️ No sync to resume")
                return
            }
            
            // Don't resume if already syncing
            self.syncLock.lock()
            let alreadySyncing = self.isSyncing
            self.syncLock.unlock()
            
            if alreadySyncing {
                self.logMessage("⏭️ Sync already in progress")
                return
            }
            
            self.logMessage("🔄 Resuming sync after network restored...")
            self.refreshTokenIfNeeded { success in
                if success {
                    self.syncAll(fullExport: false) {
                        self.logMessage("✅ Network resume sync completed")
                    }
                } else {
                    self.logMessage("⚠️ Token refresh failed")
                }
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
    
    // MARK: - Helpers
    internal func shortTypeName(_ identifier: String) -> String {
        return identifier
            .replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKWorkoutType", with: "Workout")
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
