import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'health_bg_sync_platform_interface.dart';
import 'src/exceptions.dart';

/// MethodChannel-based implementation of the HealthBgSync platform interface.
class MethodChannelHealthBgSync extends HealthBgSyncPlatform {
  static const MethodChannel _channel = MethodChannel('health_bg_sync');
  static const EventChannel _logChannel = EventChannel('health_bg_sync/logs');

  bool _logsListenerAttached = false;

  @override
  Future<bool> configure({required String baseUrl, String? customSyncUrl}) async {
    await _channel.invokeMethod<void>('configure', {
      'baseUrl': baseUrl,
      if (customSyncUrl != null) 'customSyncUrl': customSyncUrl,
    });

    if (!_logsListenerAttached) {
      _logsListenerAttached = true;
      _logChannel.receiveBroadcastStream().listen((dynamic event) {
        debugPrint('[HealthBgSync] $event');
      }, onError: (error) {});
    }

    // Check if sync was auto-restored by querying isSyncActive
    final isSyncActive = await _channel.invokeMethod<bool>('isSyncActive');
    return isSyncActive == true;
  }

  @override
  Future<void> signIn({required String userId, required String accessToken}) async {
    try {
      await _channel.invokeMethod<void>('signIn', {'userId': userId, 'accessToken': accessToken});
    } on PlatformException catch (e) {
      throw SignInException(e.message ?? 'Sign-in failed', statusCode: int.tryParse(e.code));
    }
  }

  @override
  Future<void> signOut() async {
    await _channel.invokeMethod<void>('signOut');
  }

  @override
  Future<String?> restoreSession() async {
    final result = await _channel.invokeMethod<String?>('restoreSession');
    return result;
  }

  @override
  Future<bool> requestAuthorization({required List<String> types}) async {
    final result = await _channel.invokeMethod<bool>('requestAuthorization', {'types': types});
    return result == true;
  }

  @override
  Future<bool> startBackgroundSync() async {
    final result = await _channel.invokeMethod<bool>('startBackgroundSync');
    return result == true;
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

  @override
  Future<Map<String, dynamic>> getStoredCredentials() async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>('getStoredCredentials');
    if (result == null) return {};
    return result.map((key, value) => MapEntry(key as String, value));
  }
}
