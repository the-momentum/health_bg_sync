import 'package:health_bg_sync/health_data_type.dart';
import 'package:health_bg_sync/src/config.dart';
import 'package:health_bg_sync/src/exceptions.dart';
import 'package:health_bg_sync/src/status.dart';
import 'package:health_bg_sync/src/user.dart';

import 'health_bg_sync_method_channel.dart';
import 'health_bg_sync_platform_interface.dart';

export 'package:health_bg_sync/src/config.dart';
export 'package:health_bg_sync/src/exceptions.dart';
export 'package:health_bg_sync/src/status.dart';
export 'package:health_bg_sync/src/user.dart';

/// Ensure MethodChannel is the default implementation.
bool _hbgsRegistered = (() {
  HealthBgSyncPlatform.instance = MethodChannelHealthBgSync();
  return true;
})();

/// Main entry point for the HealthBgSync plugin.
///
/// This plugin enables background health data synchronization from
/// Apple HealthKit (iOS) and Health Connect (Android) to the
/// Open Wearables platform.
///
/// ## Usage
///
/// 1. Configure the plugin:
/// ```dart
/// await HealthBgSync.configure();
/// ```
///
/// 2. Get accessToken from your backend and sign in:
/// ```dart
/// final credentials = await yourBackend.getHealthCredentials();
/// await HealthBgSync.signIn(
///   userId: credentials['userId'],
///   accessToken: credentials['accessToken'],
/// );
/// ```
///
/// 3. Request health data permissions:
/// ```dart
/// await HealthBgSync.requestAuthorization(types: [...]);
/// ```
///
/// 4. Start background synchronization:
/// ```dart
/// await HealthBgSync.startBackgroundSync();
/// ```
class HealthBgSync {
  HealthBgSync._();

  static HealthBgSyncPlatform get _platform {
    assert(_hbgsRegistered, 'MethodChannel not registered');
    return HealthBgSyncPlatform.instance;
  }

  static HealthBgSyncConfig? _config;
  static HealthBgSyncUser? _currentUser;
  static bool _isSyncActive = false;

  // MARK: - Configuration

  /// Configures the HealthBgSync plugin.
  ///
  /// This must be called before any other method. It will also attempt
  /// to restore any existing user session from secure storage.
  ///
  /// - [environment]: The environment to connect to (default: production).
  /// - [customSyncUrl]: Optional custom URL for syncing health data.
  ///   Use this for local testing. The URL can include `{user_id}` or `{userId}`
  ///   placeholder which will be replaced with the signed-in user's ID.
  ///   Example: `http://localhost:3000/sdk/users/{user_id}/sync/apple/healthion`
  ///
  /// ```dart
  /// await HealthBgSync.configure(
  ///   environment: HealthBgSyncEnvironment.sandbox,
  /// );
  ///
  /// // Or with custom URL for local testing:
  /// await HealthBgSync.configure(
  ///   customSyncUrl: 'http://localhost:3000/sdk/users/{user_id}/sync/apple/healthion',
  /// );
  ///
  /// // Check if session was restored
  /// if (HealthBgSync.isSignedIn) {
  ///   print('Welcome back!');
  /// }
  /// ```
  static Future<void> configure({
    HealthBgSyncEnvironment environment = HealthBgSyncEnvironment.production,
    String? customSyncUrl,
  }) async {
    _config = HealthBgSyncConfig(environment: environment);

    // Configure and check if sync was auto-restored
    _isSyncActive = await _platform.configure(baseUrl: _config!.baseUrl, customSyncUrl: customSyncUrl);

    // Try to restore existing session from Keychain
    final restoredUserId = await _platform.restoreSession();
    if (restoredUserId != null) {
      _currentUser = HealthBgSyncUser(userId: restoredUserId);
    }
  }

  /// Returns the current configuration, or null if not configured.
  static HealthBgSyncConfig? get config => _config;

  // MARK: - Status

  /// Returns the current status of the plugin.
  static HealthBgSyncStatus get status {
    if (_config == null) return HealthBgSyncStatus.notConfigured;
    if (_currentUser == null) return HealthBgSyncStatus.configured;
    return HealthBgSyncStatus.signedIn;
  }

  /// Returns true if the plugin is configured.
  static bool get isConfigured => _config != null;

  /// Returns true if a user is signed in.
  static bool get isSignedIn => _currentUser != null;

  /// Returns the currently signed-in user, or null if no user is signed in.
  static HealthBgSyncUser? get currentUser => _currentUser;

