/// Represents the current status of the HealthBgSync plugin.
enum HealthBgSyncStatus {
  /// Plugin has not been configured yet.
  /// Call [HealthBgSync.configure] first.
  notConfigured,

  /// Plugin is configured but no user is signed in.
  /// Call [HealthBgSync.signIn] with userId and accessToken.
  configured,

  /// User is signed in and ready to sync.
  signedIn,
}
