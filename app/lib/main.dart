import 'package:flutter/material.dart';

import 'screens/status/status_screen.dart';
import 'screens/upload/upload_screen.dart';

void main() {
  runApp(const NightshiftApp());
}

class NightshiftApp extends StatelessWidget {
  const NightshiftApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nightshift',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const _RootShell(),
    );
  }
}

/// M5: Upload and Status as sibling tabs, each keeping its own Scaffold
/// and AppBar (Settings stays reachable from Upload's AppBar action).
/// IndexedStack, not a fresh widget per tab switch, so neither screen's
/// state -- least of all Upload's in-flight engine.run() calls -- gets
/// torn down just from tapping over to Status and back.
class _RootShell extends StatefulWidget {
  const _RootShell();

  @override
  State<_RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<_RootShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [UploadScreen(), StatusScreen()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.upload_file), label: 'Upload'),
          NavigationDestination(icon: Icon(Icons.dashboard_outlined), label: 'Status'),
        ],
      ),
    );
  }
}