  /// Returns true if background sync is active.
  static bool get isSyncActive => _isSyncActive;

  // MARK: - Authentication

  /// Signs in a user with userId and accessToken.
  ///
  /// The accessToken must be obtained from your backend server, which
  /// generates it via communication with the Open Wearables API.
  ///
  /// ## Flow
  ///
  /// 1. Your mobile app requests credentials from YOUR backend
  /// 2. Your backend calls Open Wearables API to generate accessToken
  /// 3. Your backend returns userId and accessToken to mobile app
  /// 4. Mobile app calls this method with the credentials
  ///
  /// ```dart
  /// // 1. Get credentials from your backend
  /// final response = await yourApi.post('/health/connect');
  ///
  /// // 2. Sign in with the credentials
  /// final user = await HealthBgSync.signIn(
  ///   userId: response['userId'],
  ///   accessToken: response['accessToken'],
  /// );
  /// print('Connected: ${user.userId}');
  /// ```
  ///
  /// Throws [NotConfiguredException] if [configure] was not called.
  /// Throws [SignInException] if sign-in fails.
  static Future<HealthBgSyncUser> signIn({required String userId, required String accessToken}) async {
    if (_config == null) throw const NotConfiguredException();

    await _platform.signIn(userId: userId, accessToken: accessToken);

    _currentUser = HealthBgSyncUser(userId: userId);

    return _currentUser!;
  }

  /// Signs out the current user.
  ///
  /// This will:
  /// - Stop any background sync
  /// - Clear all tokens from secure storage (Keychain/Keystore)
  /// - Clear the user session and sync state
  ///
  /// After signing out, you must call [signIn] again before performing
  /// any sync operations.
  static Future<void> signOut() async {
    if (_currentUser != null) {
      await _platform.signOut();
      _currentUser = null;
      _isSyncActive = false;
    }
  }

  // MARK: - Health Data Authorization

  /// Requests authorization to access the specified health data types.
  ///
  /// On iOS, this will present the HealthKit authorization sheet.
  /// On Android, this will request Health Connect permissions.
  ///
  /// Returns true if authorization was successful, false otherwise.
  ///
  /// Throws [NotSignedInException] if no user is signed in.
  static Future<bool> requestAuthorization({required List<HealthDataType> types}) async {
    _ensureSignedIn();
    return _platform.requestAuthorization(types: types.map((e) => e.id).toList(growable: false));
  }

  // MARK: - Sync Operations

  /// Starts background health data synchronization.
  ///
  /// This will:
  /// - Register for background updates when new health data is available
  /// - Perform an initial full export if this is the first sync
  /// - Schedule periodic background sync tasks
  ///
  /// The sync state is persisted and will auto-restore on app restart
  /// when [configure] is called.
  ///
  /// Returns true if background sync started successfully.
  ///
  /// Throws [NotSignedInException] if no user is signed in.
  static Future<bool> startBackgroundSync() async {
    _ensureSignedIn();
    final started = await _platform.startBackgroundSync();
    if (started) {
      _isSyncActive = true;
    }
    return started;
  }

  /// Stops background health data synchronization.
  ///
  /// This will disable all background observers and cancel scheduled tasks.
  /// The stopped state is persisted and sync will not auto-restore on restart.
  static Future<void> stopBackgroundSync() async {
    await _platform.stopBackgroundSync();
    _isSyncActive = false;
  }

  /// Manually triggers an incremental sync.
  ///
  /// This will sync any new health data since the last sync.
  /// Useful for forcing a sync when the app is in the foreground.
  ///
  /// Throws [NotSignedInException] if no user is signed in.
  static Future<void> syncNow() async {
    _ensureSignedIn();
    await _platform.syncNow();
  }

  /// Resets all sync anchors and forces a full re-export on next sync.
  ///
  /// Use this to re-sync all historical data. The next sync will
  /// behave as if it's the first sync.
  static Future<void> resetAnchors() async {
    await _platform.resetAnchors();
  }

  /// Returns stored credentials for debugging/display purposes.
  ///
  /// Returns a map with keys: userId, accessToken, customSyncUrl, isSyncActive.
  /// String values may be null if not stored. isSyncActive is a bool.
  static Future<Map<String, dynamic>> getStoredCredentials() async {
    return _platform.getStoredCredentials();
  }

  // MARK: - Helpers

  static void _ensureSignedIn() {
    if (_config == null) throw const NotConfiguredException();
    if (_currentUser == null) throw const NotSignedInException();
  }
}
