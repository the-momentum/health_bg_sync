/// Represents a signed-in user in the HealthBgSync system.
class HealthBgSyncUser {
  const HealthBgSyncUser({required this.userId});

  /// The unique user ID provided by the developer.
  final String userId;

  @override
  String toString() => 'HealthBgSyncUser(userId: $userId)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HealthBgSyncUser &&
          runtimeType == other.runtimeType &&
          userId == other.userId;

  @override
  int get hashCode => userId.hashCode;
}
