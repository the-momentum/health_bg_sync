import Foundation
import UIKit
import HealthKit
import BackgroundTasks

extension HealthBgSyncPlugin {

    // MARK: - Background delivery
    internal func startBackgroundDelivery() {
        for q in activeObserverQueries { healthStore.stop(q) }
        activeObserverQueries.removeAll()

        for type in trackedTypes {
            let observer = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completionHandler, error in
                guard let self = self else { 
                    completionHandler()
                    return 
                }

                if let error = error {
                    print("⚠️ Observer error for \(type.identifier): \(error.localizedDescription)")
                    completionHandler()
                    return
                }

                // Trigger debounced combined sync - all types will be collected and sent together in one request
                // This debounces multiple observer triggers and sends all changes together
                self.triggerCombinedSync()
                
                completionHandler()
            }
            healthStore.execute(observer)
            activeObserverQueries.append(observer)
            healthStore.enableBackgroundDelivery(for: type, frequency: .immediate) { _, _ in }
        }
        print("📡 Background observers registered for \(trackedTypes.count) types")
    }

    internal func stopBackgroundDelivery() {
        for q in activeObserverQueries { healthStore.stop(q) }
        activeObserverQueries.removeAll()
        for t in trackedTypes { healthStore.disableBackgroundDelivery(for: t) {_,_ in} }
    }

    // MARK: - BGTaskScheduler (fallback catch-up)
    internal func scheduleAppRefresh() {
        guard #available(iOS 13.0, *) else { return }
        let req = BGAppRefreshTaskRequest(identifier: refreshTaskId)
        // Earliest in ~15 minutes (iOS decides the actual time)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do { try BGTaskScheduler.shared.submit(req) }
        catch { print("⚠️ scheduleAppRefresh error: \(error.localizedDescription)") }
    }

    internal func scheduleProcessing() {
        guard #available(iOS 13.0, *) else { return }
        let req = BGProcessingTaskRequest(identifier: processTaskId)
        req.requiresNetworkConnectivity = true
        req.requiresExternalPower = false
        do { try BGTaskScheduler.shared.submit(req) }
        catch { print("⚠️ scheduleProcessing error: \(error.localizedDescription)") }
    }

    internal func cancelAllBGTasks() {
        if #available(iOS 13.0, *) {
            BGTaskScheduler.shared.cancelAllTaskRequests()
        }
    }

    @available(iOS 13.0, *)
    internal func handleAppRefresh(task: BGAppRefreshTask) {
        // Always reschedule
        scheduleAppRefresh()

        let opQueue = OperationQueue()
        let op = BlockOperation { [weak self] in
            // Use background-optimized sync for BGAppRefresh
            let group = DispatchGroup()
            group.enter()
            
            self?.collectAllData(fullExport: false, isBackground: true) {
                group.leave()
            }
            
            // Wait with timeout
            let result = group.wait(timeout: .now() + 20)
            if result == .timedOut {
                print("⚠️ BGAppRefresh sync timed out")
            }
        }

        task.expirationHandler = { 
            print("⚠️ BGAppRefresh task expired")
            op.cancel() 
        }
        op.completionBlock = { task.setTaskCompleted(success: !op.isCancelled) }
        opQueue.addOperation(op)
    }

    @available(iOS 13.0, *)
    internal func handleProcessing(task: BGProcessingTask) {
        // Always reschedule
        scheduleProcessing()

        let opQueue = OperationQueue()
        let op = BlockOperation { [weak self] in
            // Use background-optimized sync for BGProcessing
            let group = DispatchGroup()
            group.enter()
            
            self?.retryOutboxIfPossible()
            self?.collectAllData(fullExport: false, isBackground: true) {
                group.leave()
            }
            
            // Wait with timeout
            let result = group.wait(timeout: .now() + 25)
            if result == .timedOut {
                print("⚠️ BGProcessing sync timed out")
            }
        }

        task.expirationHandler = { 
            print("⚠️ BGProcessing task expired")
            op.cancel() 
        }
        op.completionBlock = { task.setTaskCompleted(success: !op.isCancelled) }
        opQueue.addOperation(op)
    }
}
