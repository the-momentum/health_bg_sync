import 'health_bg_sync_method_channel.dart';
import 'health_bg_sync_platform_interface.dart';

/// Public entry point for the HealthBgSync plugin.
/// Delegates calls to the registered platform implementation (MethodChannel by default).
class HealthBgSync {
  /// Sets the default platform implementation to MethodChannel.
  static void registerWith() {
    HealthBgSyncPlatform.instance = MethodChannelHealthBgSync();
  }

  /// Initializes the plugin with endpoint, token, and data types.
  static Future<void> initialize({required String endpoint, required String token, required List<String> types}) async {
    await HealthBgSyncPlatform.instance.initialize({'endpoint': endpoint, 'token': token, 'types': types});
  }

  /// Requests HealthKit read authorization.
  static Future<bool> requestAuthorization() async {
    return HealthBgSyncPlatform.instance.requestAuthorization();
  }

  /// Manually triggers an incremental sync (from the last anchor).
  static Future<void> syncNow() async {
    await HealthBgSyncPlatform.instance.syncNow();
  }

  /// Starts background sync:
  /// - Registers ObserverQuery and enables background delivery.
  /// - Performs full export for types without anchors, incremental for others.
  static Future<void> startBackgroundSync() async {
    await HealthBgSyncPlatform.instance.startBackgroundSync();
  }

  /// Stops background sync (disables observers).
  static Future<void> stopBackgroundSync() async {
    await HealthBgSyncPlatform.instance.stopBackgroundSync();
  }

  /// Clears anchors and full-export flags for the current endpoint (optional).
  static Future<void> resetAnchors() async {
    await HealthBgSyncPlatform.instance.resetAnchors();
  }
}
