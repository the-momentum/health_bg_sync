/// Thrown when the plugin is not configured.
class NotConfiguredException implements Exception {
  const NotConfiguredException();

  @override
  String toString() => 'NotConfiguredException: HealthBgSync.configure() was not called.';
}

/// Thrown when no user is signed in.
class NotSignedInException implements Exception {
  const NotSignedInException();

  @override
  String toString() => 'NotSignedInException: No user is signed in. Call HealthBgSync.signIn() first.';
}

/// Thrown when sign-in fails.
class SignInException implements Exception {
  const SignInException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'SignInException: $message${statusCode != null ? ' (HTTP $statusCode)' : ''}';
}
