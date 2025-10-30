import 'package:health_bg_sync/health_data_type.dart';

import 'health_bg_sync_method_channel.dart';
import 'health_bg_sync_platform_interface.dart';

/// Ensure MethodChannel is the default implementation.
bool _hbgsRegistered = (() {
  HealthBgSyncPlatform.instance = MethodChannelHealthBgSync();
  return true;
})();

class HealthBgSync {
  static HealthBgSyncPlatform get _platform => HealthBgSyncPlatform.instance;

  static Future<void> initialize({
    required String endpoint,
    required String token,
    required List<HealthDataType> types,
    int chunkSize = 1000, // Default chunk size to prevent HTTP 413 errors
    int recordsPerChunk = 10000, // Default records per HTTP request to prevent timeouts (~2-3MB per chunk)
  }) async {
    // Touch the registration so it's tree-shake-proof.
    assert(_hbgsRegistered, 'MethodChannel not registered');
    await _platform.initialize({
      'endpoint': endpoint,
      'token': token,
      'types': types.map((e) => e.id).toList(growable: false),
      'chunkSize': chunkSize,
      'recordsPerChunk': recordsPerChunk,
    });
  }

  static Future<bool> requestAuthorization() async {
    assert(_hbgsRegistered);
    return _platform.requestAuthorization();
  }

  static Future<void> syncNow() async {
    assert(_hbgsRegistered);
    await _platform.syncNow();
  }

  static Future<void> startBackgroundSync() async {
    assert(_hbgsRegistered);
    await _platform.startBackgroundSync();
  }

  static Future<void> stopBackgroundSync() async {
    assert(_hbgsRegistered);
    await _platform.stopBackgroundSync();
  }

  static Future<void> resetAnchors() async {
    assert(_hbgsRegistered);
    await _platform.resetAnchors();
  }
}
