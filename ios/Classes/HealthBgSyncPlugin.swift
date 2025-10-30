import Flutter
import UIKit
import HealthKit
import BackgroundTasks

public class HealthBgSyncPlugin: NSObject, FlutterPlugin, URLSessionDelegate, URLSessionTaskDelegate {

    // MARK: - State
    internal let healthStore = HKHealthStore()
    internal var session: URLSession! // Background session
    internal var foregroundSession: URLSession! // Foreground session for immediate uploads
    internal var endpoint: URL?
    internal var token: String?
    internal var trackedTypes: [HKSampleType] = []
    internal var chunkSize: Int = 1000 // Configurable chunk size to prevent HTTP 413 errors
    internal var backgroundChunkSize: Int = 100 // Smaller chunk size for background operations
    internal var recordsPerChunk: Int = 10000 // Maximum records per HTTP request to prevent timeouts (~2-3MB per chunk)
    
    // Debouncing for observer queries to collect all changes before sending
    private var pendingSyncWorkItem: DispatchWorkItem?
    private let syncDebounceQueue = DispatchQueue(label: "health_sync_debounce")
    private var observerBgTask: UIBackgroundTaskIdentifier = .invalid
    private var isSyncing: Bool = false // Prevent concurrent syncs
    private let syncLock = NSLock()

    // Per-endpoint state (anchors + full-export-done flag)
    internal let defaults = UserDefaults(suiteName: "com.healthbgsync.state") ?? .standard

    // Observer queries for background delivery
    internal var activeObserverQueries: [HKObserverQuery] = []

    // Background session identifier
    internal let bgSessionId = "com.healthbgsync.upload.session"

    // BGTask identifiers (MUST be present in Info.plist -> BGTaskSchedulerPermittedIdentifiers)
    internal let refreshTaskId  = "com.healthbgsync.task.refresh"
    internal let processTaskId  = "com.healthbgsync.task.process"

    // AppDelegate will pass its background completion handler here
    internal static var bgCompletionHandler: (() -> Void)?

