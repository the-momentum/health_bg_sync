import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Defines the interface for the HealthBgSync plugin.
abstract class HealthBgSyncPlatform extends PlatformInterface {
  HealthBgSyncPlatform() : super(token: _token);

  static final Object _token = Object();

  static HealthBgSyncPlatform _instance = _NoopHealthBgSyncPlatform();

  static HealthBgSyncPlatform get instance => _instance;

  static set instance(HealthBgSyncPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  // MARK: - Configuration

  /// Configures the plugin with base URL and optional custom sync URL.
  /// Returns true if sync was auto-restored (session + sync was active).
  Future<bool> configure({required String baseUrl, String? customSyncUrl}) {
    throw UnimplementedError('configure() has not been implemented.');
  }

  // MARK: - Authentication

  /// Signs in a user with userId and accessToken.
  ///
  /// The accessToken is obtained from the developer's backend which generates it
  /// via communication with the Open Wearables API.
  ///
  /// Optionally pass [appId], [appSecret], and [baseUrl] to enable automatic
  /// token refresh when the 60-minute token expires.
  Future<void> signIn({
    required String userId,
    required String accessToken,
    String? appId,
    String? appSecret,
    String? baseUrl,
  }) {
    throw UnimplementedError('signIn() has not been implemented.');
  }

  /// Signs out the current user and clears all tokens from secure storage.
  Future<void> signOut() {
    throw UnimplementedError('signOut() has not been implemented.');
  }

  /// Restores session from secure storage if available.
  ///
  /// Returns userId if session exists, null otherwise.
  Future<String?> restoreSession() {
    throw UnimplementedError('restoreSession() has not been implemented.');
  }

  // MARK: - Authorization

  /// Requests authorization from HealthKit/Health Connect.
  Future<bool> requestAuthorization({required List<String> types}) {
    throw UnimplementedError(
      'requestAuthorization() has not been implemented.',
    );
  }

  // MARK: - Sync Operations

  Future<bool> startBackgroundSync() {
    throw UnimplementedError('startBackgroundSync() has not been implemented.');
  }

  Future<void> syncNow() {
    throw UnimplementedError('syncNow() has not been implemented.');
  }

  Future<void> stopBackgroundSync() {
    throw UnimplementedError('stopBackgroundSync() has not been implemented.');
  }

  Future<void> resetAnchors() {
    throw UnimplementedError('resetAnchors() has not been implemented.');
  }

  /// Returns stored credentials for debugging/display purposes.
  Future<Map<String, dynamic>> getStoredCredentials() {
    throw UnimplementedError(
      'getStoredCredentials() has not been implemented.',
    );
  }

  /// Returns the current sync session status.
  ///
  /// Returns a map with:
  /// - hasResumableSession: bool - whether there's an interrupted sync to resume
  /// - sentCount: int - number of records already sent in this session
  /// - isFullExport: bool - whether this is a full export or incremental sync
  /// - createdAt: String? - ISO8601 timestamp when the sync session started
  Future<Map<String, dynamic>> getSyncStatus() {
    throw UnimplementedError('getSyncStatus() has not been implemented.');
  }

  /// Manually resumes an interrupted sync session.
  ///
  /// Throws if there's no resumable session.
  Future<void> resumeSync() {
    throw UnimplementedError('resumeSync() has not been implemented.');
  }

  /// Clears any interrupted sync session without resuming.
  ///
  /// Use this if you want to discard an interrupted sync and start fresh.
  Future<void> clearSyncSession() {
    throw UnimplementedError('clearSyncSession() has not been implemented.');
  }
}

/// NO-OP placeholder.
class _NoopHealthBgSyncPlatform extends HealthBgSyncPlatform {}
