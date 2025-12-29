/// Configuration for the HealthBgSync plugin.
class HealthBgSyncConfig {
  const HealthBgSyncConfig({this.environment = HealthBgSyncEnvironment.production});

  /// The environment to connect to.
  final HealthBgSyncEnvironment environment;

  /// Get the base URL for the API based on environment.
  String get baseUrl => environment.baseUrl;

  @override
  String toString() => 'HealthBgSyncConfig(environment: ${environment.name})';
}

/// Environment for the HealthBgSync platform.
enum HealthBgSyncEnvironment {
  /// Production environment.
  production('https://open-wearables-production.up.railway.app/api/v1'),

  /// Sandbox/Development environment for testing.
  sandbox('https://sandbox.api.healthbgsync.com');

  const HealthBgSyncEnvironment(this.baseUrl);

  /// The base URL for API calls.
  final String baseUrl;
}
