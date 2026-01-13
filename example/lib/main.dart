import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:health_bg_sync/health_bg_sync.dart';
import 'package:health_bg_sync/health_data_type.dart';
import 'package:http/http.dart' as http;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  runApp(const MyApp());
}

// Simple in-memory logs (limited to 1000 entries for performance)
final List<String> appLogs = [];
const int _maxLogEntries = 1000;

// Notifier to trigger rebuilds when logs change
final logUpdateNotifier = ValueNotifier<int>(0);

void _addLog(String message) {
  appLogs.add(message);
  if (appLogs.length > _maxLogEntries) {
    appLogs.removeRange(0, appLogs.length - _maxLogEntries);
  }
  logUpdateNotifier.value++;
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Health Sync',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFFF2D55), brightness: Brightness.light),
        scaffoldBackgroundColor: const Color(0xFFF2F2F7),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF2F2F7),
          elevation: 0,
          scrolledUnderElevation: 0,
          titleTextStyle: TextStyle(
            color: Colors.black,
            fontSize: 34,
            fontWeight: FontWeight.bold,
            letterSpacing: -0.5,
          ),
        ),
        useMaterial3: true,
      ),
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
  final _customUrlController = TextEditingController(text: 'https://api.openwearables.io');
  final _userIdController = TextEditingController();
  final _appIdController = TextEditingController();
  final _appSecretController = TextEditingController();
  final _accessTokenController = TextEditingController();

  bool _isLoading = false;
  String _statusMessage = '';

  bool _isSignedIn = false;
  bool _isAuthorized = false;
  bool _isSyncing = false;

  @override
  void initState() {
    super.initState();
    _subscribeToNativeLogs();
    _autoConfigureOnStartup();
  }

  void _subscribeToNativeLogs() {
    MethodChannelHealthBgSync.logStream.listen((message) {
      final timestamp = DateTime.now().toIso8601String().split('T').last.split('.').first;
      _addLog('$timestamp $message');
    });
  }

  @override
  void dispose() {
    _userIdController.dispose();
    _accessTokenController.dispose();
    _customUrlController.dispose();
    _appIdController.dispose();
    _appSecretController.dispose();
    super.dispose();
  }

  Future<void> _autoConfigureOnStartup() async {
    setState(() => _isLoading = true);
    try {
      final credentials = await HealthBgSync.getStoredCredentials();
      final hasUserId = credentials['userId'] != null && (credentials['userId'] as String).isNotEmpty;
      final hasAccessToken = credentials['accessToken'] != null && (credentials['accessToken'] as String).isNotEmpty;
      final wasSyncActive = credentials['isSyncActive'] == true;

      setState(() {
        if (credentials['userId'] != null) {
          _userIdController.text = credentials['userId'] as String;
        }
        if (credentials['accessToken'] != null) {
          _accessTokenController.text = credentials['accessToken'] as String;
        }
      });

      if (hasUserId && hasAccessToken && wasSyncActive) {
        final storedCustomUrl = credentials['customSyncUrl'] as String?;
        await HealthBgSync.configure(environment: HealthBgSyncEnvironment.production, customSyncUrl: storedCustomUrl);
        _checkStatus();
        _setStatus('Session restored');
      }
    } catch (e) {
      debugPrint('Auto-configure failed: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<String?> _fetchToken(String userId, String appId, String appSecret, String baseUrl) async {
    final url = Uri.parse('$baseUrl/api/v1/users/$userId/token');
    _setStatus('Fetching token...');

    final response = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'app_id': appId, 'app_secret': appSecret}),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      return data['access_token'];
    } else {
      throw Exception('Failed to get token: ${response.statusCode}');
    }
  }

  Future<void> _loginWithCredentials() async {
    final userId = _userIdController.text.trim();
    final appId = _appIdController.text.trim();
    final appSecret = _appSecretController.text.trim();
    final baseUrl = _customUrlController.text.isNotEmpty
        ? _customUrlController.text.trim()
        : 'https://api.openwearables.io';

    if (userId.isEmpty || appId.isEmpty || appSecret.isEmpty) {
      _setStatus('Please fill all fields');
      return;
    }

    setState(() => _isLoading = true);

    try {
      final fullSyncUrl = '$baseUrl/api/v1/sdk/users/{user_id}/sync/apple/healthion';
      await HealthBgSync.configure(environment: HealthBgSyncEnvironment.production, customSyncUrl: fullSyncUrl);
      _checkStatus();

      final token = await _fetchToken(userId, appId, appSecret, baseUrl);
      if (token == null) {
        _setStatus('Failed to retrieve token');
        return;
      }

      setState(() => _accessTokenController.text = token);

      _setStatus('Signing in...');
      final authToken = token.startsWith('Bearer ') ? token : 'Bearer $token';
      await HealthBgSync.signIn(
        userId: userId,
        accessToken: authToken,
        appId: appId,
        appSecret: appSecret,
        baseUrl: baseUrl,
      );

      _setStatus('Connected successfully');
      _checkStatus();
    } catch (e) {
      _setStatus('Connection failed: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _checkStatus() {
    setState(() {
      _isSignedIn = HealthBgSync.isSignedIn;
      _isSyncing = HealthBgSync.isSyncActive;
    });
  }

  void _setStatus(String message) {
    setState(() => _statusMessage = message);
    final log = '${DateTime.now().toIso8601String().split('T').last.split('.').first} $message';
    _addLog(log);
    debugPrint('[Demo] $message');
  }

  Future<void> _signOut() async {
    setState(() => _isLoading = true);
    try {
      await HealthBgSync.signOut();
      _setStatus('Signed out');
      _checkStatus();
      setState(() {
        _isAuthorized = false;
        _isSyncing = false;
        _accessTokenController.clear();
      });
    } catch (e) {
      _setStatus('Error: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _requestAuthorization() async {
    setState(() => _isLoading = true);
    try {
      final authorized = await HealthBgSync.requestAuthorization(types: HealthDataType.values);
      setState(() => _isAuthorized = authorized);
      _setStatus(authorized ? 'Authorized' : 'Authorization denied');
    } on NotSignedInException {
      _setStatus('Sign in first');
    } catch (e) {
      _setStatus('Error: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _startBackgroundSync() async {
    setState(() => _isLoading = true);
    try {
      final started = await HealthBgSync.startBackgroundSync();
      setState(() => _isSyncing = started);
      _setStatus(started ? 'Sync started' : 'Could not start sync');
    } on NotSignedInException {
      _setStatus('Sign in first');
    } catch (e) {
      _setStatus('Error: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _stopBackgroundSync() async {
    setState(() => _isLoading = true);
    try {
      await HealthBgSync.stopBackgroundSync();
      setState(() => _isSyncing = false);
      _setStatus('Sync stopped');
    } catch (e) {
      _setStatus('Error: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _syncNow() async {
    setState(() => _isLoading = true);
    try {
      await HealthBgSync.syncNow();
      _setStatus('Sync triggered');
    } on NotSignedInException {
      _setStatus('Sign in first');
    } catch (e) {
      _setStatus('Error: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // Large title app bar (Apple style)
          SliverAppBar(
            pinned: true,
            expandedHeight: 100,
            flexibleSpace: FlexibleSpaceBar(
              title: const Text('Health Sync'),
              titlePadding: const EdgeInsets.only(left: 20, bottom: 16),
            ),
            actions: [
              CupertinoButton(
                padding: const EdgeInsets.all(12),
                child: const Icon(CupertinoIcons.doc_text, size: 24),
                onPressed: () => Navigator.of(context).push(CupertinoPageRoute(builder: (c) => const LogsPage())),
              ),
            ],
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Status Card
                  _buildStatusCard(),
                  const SizedBox(height: 24),

                  if (!_isSignedIn) ...[_buildLoginSection()] else ...[_buildActionsSection()],

                  if (_statusMessage.isNotEmpty) ...[const SizedBox(height: 24), _buildStatusMessage()],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 2))],
      ),
      child: Row(
        children: [
          // Status indicator ring
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: _isSyncing
                    ? [const Color(0xFF34C759), const Color(0xFF30D158)]
                    : [const Color(0xFFFF3B30), const Color(0xFFFF453A)],
              ),
            ),
            child: Icon(
              _isSyncing ? CupertinoIcons.checkmark_alt : CupertinoIcons.xmark,
              color: Colors.white,
              size: 28,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isSyncing ? 'Syncing Active' : 'Not Syncing',
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, letterSpacing: -0.3),
                ),
                const SizedBox(height: 4),
                Text(
                  _isSignedIn
                      ? 'Connected as ${_userIdController.text.length > 8 ? '${_userIdController.text.substring(0, 8)}...' : _userIdController.text}'
                      : 'Not connected',
                  style: TextStyle(fontSize: 15, color: Colors.grey[600], letterSpacing: -0.2),
                ),
              ],
            ),
          ),
          if (_isLoading) const CupertinoActivityIndicator(),
        ],
      ),
    );
  }

  Widget _buildLoginSection() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Text(
              'CONNECT',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey, letterSpacing: 0.5),
            ),
          ),
          _buildTextField(controller: _userIdController, placeholder: 'User ID', icon: CupertinoIcons.person),
          _buildDivider(),
          _buildTextField(controller: _appIdController, placeholder: 'App ID', icon: CupertinoIcons.app),
          _buildDivider(),
          _buildTextField(
            controller: _appSecretController,
            placeholder: 'App Secret',
            icon: CupertinoIcons.lock,
            obscureText: true,
          ),
          _buildDivider(),
          _buildTextField(controller: _customUrlController, placeholder: 'API URL', icon: CupertinoIcons.link),
          Padding(
            padding: const EdgeInsets.all(20),
            child: SizedBox(
              width: double.infinity,
              child: CupertinoButton.filled(
                onPressed: _isLoading ? null : _loginWithCredentials,
                borderRadius: BorderRadius.circular(12),
                child: _isLoading
                    ? const CupertinoActivityIndicator(color: Colors.white)
                    : const Text('Connect', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String placeholder,
    required IconData icon,
    bool obscureText = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          Icon(icon, color: Colors.grey[400], size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: CupertinoTextField(
              controller: controller,
              placeholder: placeholder,
              obscureText: obscureText,
              padding: EdgeInsets.zero,
              decoration: const BoxDecoration(),
              style: const TextStyle(fontSize: 17),
              placeholderStyle: TextStyle(fontSize: 17, color: Colors.grey[400]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDivider() {
    return Padding(
      padding: const EdgeInsets.only(left: 56),
      child: Divider(height: 1, color: Colors.grey[200]),
    );
  }

  Widget _buildActionsSection() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 2))],
      ),
      child: Column(
        children: [
          if (!_isAuthorized)
            _buildActionTile(
              icon: CupertinoIcons.heart,
              iconColor: const Color(0xFFFF2D55),
              title: 'Authorize Health',
              subtitle: 'Grant access to health data',
              onTap: _requestAuthorization,
            ),
          if (_isAuthorized) ...[
            _buildActionTile(
              icon: _isSyncing ? CupertinoIcons.pause : CupertinoIcons.play,
              iconColor: const Color(0xFF34C759),
              title: _isSyncing ? 'Stop Sync' : 'Start Sync',
              subtitle: _isSyncing ? 'Background sync is active' : 'Begin syncing health data',
              onTap: _isSyncing ? _stopBackgroundSync : _startBackgroundSync,
            ),
            _buildDivider(),
            _buildActionTile(
              icon: CupertinoIcons.arrow_2_circlepath,
              iconColor: const Color(0xFF007AFF),
              title: 'Sync Now',
              subtitle: 'Force an immediate sync',
              onTap: _syncNow,
            ),
          ],
          _buildDivider(),
          _buildActionTile(
            icon: CupertinoIcons.square_arrow_left,
            iconColor: const Color(0xFFFF3B30),
            title: 'Disconnect',
            subtitle: 'Sign out and stop syncing',
            onTap: _signOut,
            destructive: true,
          ),
        ],
      ),
    );
  }

  Widget _buildActionTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool destructive = false,
  }) {
    return CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: _isLoading ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w500,
                      color: destructive ? const Color(0xFFFF3B30) : Colors.black,
                      letterSpacing: -0.2,
                    ),
                  ),
                  Text(subtitle, style: TextStyle(fontSize: 14, color: Colors.grey[500], letterSpacing: -0.1)),
                ],
              ),
            ),
            Icon(CupertinoIcons.chevron_right, color: Colors.grey[300], size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusMessage() {
    final isError = _statusMessage.toLowerCase().contains('error') || _statusMessage.toLowerCase().contains('failed');
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isError
            ? const Color(0xFFFF3B30).withValues(alpha: 0.1)
            : const Color(0xFF34C759).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            isError ? CupertinoIcons.exclamationmark_circle : CupertinoIcons.checkmark_circle,
            color: isError ? const Color(0xFFFF3B30) : const Color(0xFF34C759),
            size: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _statusMessage,
              style: TextStyle(
                fontSize: 15,
                color: isError ? const Color(0xFFFF3B30) : const Color(0xFF34C759),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  final _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<String> get _filteredLogs {
    if (_searchQuery.isEmpty) return appLogs;
    return appLogs.where((log) => log.toLowerCase().contains(_searchQuery.toLowerCase())).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF2F2F7),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF2F2F7),
        title: const Text(
          'Sync Logs',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Colors.black),
        ),
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          child: const Icon(CupertinoIcons.back, color: Color(0xFF007AFF)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          CupertinoButton(
            padding: const EdgeInsets.all(12),
            child: const Icon(CupertinoIcons.trash, color: Color(0xFFFF3B30)),
            onPressed: () {
              appLogs.clear();
              logUpdateNotifier.value++;
            },
          ),
        ],
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: logUpdateNotifier,
        builder: (context, _, __) {
          final filteredLogs = _filteredLogs;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: CupertinoSearchTextField(
                  controller: _searchController,
                  placeholder: 'Search in logs...',
                  onChanged: (value) => setState(() => _searchQuery = value),
                ),
              ),
              Expanded(
                child: appLogs.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(CupertinoIcons.doc_text, size: 48, color: Colors.grey[300]),
                            const SizedBox(height: 12),
                            Text('No logs yet', style: TextStyle(fontSize: 17, color: Colors.grey[400])),
                          ],
                        ),
                      )
                    : filteredLogs.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(CupertinoIcons.search, size: 48, color: Colors.grey[300]),
                            const SizedBox(height: 12),
                            Text('No results', style: TextStyle(fontSize: 17, color: Colors.grey[400])),
                          ],
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: filteredLogs.length,
                        separatorBuilder: (context, index) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final log = filteredLogs[filteredLogs.length - 1 - index];
                          return _LogItem(
                            log: log,
                            key: ValueKey('${filteredLogs.length - 1 - index}_${log.hashCode}'),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// Extracted log item widget for better performance
class _LogItem extends StatelessWidget {
  final String log;

  const _LogItem({required this.log, super.key});

  @override
  Widget build(BuildContext context) {
    // Pre-compute these once per item
    final isError = log.contains('❌') || log.contains('Error');
    final isSuccess = log.contains('✅');

    final Color dotColor = isError
        ? const Color(0xFFFF3B30)
        : isSuccess
        ? const Color(0xFF34C759)
        : const Color(0xFFE5E5EA);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.all(Radius.circular(10))),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(top: 6),
            decoration: BoxDecoration(shape: BoxShape.circle, color: dotColor),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              log,
              style: const TextStyle(fontSize: 13, fontFamily: 'Menlo', color: Color(0xFF666666), height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
