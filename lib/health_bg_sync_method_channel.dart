import 'package:flutter/services.dart';

import 'health_bg_sync_platform_interface.dart';

/// MethodChannel-based implementation of the HealthBgSync platform interface.
/// Communicates with the native side using a single method channel.
class MethodChannelHealthBgSync extends HealthBgSyncPlatform {
  static const MethodChannel _channel = MethodChannel('health_bg_sync');

  @override
  Future<void> initialize(Map<String, dynamic> config) async {
    await _channel.invokeMethod<void>('initialize', config);
  }

  @override
  Future<bool> requestAuthorization() async {
    final res = await _channel.invokeMethod<bool>('requestAuthorization');
    return res == true;
  }

  @override
  Future<void> startBackgroundSync() async {
    await _channel.invokeMethod<void>('startBackgroundSync');
  }

  @override
  Future<void> syncNow() async {
    await _channel.invokeMethod<void>('syncNow');
  }

  @override
  Future<void> stopBackgroundSync() async {
    await _channel.invokeMethod<void>('stopBackgroundSync');
  }

  @override
  Future<void> resetAnchors() async {
    await _channel.invokeMethod<void>('resetAnchors');
  }
}
