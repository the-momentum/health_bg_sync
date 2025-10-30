import 'package:flutter/material.dart';
import 'package:health_bg_sync/health_bg_sync.dart';
import 'package:health_bg_sync/health_data_type.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await HealthBgSync.initialize(
    endpoint: 'https://catchmomentum.requestcatcher.com/health',
    token: 'JWT_TOKEN',
    types: HealthDataType.values,
    chunkSize: 10000,
  );
  await HealthBgSync.requestAuthorization();

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
