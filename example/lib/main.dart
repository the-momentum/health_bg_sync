import 'package:flutter/material.dart';
import 'package:health_bg_sync/health_bg_sync.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await HealthBgSync.initialize(
    endpoint: 'https://webhook.site/38ef2363-2e0d-43ca-8dbe-9d312285b511',
    token: 'JWT_TOKEN',
    types: ['steps', 'heartRate', 'activeEnergy', 'distanceWalkingRunning', 'sleep'],
  );

  final ok = await HealthBgSync.requestAuthorization();
  debugPrint('Health permission: $ok');

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Health Sync Demo')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () async {
                  debugPrint('➡️ Incremental sync');
                  await HealthBgSync.syncNow();
                },
                child: const Text('Sync New Data'),
              ),
              ElevatedButton(
                onPressed: () async {
                  await HealthBgSync.startBackgroundSync();
                },
                child: const Text('Start Background Sync'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
