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
export 'health_bg_sync_method_channel.dart';

/// Ensure MethodChannel is the default implementation.
/// This runs at library load time before any static methods can be called.
final HealthBgSyncPlatform _platform = (() {
  HealthBgSyncPlatform.instance = MethodChannelHealthBgSync();
  return HealthBgSyncPlatform.instance;
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
  /// ## Token Refresh
  ///
  /// Pass [appId], [appSecret], and [baseUrl] to enable automatic token
  /// refresh. The token is valid for 60 minutes, and will be automatically
  /// refreshed before sync operations if expired.
  ///
  /// ## Flow
  ///
  /// 1. Your mobile app requests credentials from YOUR backend
  /// 2. Your backend calls Open Wearables API to generate accessToken
  /// 3. Your backend returns userId and accessToken to mobile app
  /// 4. Mobile app calls this method with the credentials
  ///
  /// ```dart
  /// final user = await HealthBgSync.signIn(
  ///   userId: response['userId'],
  ///   accessToken: response['accessToken'],
  ///   appId: 'your-app-id',        // For auto-refresh
  ///   appSecret: 'your-app-secret', // For auto-refresh
  ///   baseUrl: 'https://api.openwearables.io', // For auto-refresh
  /// );
  /// ```
  ///
  /// Throws [NotConfiguredException] if [configure] was not called.
  /// Throws [SignInException] if sign-in fails.
  static Future<HealthBgSyncUser> signIn({
    required String userId,
    required String accessToken,
    String? appId,
    String? appSecret,
    String? baseUrl,
  }) async {
    if (_config == null) throw const NotConfiguredException();

    await _platform.signIn(
      userId: userId,
      accessToken: accessToken,
      appId: appId,
      appSecret: appSecret,
      baseUrl: baseUrl,
    );

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

  // MARK: - Sync Session Management

  /// Returns the current sync session status.
  ///
  /// Use this to check if there's an interrupted sync that can be resumed.
  /// The sync will automatically resume on app restart, but you can also
  /// manually trigger resume with [resumeSync].
  ///
  /// Returns a map with:
  /// - `hasResumableSession`: bool - whether there's an interrupted sync
  /// - `sentCount`: int - number of records already sent in this session
  /// - `isFullExport`: bool - whether this is a full export or incremental
  /// - `createdAt`: String? - ISO8601 timestamp when sync started
  ///
  /// ```dart
  /// final status = await HealthBgSync.getSyncStatus();
  /// if (status['hasResumableSession'] == true) {
  ///   print('Sync interrupted, ${status['sentCount']} records already sent');
  /// }
  /// ```
  static Future<Map<String, dynamic>> getSyncStatus() async {
    return _platform.getSyncStatus();
  }

  /// Manually resumes an interrupted sync session.
  ///
  /// The sync is automatically resumed on app restart when [configure] is
  /// called. Use this method if you want to manually trigger resume, for
  /// example after network connectivity is restored.
  ///
  /// Throws [NotSignedInException] if no user is signed in.
  /// Throws [PlatformException] if there's no resumable session.
  ///
  /// ```dart
  /// final status = await HealthBgSync.getSyncStatus();
  /// if (status['hasResumableSession'] == true) {
  ///   await HealthBgSync.resumeSync();
  /// }
  /// ```
  static Future<void> resumeSync() async {
    _ensureSignedIn();
    await _platform.resumeSync();
  }

  /// Clears any interrupted sync session without resuming.
  ///
  /// Use this if you want to discard an interrupted sync and start fresh.
  /// This will NOT reset the sync anchors - the next sync will be incremental
  /// from where the last successful sync completed.
  ///
  /// To fully reset and re-export all data, use [resetAnchors] instead.
  static Future<void> clearSyncSession() async {
    await _platform.clearSyncSession();
  }

  // MARK: - Helpers

  static void _ensureSignedIn() {
    if (_config == null) throw const NotConfiguredException();
    if (_currentUser == null) throw const NotSignedInException();
  }
}
