import Flutter
import UIKit
import HealthKit
import BackgroundTasks

public class HealthBgSyncPlugin: NSObject, FlutterPlugin, URLSessionDelegate, URLSessionTaskDelegate {

    // MARK: - State
    private let healthStore = HKHealthStore()
    private var session: URLSession!
    private var endpoint: URL?
    private var token: String?
    private var trackedTypes: [HKSampleType] = []

    // Per-endpoint state (anchors + full-export-done flag)
    private let defaults = UserDefaults(suiteName: "com.healthbgsync.state") ?? .standard

    // Observer queries for background delivery
    private var activeObserverQueries: [HKObserverQuery] = []

    // Background session identifier
    private let bgSessionId = "com.healthbgsync.upload.session"

    // BGTask identifiers (MUST be present in Info.plist -> BGTaskSchedulerPermittedIdentifiers)
    private let refreshTaskId  = "com.healthbgsync.task.refresh"
    private let processTaskId  = "com.healthbgsync.task.process"

    // AppDelegate will pass its background completion handler here
    private static var bgCompletionHandler: (() -> Void)?

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
        let cfg = URLSessionConfiguration.background(withIdentifier: bgSessionId)
        cfg.isDiscretionary = false
        cfg.waitsForConnectivity = true
        self.session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)

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

            print("✅ Initialized for endpointKey=\(endpointKey()) types=\(trackedTypes.map{$0.identifier})")

            // Retry pending outbox items (if any)
            retryOutboxIfPossible()

            // If no full export was done for this endpoint yet — perform it
            initialSyncKickoff { result(nil) }

        case "requestAuthorization":
            requestAuthorization { ok in result(ok) }

        case "syncNow":
            // Manual incremental sync (does not trigger full export)
            self.syncAll(fullExport: false) { result(nil) }

        case "startBackgroundSync":
            // Register observers and perform initial sync (full only for types without an anchor)
            self.startBackgroundDelivery()
            self.initialSyncKickoff { }
            // Schedule fallback BG tasks
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

    // MARK: - Type mapping
    private func mapTypes(_ names: [String]) -> [HKSampleType] {
        var out: [HKSampleType] = []
        for n in names {
            switch n {
            case "steps":
                if let t = HKObjectType.quantityType(forIdentifier: .stepCount) { out.append(t) }
            case "heartRate":
                if let t = HKObjectType.quantityType(forIdentifier: .heartRate) { out.append(t) }
            case "activeEnergy":
                if let t = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) { out.append(t) }
            case "distanceWalkingRunning":
                if let t = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning) { out.append(t) }
            case "sleep":
                if let t = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { out.append(t) }
            default: break
            }
        }
        return out
    }

    // MARK: - Authorization
    private func requestAuthorization(completion: @escaping (Bool)->Void) {
        guard HKHealthStore.isHealthDataAvailable() else { completion(false); return }
        let toRead = Set(trackedTypes)
        healthStore.requestAuthorization(toShare: nil, read: toRead) { ok, _ in
            completion(ok)
        }
    }

    // MARK: - Keys (per-endpoint)
    private func endpointKey() -> String {
        guard let s = endpoint?.absoluteString, !s.isEmpty else { return "endpoint.none" }
        // Simple safe key for UserDefaults (no CryptoKit)
        let safe = s.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return "ep.\(safe)"
    }
    private func anchorKey(for type: HKSampleType) -> String { "anchor.\(endpointKey()).\(type.identifier)" }
    private func fullDoneKey() -> String { "fullDone.\(endpointKey())" }

    // Identifier-based variants (to store anchors without needing HKSampleType in memory)
    private func anchorKey(typeIdentifier: String, endpointKey: String) -> String {
        return "anchor.\(endpointKey).\(typeIdentifier)"
    }
    private func saveAnchorData(_ data: Data, typeIdentifier: String, endpointKey: String) {
        defaults.set(data, forKey: anchorKey(typeIdentifier: typeIdentifier, endpointKey: endpointKey))
    }

    // MARK: - Anchors
    private func loadAnchor(for type: HKSampleType) -> HKQueryAnchor? {
        guard let data = defaults.data(forKey: anchorKey(for: type)) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }
    private func saveAnchor(_ anchor: HKQueryAnchor, for type: HKSampleType) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) {
            defaults.set(data, forKey: anchorKey(for: type))
        }
    }
    private func resetAllAnchors() {
        for t in trackedTypes { defaults.removeObject(forKey: anchorKey(for: t)) }
        defaults.set(false, forKey: fullDoneKey())
    }

    // MARK: - Initial sync plan
    private func initialSyncKickoff(completion: @escaping ()->Void) {
        let fullDone = defaults.bool(forKey: fullDoneKey())
        if fullDone {
            // Endpoint already completed full export → do incremental only
            syncAll(fullExport: false, completion: completion)
        } else {
            // First time for this endpoint → perform full export
            syncAll(fullExport: true) {
                self.defaults.set(true, forKey: self.fullDoneKey())
                completion()
            }
        }
    }

    // MARK: - Background delivery
    private func startBackgroundDelivery() {
        for q in activeObserverQueries { healthStore.stop(q) }
        activeObserverQueries.removeAll()

        for type in trackedTypes {
            let observer = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completionHandler, error in
                guard let self = self else { return }
                // Short "grace time" so uploads can finish cleanly
                var bgTask: UIBackgroundTaskIdentifier = .invalid
                bgTask = UIApplication.shared.beginBackgroundTask(withName: "health_observer_sync") {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }

                if let error = error {
                    print("⚠️ Observer error for \(type.identifier): \(error.localizedDescription)")
                    completionHandler()
                    if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
                    return
                }

                self.syncType(type, fullExport: false) {
                    completionHandler()
                    if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
                }
            }
            healthStore.execute(observer)
            activeObserverQueries.append(observer)
            healthStore.enableBackgroundDelivery(for: type, frequency: .immediate) { _, _ in }
        }
        print("📡 Background observers registered for \(trackedTypes.count) types")
    }

    private func stopBackgroundDelivery() {
        for q in activeObserverQueries { healthStore.stop(q) }
        activeObserverQueries.removeAll()
        for t in trackedTypes { healthStore.disableBackgroundDelivery(for: t) {_,_ in} }
    }

    // MARK: - Sync (all / single)
    private func syncAll(fullExport: Bool, completion: @escaping ()->Void) {
        guard !trackedTypes.isEmpty else { completion(); return }
        let group = DispatchGroup()
        for t in trackedTypes {
            group.enter()
            syncType(t, fullExport: fullExport) { group.leave() }
        }
        group.notify(queue: .main) { completion() }
    }

    private func syncType(_ type: HKSampleType, fullExport: Bool, completion: @escaping ()->Void) {
        let anchor = fullExport ? nil : loadAnchor(for: type)
        let query = HKAnchoredObjectQuery(type: type, predicate: nil, anchor: anchor, limit: HKObjectQueryNoLimit) {
            [weak self] _, samplesOrNil, _, newAnchor, error in
            guard let self = self else { completion(); return }
            guard error == nil else { completion(); return }

            let samples = samplesOrNil ?? []
            // Nothing to send if empty
            guard !samples.isEmpty else { completion(); return }
            guard let endpoint = self.endpoint, let token = self.token else { completion(); return }

            let payload = self.serialize(samples: samples, type: type)
            self.enqueueBackgroundUpload(payload: payload, type: type, candidateAnchor: newAnchor, endpoint: endpoint, token: token) {
                completion()
            }
        }
        healthStore.execute(query)
    }

    // MARK: - Serialization
    private func serialize(samples: [HKSample], type: HKSampleType) -> [String: Any] {
        let df = ISO8601DateFormatter()
        var out: [[String: Any]] = []

        for s in samples {
            if let q = s as? HKQuantitySample {
                let unit: HKUnit
                switch q.quantityType {
                case HKObjectType.quantityType(forIdentifier: .stepCount):
                    unit = .count()
                case HKObjectType.quantityType(forIdentifier: .heartRate):
                    unit = .count().unitDivided(by: .minute())
                case HKObjectType.quantityType(forIdentifier: .activeEnergyBurned):
                    unit = .kilocalorie()
                case HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning):
                    unit = .meter()
                default:
                    unit = .count()
                }
                out.append([
                    "type": q.quantityType.identifier,
                    "start": df.string(from: q.startDate),
                    "end": df.string(from: q.endDate),
                    "value": q.quantity.doubleValue(for: unit),
                    "unit": unit.description
                ])
            } else if let c = s as? HKCategorySample {
                out.append([
                    "type": c.categoryType.identifier,
                    "start": df.string(from: c.startDate),
                    "end": df.string(from: c.endDate),
                    "value": c.value
                ])
            }
        }

        return [
            "device": "ios",
            "endpointKey": endpointKey(),
            "batchGeneratedAt": df.string(from: Date()),
            "samples": out
        ]
    }

    // MARK: - Outbox model
    private struct OutboxItem: Codable {
        let typeIdentifier: String
        let endpointKey: String
        let payloadPath: String
        let anchorPath: String?
    }

    private func outboxDir() -> URL {
        let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return (base ?? FileManager.default.temporaryDirectory).appendingPathComponent("health_outbox", isDirectory: true)
    }
    private func ensureOutboxDir() {
        try? FileManager.default.createDirectory(at: outboxDir(), withIntermediateDirectories: true)
    }
    private func newPath(_ name: String, ext: String) -> URL {
        ensureOutboxDir()
        return outboxDir().appendingPathComponent("\(name).\(ext)")
    }

    // MARK: - Background upload with persistence
    private func enqueueBackgroundUpload(payload: [String: Any], type: HKSampleType, candidateAnchor: HKQueryAnchor?, endpoint: URL, token: String, completion: @escaping ()->Void) {
        // 1) payload → file
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { completion(); return }
        let id = UUID().uuidString
        let payloadURL = newPath("payload_\(id)", ext: "json")
        do { try data.write(to: payloadURL, options: .atomic) } catch { completion(); return }

        // 2) candidate anchor → file (optional)
        var anchorURL: URL? = nil
        if let cand = candidateAnchor,
           let ad = try? NSKeyedArchiver.archivedData(withRootObject: cand, requiringSecureCoding: true) {
            let u = newPath("anchor_\(id)", ext: "bin")
            try? ad.write(to: u, options: .atomic)
            anchorURL = u
        }

        // 3) manifest (item) → file
        let item = OutboxItem(typeIdentifier: type.identifier,
                              endpointKey: endpointKey(),
                              payloadPath: payloadURL.path,
                              anchorPath: anchorURL?.path)
        let itemURL = newPath("item_\(id)", ext: "json")
        if let md = try? JSONEncoder().encode(item) { try? md.write(to: itemURL, options: .atomic) }

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

    // Retry pending items after startup (when endpoint/token are available)
    private func retryOutboxIfPossible() {
        guard let endpoint = self.endpoint, let token = self.token else { return }
        let dir = outboxDir()
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let items = files.filter { $0.lastPathComponent.hasPrefix("item_") && $0.pathExtension == "json" }

        for itemURL in items {
            guard let data = try? Data(contentsOf: itemURL),
                  let item = try? JSONDecoder().decode(OutboxItem.self, from: data) else { continue }
            let payloadURL = URL(fileURLWithPath: item.payloadPath)
            guard FileManager.default.fileExists(atPath: payloadURL.path) else { continue }

            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let task = session.uploadTask(with: req, fromFile: payloadURL)
            task.taskDescription = [itemURL.path, payloadURL.path, item.anchorPath ?? ""].joined(separator: "|")
            task.resume()
        }
    }

    // MARK: - URLSession delegate
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let desc = task.taskDescription else { return }
        let parts = desc.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let itemPath = parts.count > 0 ? parts[0] : ""
        let payloadPath = parts.count > 1 ? parts[1] : ""
        let anchorPath = parts.count > 2 ? parts[2] : ""

        defer {
            if !payloadPath.isEmpty { try? FileManager.default.removeItem(atPath: payloadPath) }
            if error == nil, !itemPath.isEmpty { try? FileManager.default.removeItem(atPath: itemPath) }
        }

        // Transport error → keep manifest + anchor for retry
        if let error = error {
            print("⛔️ background upload failed: \(error.localizedDescription)")
            return
        }

        // Only treat 2xx as success (HEAD/redirects can happen in background)
        if let http = task.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            print("⛔️ upload HTTP \(http.statusCode) — keep item for retry")
            return
        }

        // SUCCESS: save anchor BASED ON MANIFEST — no need to have trackedTypes in memory
        if !anchorPath.isEmpty,
           let itemData = try? Data(contentsOf: URL(fileURLWithPath: itemPath)),
           let item = try? JSONDecoder().decode(OutboxItem.self, from: itemData),
           let anchorData = try? Data(contentsOf: URL(fileURLWithPath: anchorPath)) {

            saveAnchorData(anchorData, typeIdentifier: item.typeIdentifier, endpointKey: item.endpointKey)
            try? FileManager.default.removeItem(atPath: anchorPath)
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        if let handler = HealthBgSyncPlugin.bgCompletionHandler {
            HealthBgSyncPlugin.bgCompletionHandler = nil
            handler()
        }
    }

    // MARK: - BGTaskScheduler (fallback catch-up)
    private func scheduleAppRefresh() {
        guard #available(iOS 13.0, *) else { return }
        let req = BGAppRefreshTaskRequest(identifier: refreshTaskId)
        // Earliest in ~15 minutes (iOS decides the actual time)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do { try BGTaskScheduler.shared.submit(req) }
        catch { print("⚠️ scheduleAppRefresh error: \(error.localizedDescription)") }
    }

    private func scheduleProcessing() {
        guard #available(iOS 13.0, *) else { return }
        let req = BGProcessingTaskRequest(identifier: processTaskId)
        req.requiresNetworkConnectivity = true
        req.requiresExternalPower = false
        do { try BGTaskScheduler.shared.submit(req) }
        catch { print("⚠️ scheduleProcessing error: \(error.localizedDescription)") }
    }

    private func cancelAllBGTasks() {
        if #available(iOS 13.0, *) {
            BGTaskScheduler.shared.cancelAllTaskRequests()
        }
    }

    @available(iOS 13.0, *)
    private func handleAppRefresh(task: BGAppRefreshTask) {
        // Always reschedule
        scheduleAppRefresh()

        let opQueue = OperationQueue()
        let op = BlockOperation { [weak self] in
            // Incremental sync for all types
            self?.syncAll(fullExport: false) { }
        }

        task.expirationHandler = { op.cancel() }
        op.completionBlock = { task.setTaskCompleted(success: !op.isCancelled) }
        opQueue.addOperation(op)
    }

    @available(iOS 13.0, *)
    private func handleProcessing(task: BGProcessingTask) {
        // Always reschedule
        scheduleProcessing()

        let opQueue = OperationQueue()
        let op = BlockOperation { [weak self] in
            // Incremental sync + retry outbox (if anything is pending)
            self?.retryOutboxIfPossible()
            self?.syncAll(fullExport: false) { }
        }

        task.expirationHandler = { op.cancel() }
        op.completionBlock = { task.setTaskCompleted(success: !op.isCancelled) }
        opQueue.addOperation(op)
    }
}
