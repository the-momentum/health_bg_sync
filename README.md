# HealthBgSync (Open Wearables SDK)

A Flutter plugin for secure background health data synchronization from Apple HealthKit (iOS) and Health Connect (Android) to the Open Wearables platform.

## Features

- 🔐 **Simple Token Authentication** - Backend generates accessToken, SDK uses it directly
- 📱 **Background Sync** - Health data syncs even when app is in background
- 📦 **Incremental Updates** - Only syncs new data using anchored queries
- 💾 **Secure Storage** - Credentials stored in iOS Keychain / Android Keystore
- 📊 **Wide Data Support** - Steps, heart rate, workouts, sleep, and more

---

## Authentication Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              SECURE ZONE                                     │
│                         (Server-to-Server, HTTPS)                           │
│                                                                             │
│  ┌──────────────────┐                      ┌─────────────────┐             │
│  │  Your Backend    │   Generate Token     │  Open Wearables │             │
│  │                  │   (with API Key)     │  Platform       │             │
│  │  [API Key here]  │─────────────────────>│                 │             │
│  │                  │                      │                 │             │
│  │                  │<─────────────────────│                 │             │
│  │                  │   { accessToken,     │                 │             │
│  │                  │     userId }         │                 │             │
│  └────────┬─────────┘                      └────────┬────────┘             │
│           │                                         │                       │
└───────────│─────────────────────────────────────────│───────────────────────┘
            │                                         │
            │ userId + accessToken                    │
            │ (NO API Key!)                          │
            ▼                                         │
┌───────────────────────┐                            │
│  Mobile App           │                            │
│  (Flutter SDK)        │   Health data sync         │
│                       │───────────────────────────>│
│  [Keychain storage]   │   (Bearer accessToken)     │
└───────────────────────┘                            │
```

### Step-by-Step Flow

1. **User logs into your app** (your own authentication)

2. **Mobile app requests credentials from YOUR backend**
   ```
   POST /api/health/connect
   Authorization: Bearer <your-user-jwt>
   ```

3. **Your backend generates credentials** (server-to-server with API Key)
   ```http
   POST https://api.openwearables.com/v1/tokens
   X-API-Key: sk_live_your_secret_key
   Content-Type: application/json
   
   { "externalId": "user-123" }
   ```
   
   Response:
   ```json
   { 
     "userId": "usr_abc123",
     "accessToken": "at_..." 
   }
   ```

4. **Your backend returns credentials to mobile app**
   ```json
   { 
     "userId": "usr_abc123",
     "accessToken": "at_..." 
   }
   ```

5. **Mobile app signs in with the SDK**
   ```dart
   final user = await HealthBgSync.signIn(
     userId: response['userId'],
     accessToken: response['accessToken'],
   );
   ```

6. **SDK stores credentials securely** in iOS Keychain / Android Keystore

7. **Health data syncs using accessToken**
   ```http
   POST https://api.openwearables.com/sdk/users/{userId}/sync/apple/healthion
   Authorization: at_...
   ```

---

## Installation

### 1. Add Dependency

```yaml
dependencies:
  health_bg_sync: ^0.1.0
```

### 2. iOS Configuration

Add to `Info.plist`:

```xml
<key>NSHealthShareUsageDescription</key>
<string>This app syncs your health data to your account.</string>

<key>UIBackgroundModes</key>
<array>
    <string>fetch</string>
    <string>processing</string>
</array>

<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>com.healthbgsync.task.refresh</string>
    <string>com.healthbgsync.task.process</string>
</array>
```

Enable HealthKit in Xcode → Target → Signing & Capabilities → + HealthKit.

---

## Backend Integration

Your backend needs ONE endpoint to generate credentials:

```javascript
// Node.js / Express example
app.post('/api/health/connect', authenticateUser, async (req, res) => {
  // 1. Get your authenticated user
  const userId = req.user.id;
  
  // 2. Call Open Wearables API to generate token
  const response = await fetch('https://api.openwearables.com/v1/tokens', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-API-Key': process.env.OPENWEARABLES_API_KEY, // Secret! Never expose!
    },
    body: JSON.stringify({
      externalId: userId.toString(),
    }),
  });
  
  const { userId: owUserId, accessToken } = await response.json();
  
  // 3. Return credentials (NOT the API Key!)
  res.json({ userId: owUserId, accessToken });
});
```

---

## SDK Usage

### 1. Configure (once at app start)

```dart
await HealthBgSync.configure(
  environment: HealthBgSyncEnvironment.production,
);

