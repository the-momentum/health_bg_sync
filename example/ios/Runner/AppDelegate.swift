import Flutter
import UIKit
import health_bg_sync

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(_ application: UIApplication,
                            didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(_ application: UIApplication,
                            handleEventsForBackgroundURLSession identifier: String,
                            completionHandler: @escaping () -> Void) {
    HealthBgSyncPlugin.setBackgroundCompletionHandler(completionHandler)
  }
}
