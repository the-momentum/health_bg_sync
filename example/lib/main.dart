import 'package:flutter/material.dart';
import 'package:health_bg_sync/health_bg_sync.dart';
import 'package:health_bg_sync/health_data_type.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HealthBgSync Demo',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal), useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _userIdController = TextEditingController();
  final _accessTokenController = TextEditingController();
  final _customUrlController = TextEditingController();

  bool _isLoading = false;
  String _statusMessage = '';
  bool _isConfigured = false;
  bool _isSignedIn = false;
  bool _isAuthorized = false;
  bool _isSyncing = false;

  @override
  void initState() {
    super.initState();
    _autoConfigureOnStartup();
  }

  Future<void> _autoConfigureOnStartup() async {
    setState(() => _isLoading = true);
    try {
      // Check stored credentials BEFORE configure to decide if we should auto-configure
      final credentials = await HealthBgSync.getStoredCredentials();
      final hasUserId = credentials['userId'] != null && (credentials['userId'] as String).isNotEmpty;
      final hasAccessToken = credentials['accessToken'] != null && (credentials['accessToken'] as String).isNotEmpty;
      final wasSyncActive = credentials['isSyncActive'] == true;

      // Populate text fields with any stored data
      setState(() {
        if (credentials['customSyncUrl'] != null) {
          _customUrlController.text = credentials['customSyncUrl'] as String;
        }
        if (credentials['userId'] != null) {
          _userIdController.text = credentials['userId'] as String;
        }
        if (credentials['accessToken'] != null) {
          _accessTokenController.text = credentials['accessToken'] as String;
        }
      });

      // Only auto-configure if we have stored session AND sync was active
      if (hasUserId && hasAccessToken && wasSyncActive) {
        await HealthBgSync.configure(environment: HealthBgSyncEnvironment.production);
        _checkStatus();
        _setStatus('✅ Auto-restored: session & sync active');
      }
      // Otherwise don't call configure - user needs to do it manually
    } catch (e) {
      debugPrint('Auto-configure failed: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _configure() async {
    setState(() => _isLoading = true);
    try {
      final customUrl = _customUrlController.text.trim();
      await HealthBgSync.configure(
        environment: HealthBgSyncEnvironment.production,
        customSyncUrl: customUrl.isNotEmpty ? customUrl : null,
      );
      _checkStatus();

      // Check what was restored
      if (HealthBgSync.isSignedIn && HealthBgSync.isSyncActive) {
        _setStatus('✅ Session & sync restored: ${HealthBgSync.currentUser?.userId}');
      } else if (HealthBgSync.isSignedIn) {
        _setStatus('✅ Session restored: ${HealthBgSync.currentUser?.userId}');
      } else {
        _setStatus('✅ Configured successfully');
      }
    } catch (e) {
      _setStatus('❌ Configure failed: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _checkStatus() {
    setState(() {
      _isConfigured = HealthBgSync.isConfigured;
      _isSignedIn = HealthBgSync.isSignedIn;
      _isSyncing = HealthBgSync.isSyncActive;
    });
  }

  void _setStatus(String message) {
    setState(() => _statusMessage = message);
    debugPrint('[Demo] $message');
  }

  Future<void> _signIn() async {
    final userId = _userIdController.text.trim();
    final accessToken = _accessTokenController.text.trim();

    if (userId.isEmpty || accessToken.isEmpty) {
      _setStatus('⚠️ Enter both User ID and Access Token');
      return;
    }

    setState(() => _isLoading = true);
    try {
      // In production, you get these credentials from YOUR backend
      final user = await HealthBgSync.signIn(userId: userId, accessToken: accessToken);
      _setStatus('✅ Signed in: ${user.userId}');
      _checkStatus();
    } on NotConfiguredException {
      _setStatus('❌ Not configured');
    } on SignInException catch (e) {
      _setStatus('❌ Sign-in failed: ${e.message}');
    } catch (e) {
      _setStatus('❌ Error: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _signOut() async {
    setState(() => _isLoading = true);
    try {
      await HealthBgSync.signOut();
      _setStatus('✅ Signed out');
      _checkStatus();
      setState(() {
        _isAuthorized = false;
        _isSyncing = false;
      });
    } catch (e) {
      _setStatus('❌ Sign-out error: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _requestAuthorization() async {
    setState(() => _isLoading = true);
    try {
      final authorized = await HealthBgSync.requestAuthorization(
        types: [
          HealthDataType.steps,
          HealthDataType.heartRate,
          HealthDataType.activeEnergy,
          HealthDataType.sleep,
          HealthDataType.workout,
        ],
      );
      setState(() => _isAuthorized = authorized);
      _setStatus(authorized ? '✅ Authorized' : '⚠️ Partial/denied');
    } on NotSignedInException {
      _setStatus('❌ Sign in first');
    } catch (e) {
      _setStatus('❌ Error: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _startBackgroundSync() async {
    setState(() => _isLoading = true);
    try {
      final started = await HealthBgSync.startBackgroundSync();
      setState(() => _isSyncing = started);
      _setStatus(started ? '✅ Sync started' : '⚠️ Could not start');
    } on NotSignedInException {
      _setStatus('❌ Sign in first');
    } catch (e) {
      _setStatus('❌ Error: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _stopBackgroundSync() async {
    setState(() => _isLoading = true);
    try {
      await HealthBgSync.stopBackgroundSync();
      setState(() => _isSyncing = false);
      _setStatus('✅ Sync stopped');
    } catch (e) {
      _setStatus('❌ Error: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _syncNow() async {
    setState(() => _isLoading = true);
    try {
      await HealthBgSync.syncNow();
      _setStatus('✅ Sync complete');
    } on NotSignedInException {
      _setStatus('❌ Sign in first');
    } catch (e) {
      _setStatus('❌ Error: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _resetAnchors() async {
    setState(() => _isLoading = true);
    try {
      await HealthBgSync.resetAnchors();
      _setStatus('✅ Anchors reset');
    } catch (e) {
      _setStatus('❌ Error: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('HealthBgSync Demo'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Info Card
            Card(
              color: Colors.green.shade50,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.security, color: Colors.green.shade700),
                        const SizedBox(width: 8),
                        Text(
                          'Secure Authentication Flow',
                          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green.shade900),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'The User ID and Access Token are obtained from YOUR backend.\n'
                      'Your backend generates them using the API Key (server-to-server).\n'
                      'API Key NEVER leaves your backend!',
                      style: TextStyle(fontSize: 12, color: Colors.green.shade900),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Status Card
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Status', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    _StatusRow(label: 'Configured', isActive: _isConfigured),
                    _StatusRow(
                      label: 'Signed In',
                      isActive: _isSignedIn,
                      detail: _isSignedIn ? HealthBgSync.currentUser?.userId : null,
                    ),
                    _StatusRow(label: 'Authorized', isActive: _isAuthorized),
                    _StatusRow(label: 'Background Sync', isActive: _isSyncing),
                    if (_statusMessage.isNotEmpty) ...[
                      const Divider(),
                      Text(_statusMessage, style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Configuration Section
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('1. Configure', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _customUrlController,
                      decoration: const InputDecoration(
                        labelText: 'Custom Sync URL (optional)',
                        hintText: 'http://localhost:8000/api/v1/users/{user_id}/sync',
                        helperText: 'Use {user_id} placeholder - will be replaced with User ID',
                        helperMaxLines: 2,
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      maxLines: 2,
                      enabled: !_isConfigured,
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _isLoading || _isConfigured ? null : _configure,
                      icon: const Icon(Icons.settings),
                      label: const Text('Configure'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Authentication Section
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('2. Sign In', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _userIdController,
                      decoration: const InputDecoration(
                        labelText: 'User ID (from your backend)',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      enabled: !_isSignedIn && _isConfigured,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _accessTokenController,
                      decoration: const InputDecoration(
                        labelText: 'Access Token (will be sent as Authorization header)',
                        helperText: 'Include "Bearer " prefix if your API requires it',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      maxLines: 2,
                      enabled: !_isSignedIn && _isConfigured,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _isLoading || _isSignedIn || !_isConfigured ? null : _signIn,
                            icon: const Icon(Icons.login),
                            label: const Text('Sign In'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _isLoading || !_isSignedIn ? null : _signOut,
                            icon: const Icon(Icons.logout),
                            label: const Text('Sign Out'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Health Authorization
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('3. Health Authorization', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _isLoading || !_isSignedIn ? null : _requestAuthorization,
                      icon: const Icon(Icons.health_and_safety),
                      label: const Text('Request Authorization'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Sync
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('4. Data Sync', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _isLoading || !_isSignedIn || _isSyncing ? null : _startBackgroundSync,
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('Start'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _isLoading || !_isSyncing ? null : _stopBackgroundSync,
                            icon: const Icon(Icons.stop),
                            label: const Text('Stop'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _isLoading || !_isSignedIn ? null : _syncNow,
                            icon: const Icon(Icons.sync),
                            label: const Text('Sync Now'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _isLoading ? null : _resetAnchors,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Reset'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 32),

            if (_isLoading) const Center(child: CircularProgressIndicator()),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _userIdController.dispose();
    _accessTokenController.dispose();
    _customUrlController.dispose();
    super.dispose();
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.label, required this.isActive, this.detail});

  final String label;
  final bool isActive;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            isActive ? Icons.check_circle : Icons.circle_outlined,
            size: 16,
            color: isActive ? Colors.green : Colors.grey,
          ),
          const SizedBox(width: 8),
          Text(label),
          if (detail != null) ...[
            const SizedBox(width: 4),
            Text('($detail)', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey)),
          ],
        ],
      ),
    );
  }
}