    // MARK: - Flutter registration
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "health_bg_sync", binaryMessenger: registrar.messenger())
        let instance = HealthBgSyncPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    // Call from AppDelegate.handleEventsForBackgroundURLSession
    public static func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        HealthBgSyncPlugin.bgCompletionHandler = handler
    }

    // MARK: - Init
    override init() {
        super.init()
        
        // Background session for true background uploads
        let bgCfg = URLSessionConfiguration.background(withIdentifier: bgSessionId)
        bgCfg.isDiscretionary = false
        bgCfg.waitsForConnectivity = true
        self.session = URLSession(configuration: bgCfg, delegate: self, delegateQueue: nil)
        
        // Foreground session for immediate uploads when app is active
        // Use default session with main queue for immediate completion handlers
        let fgCfg = URLSessionConfiguration.default
        fgCfg.timeoutIntervalForRequest = 120 // 2 minutes for request timeout
        fgCfg.timeoutIntervalForResource = 600 // 10 minutes for total resource timeout
        fgCfg.waitsForConnectivity = false // Don't wait, fail fast
        self.foregroundSession = URLSession(configuration: fgCfg, delegate: nil, delegateQueue: OperationQueue.main)

        // Register BGTasks (iOS 13+)
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

        case "initialize":
            guard let args = call.arguments as? [String: Any],
                  let endpointStr = args["endpoint"] as? String,
                  let token = args["token"] as? String,
                  let types = args["types"] as? [String] else {
                result(FlutterError(code: "bad_args", message: "Missing args", details: nil))
                return
            }
            self.endpoint = URL(string: endpointStr)
            self.token = token
            self.trackedTypes = mapTypes(types)

            // Configure chunk size if provided (default: 1000)
            if let chunkSizeArg = args["chunkSize"] as? Int, chunkSizeArg > 0 {
                self.chunkSize = chunkSizeArg
            }
            
            // Configure records per HTTP request chunk if provided (default: 10000)
            if let recordsPerChunkArg = args["recordsPerChunk"] as? Int, recordsPerChunkArg > 0 {
                self.recordsPerChunk = recordsPerChunkArg
            }

            print("✅ Initialized for endpointKey=\(endpointKey()) types=\(trackedTypes.map{$0.identifier}) chunkSize=\(chunkSize) recordsPerChunk=\(recordsPerChunk)")

            // Retry pending outbox items (if any)
            retryOutboxIfPossible()

            // Note: Initial sync will be triggered by startBackgroundSync(), not here
            // This ensures proper flow: initialize → requestAuthorization → startBackgroundSync
            result(nil)

        case "requestAuthorization":
            requestAuthorization { ok in result(ok) }

        case "syncNow":
            // Manual incremental sync (does not trigger full export)
            self.syncAll(fullExport: false) { result(nil) }

        case "startBackgroundSync":
            // Register observers for background delivery of new health data
            self.startBackgroundDelivery()
            
            // Perform initial full sync if not done yet (will be incremental after first sync)
            self.initialSyncKickoff {
                print("✅ Initial sync completed")
            }
            
            // Schedule fallback BG tasks for catch-up syncing
            self.scheduleAppRefresh()
            self.scheduleProcessing()
            result(nil)

        case "stopBackgroundSync":
            self.stopBackgroundDelivery()
            self.cancelAllBGTasks()
            result(nil)

        case "resetAnchors":
            self.resetAllAnchors()
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Authorization
    internal func requestAuthorization(completion: @escaping (Bool)->Void) {
        guard HKHealthStore.isHealthDataAvailable() else { 
            DispatchQueue.main.async { completion(false) }
            return 
        }
        
        // Filter out correlation types - they cannot be requested for authorization
        // Correlation types are automatically available when component types are authorized
        let toRead = Set(trackedTypes.filter { !($0 is HKCorrelationType) })
        
        healthStore.requestAuthorization(toShare: nil, read: toRead) { ok, _ in
            DispatchQueue.main.async { completion(ok) }
        }
    }

    // MARK: - Sync (all / single)
    internal func syncAll(fullExport: Bool, completion: @escaping ()->Void) {
        guard !trackedTypes.isEmpty else { completion(); return }
        
        // Collect data from all types and send together
        collectAllData(fullExport: fullExport, completion: completion)
    }
    
    // MARK: - Debounced combined sync for observer queries
    internal func triggerCombinedSync() {
        // Start background task if not already started
        if observerBgTask == .invalid {
            observerBgTask = UIApplication.shared.beginBackgroundTask(withName: "health_combined_sync") {
                print("⚠️ Observer background task expired")
                UIApplication.shared.endBackgroundTask(self.observerBgTask)
                self.observerBgTask = .invalid
            }
        }
        
        // Cancel any pending sync
        pendingSyncWorkItem?.cancel()
        
        // Create new debounced sync work item
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Send all incremental changes in one request
            self.collectAllData(fullExport: false, isBackground: true) {
                // End background task after sync completes
                if self.observerBgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(self.observerBgTask)
                    self.observerBgTask = .invalid
                }
            }
        }
        
        pendingSyncWorkItem = workItem
        
        // Debounce: wait 2 seconds to collect all observer triggers, then send one request
        syncDebounceQueue.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }
    
    // MARK: - Combined data collection and sync
    internal func collectAllData(fullExport: Bool, completion: @escaping ()->Void) {
        collectAllData(fullExport: fullExport, isBackground: false, completion: completion)
    }
    
    internal func collectAllData(fullExport: Bool, isBackground: Bool, completion: @escaping ()->Void) {
        // Prevent concurrent syncs
        syncLock.lock()
        if isSyncing {
            print("⚠️ Sync already in progress, skipping duplicate sync")
            syncLock.unlock()
            completion()
            return
        }
        isSyncing = true
        syncLock.unlock()
        
        // Check HealthKit authorization status
        guard HKHealthStore.isHealthDataAvailable() else {
            print("❌ HealthKit data not available")
            syncLock.lock()
            isSyncing = false
            syncLock.unlock()
            completion()
            return
        }
        
        print("🔄 Starting data collection (fullExport: \(fullExport), isBackground: \(isBackground))")
        
        let allSamples = NSMutableArray()
        let allAnchors = NSMutableDictionary()
        let group = DispatchGroup()
        let lock = NSLock()
        
        // Query all types to collect samples
        // For full export: get everything
        // For incremental: only get new data since last anchor
        for type in trackedTypes {
            group.enter()
            let anchor = fullExport ? nil : loadAnchor(for: type)
            
            if fullExport {
                print("📥 Full export: fetching all data for \(type.identifier)")
            } else if let anchor = anchor {
                print("📥 Incremental sync: fetching new data since anchor for \(type.identifier)")
            } else {
                print("📥 No anchor found for \(type.identifier), fetching all data (will be treated as full export)")
            }
            
            // For incremental sync, we still want all new data, but anchored queries only return new samples
            let query = HKAnchoredObjectQuery(type: type, predicate: nil, anchor: anchor, limit: HKObjectQueryNoLimit) {
                [weak self] _, samplesOrNil, deletedObjects, newAnchor, error in
                guard let self = self else { 
                    print("⚠️ Query for \(type.identifier): self is nil")
                    group.leave()
                    return 
                }
                
                if let error = error {
                    print("❌ Query error for \(type.identifier): \(error.localizedDescription)")
                    group.leave()
                    return 
                }
                
                let samples = samplesOrNil ?? []
                print("✅ Query completed for \(type.identifier): got \(samples.count) samples")
                
                // Thread-safe access to shared data
                lock.lock()
                // Add ALL samples from this type
                allSamples.addObjects(from: samples)
                
                // Store anchor for this type
                if let newAnchor = newAnchor {
                    allAnchors[type.identifier] = newAnchor
                }
                lock.unlock()
                group.leave()
            }
            
            print("▶️ Executing query for \(type.identifier)")
            healthStore.execute(query)
        }
        
        // Use notify instead of wait to avoid blocking the main thread
        print("⏳ Waiting for \(trackedTypes.count) queries to complete...")
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { 
                print("⚠️ group.notify: self is nil")
                completion()
                return 
            }
            
            print("✅ All queries completed. Total samples collected: \(allSamples.count)")
            
            // Reset sync flag
            self.syncLock.lock()
            self.isSyncing = false
            self.syncLock.unlock()
            
            // If no data, we're done
            guard allSamples.count > 0 else { 
                print("ℹ️ No samples to send")
                completion()
                return 
            }
            guard let endpoint = self.endpoint, let token = self.token else { completion(); return }
            
            // Convert back to proper types
            let samples = allSamples.compactMap { $0 as? HKSample }
            var anchors: [String: HKQueryAnchor] = [:]
            for (key, value) in allAnchors {
                if let keyString = key as? String, let anchor = value as? HKQueryAnchor {
                    anchors[keyString] = anchor
                }
            }
            
            print("📦 Collected \(samples.count) total samples from \(self.trackedTypes.count) types")
            
            // Split samples into chunks to prevent timeout
            let chunks = samples.chunked(into: self.recordsPerChunk)
            print("📦 Split into \(chunks.count) chunk(s) of max \(self.recordsPerChunk) records each")
            
            if chunks.isEmpty {
                print("ℹ️ No data to send")
                self.syncLock.lock()
                self.isSyncing = false
                self.syncLock.unlock()
                completion()
                return
            }
            
            // Send chunks sequentially (wait for each to complete before sending next)
            self.sendChunksSequentially(
                chunks: chunks,
                anchors: anchors,
                endpoint: endpoint,
                token: token,
                fullExport: fullExport,
                chunkIndex: 0,
                totalChunks: chunks.count,
                completion: {
                    // All chunks sent successfully
                    self.syncLock.lock()
                    self.isSyncing = false
                    self.syncLock.unlock()
                    completion()
                }
            )
        }
    }
    
    // MARK: - Sequential chunk sending
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
            // All chunks sent successfully
            completion()
            return
        }
        
        let chunk = chunks[chunkIndex]
        let isLastChunk = (chunkIndex == chunks.count - 1)
        
        print("📤 Sending chunk \(chunkIndex + 1)/\(totalChunks) (\(chunk.count) records)...")
        
        // Serialize this chunk
        let startTime = Date()
        let payload = self.serializeCombined(samples: chunk, anchors: isLastChunk ? anchors : [:])
        let serializationTime = Date().timeIntervalSince(startTime)
        print("✅ Serialized chunk \(chunkIndex + 1) in \(String(format: "%.2f", serializationTime)) seconds")
        
        // Send this chunk - only mark fullDone on last chunk
        let wasFullExport = fullExport && isLastChunk
        
        self.enqueueCombinedUpload(payload: payload, anchors: isLastChunk ? anchors : [:], endpoint: endpoint, token: token, wasFullExport: wasFullExport) { [weak self] success in
            guard let self = self else {
                completion()
                return
            }
            
            if success {
                print("✅ Chunk \(chunkIndex + 1)/\(totalChunks) sent successfully")
                // Send next chunk
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
                print("❌ Chunk \(chunkIndex + 1)/\(totalChunks) failed, stopping")
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
            // Nothing to send if empty
            guard !samples.isEmpty else { completion(); return }
            guard let endpoint = self.endpoint, let token = self.token else { completion(); return }

            let payload = self.serialize(samples: samples, type: type)
            self.enqueueBackgroundUpload(payload: payload, type: type, candidateAnchor: newAnchor, endpoint: endpoint, token: token) {
                // If we got exactly chunkSize samples, there might be more - continue syncing
                if samples.count == self.chunkSize {
                    // Recursively continue with the new anchor
                    self.syncType(type, fullExport: false, completion: completion)
                } else {
                    // We got fewer than chunkSize, so we're done
                    completion()
                }
            }
        }
        healthStore.execute(query)
    }
    
    // MARK: - Background-optimized sync
    internal func syncTypeBackground(_ type: HKSampleType, fullExport: Bool, completion: @escaping ()->Void) {
        let anchor = fullExport ? nil : loadAnchor(for: type)
        
        let query = HKAnchoredObjectQuery(type: type, predicate: nil, anchor: anchor, limit: backgroundChunkSize) {
            [weak self] _, samplesOrNil, deletedObjects, newAnchor, error in
            guard let self = self else { completion(); return }
            guard error == nil else { completion(); return }

            let samples = samplesOrNil ?? []
            // Nothing to send if empty
            guard !samples.isEmpty else { completion(); return }
            guard let endpoint = self.endpoint, let token = self.token else { completion(); return }

            let payload = self.serialize(samples: samples, type: type)
            self.enqueueBackgroundUpload(payload: payload, type: type, candidateAnchor: newAnchor, endpoint: endpoint, token: token) {
                // If we got backgroundChunkSize samples, there might be more - continue syncing
                if samples.count == self.backgroundChunkSize {
                    // Recursively continue with the new anchor
                    self.syncTypeBackground(type, fullExport: false, completion: completion)
                } else {
                    // We got fewer than backgroundChunkSize, so we're done
                completion()
                }
            }
        }
        healthStore.execute(query)
    }
    
    // MARK: - Background-safe sync (for use in background tasks)
    internal func syncTypeWithTimeout(_ type: HKSampleType, fullExport: Bool, timeout: TimeInterval = 20, completion: @escaping ()->Void) {
        let group = DispatchGroup()
        group.enter()
        
        syncType(type, fullExport: fullExport) {
            group.leave()
        }
        
        // Wait with timeout
        let result = group.wait(timeout: .now() + timeout)
        if result == .timedOut {
            print("⚠️ Sync timeout for \(type.identifier)")
        }
        completion()
    }
}

// MARK: - Array extension for chunking
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
