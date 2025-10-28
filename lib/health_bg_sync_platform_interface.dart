import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Defines the interface for the HealthBgSync plugin.
/// Each platform implementation (e.g., MethodChannel, mock, etc.)
/// must extend this class and provide its own implementation.
abstract class HealthBgSyncPlatform extends PlatformInterface {
  HealthBgSyncPlatform() : super(token: _token);

  static final Object _token = Object();

  /// Default implementation (NO-OP) to prevent errors
  /// before the actual platform implementation is registered.
  static HealthBgSyncPlatform _instance = _NoopHealthBgSyncPlatform();

  /// The active instance of the platform interface.
  static HealthBgSyncPlatform get instance => _instance;

  /// Sets the active instance of the platform interface.
  static set instance(HealthBgSyncPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Initializes the plugin with endpoint, token, and types.
  /// - Retries pending sync batches.
  /// - If no full export was performed yet for this endpoint, it triggers one.
  Future<void> initialize(Map<String, dynamic> config) {
    throw UnimplementedError('initialize() has not been implemented.');
  }

  /// Requests authorization from HealthKit (Read permissions).
  Future<bool> requestAuthorization() {
    throw UnimplementedError('requestAuthorization() has not been implemented.');
  }

  /// Starts background sync:
  /// - Registers ObserverQuery + enables background delivery.
  /// - Performs a full export for types without anchor and incremental for others.
  Future<void> startBackgroundSync() {
    throw UnimplementedError('startBackgroundSync() has not been implemented.');
  }

  /// Manually triggers incremental sync (from the last anchor).
  Future<void> syncNow() {
    throw UnimplementedError('syncNow() has not been implemented.');
  }

  /// Stops background sync (disables all observers).
  Future<void> stopBackgroundSync() {
    throw UnimplementedError('stopBackgroundSync() has not been implemented.');
  }

  /// Optionally clears anchors and the full-export-done flag for the current endpoint.
  Future<void> resetAnchors() {
    throw UnimplementedError('resetAnchors() has not been implemented.');
  }
}

/// NO-OP placeholder to avoid exceptions before initialization.
class _NoopHealthBgSyncPlatform extends HealthBgSyncPlatform {}