// Session is automatically restored if user was previously signed in
if (HealthBgSync.isSignedIn) {
  print('Welcome back, ${HealthBgSync.currentUser?.userId}!');
}
```

### 2. Sign In

```dart
// Get credentials from YOUR backend
final response = await yourApi.post('/health/connect');

// Sign in with the credentials
try {
  final user = await HealthBgSync.signIn(
    userId: response['userId'],
    accessToken: response['accessToken'],
  );
  print('Connected: ${user.userId}');
} on SignInException catch (e) {
  print('Failed: ${e.message}');
}
```

### 3. Request Permissions

```dart
final authorized = await HealthBgSync.requestAuthorization(
  types: [
    HealthDataType.steps,
    HealthDataType.heartRate,
    HealthDataType.sleep,
    HealthDataType.workout,
  ],
);
```

### 4. Start Background Sync

```dart
await HealthBgSync.startBackgroundSync();
```

### 5. Sign Out

```dart
await HealthBgSync.signOut();
// All credentials cleared from Keychain
```

---

## Complete Example

```dart
class HealthService {
  final ApiClient _api;
  
  Future<void> connect() async {
    // 1. Configure SDK (once)
    await HealthBgSync.configure();
    
    // 2. Check current status
    switch (HealthBgSync.status) {
      case HealthBgSyncStatus.signedIn:
        // Already signed in, start sync
        await _startSync();
        return;
        
      case HealthBgSyncStatus.configured:
        // Need to sign in
        await _signIn();
        await _startSync();
        return;
        
      case HealthBgSyncStatus.notConfigured:
        throw Exception('SDK not configured');
    }
  }
  
  Future<void> _signIn() async {
    // Get credentials from your backend
    final response = await _api.post('/health/connect');
    
    // Sign in with SDK
    await HealthBgSync.signIn(
      userId: response['userId'],
      accessToken: response['accessToken'],
    );
  }
  
  Future<void> _startSync() async {
    await HealthBgSync.requestAuthorization(
      types: HealthDataType.values,
    );
    await HealthBgSync.startBackgroundSync();
  }
  
  Future<void> disconnect() async {
    await HealthBgSync.stopBackgroundSync();
    await HealthBgSync.signOut();
  }
}
```

---

## Supported Health Data Types

| Category | Types |
|----------|-------|
| **Activity** | steps, distanceWalkingRunning, distanceCycling, flightsClimbed |
| **Energy** | activeEnergy, basalEnergy |
| **Heart** | heartRate, restingHeartRate, heartRateVariabilitySDNN, vo2Max |
| **Body** | bodyMass, height, bmi, bodyFatPercentage |
| **Vitals** | bloodPressure, bloodGlucose, respiratoryRate |
| **Sleep** | sleep, mindfulSession |
| **Workouts** | workout |

---

## API Reference

### HealthBgSync

| Method | Description |
|--------|-------------|
| `configure()` | Initialize SDK and restore session |
| `signIn(userId:, accessToken:)` | Sign in with credentials from backend |
| `signOut()` | Sign out and clear all credentials |
| `requestAuthorization()` | Request health data permissions |
| `startBackgroundSync()` | Enable background sync |
| `stopBackgroundSync()` | Disable background sync |
| `syncNow()` | Trigger immediate sync |
| `resetAnchors()` | Reset sync state |

### Properties

| Property | Type | Description |
|----------|------|-------------|
| `isConfigured` | `bool` | SDK is configured |
| `isSignedIn` | `bool` | User is signed in |
| `currentUser` | `HealthBgSyncUser?` | Current user info |
| `status` | `HealthBgSyncStatus` | Current SDK status |

### HealthBgSyncStatus

| Status | Description |
|--------|-------------|
| `notConfigured` | SDK not configured, call `configure()` |
| `configured` | SDK configured, but no user signed in |
| `signedIn` | User signed in, ready to sync |

### Exceptions

| Exception | When Thrown |
|-----------|-------------|
| `NotConfiguredException` | `configure()` was not called |
| `NotSignedInException` | No user signed in |
| `SignInException` | Sign-in failed |

---

## License

MIT License
