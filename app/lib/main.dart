import 'package:flutter/material.dart';

import 'screens/status/status_screen.dart';
import 'screens/upload/upload_screen.dart';
import 'theme/app_theme.dart';

void main() {
  runApp(const NightshiftApp());
}

class NightshiftApp extends StatelessWidget {
  const NightshiftApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nightshift',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      // Dark-first by intent, not by accident: this thing runs at night, on a
      // phone, usually in a dark room, and it's an instrument readout rather
      // than a photo app. Light is fully designed as the daytime alternative,
      // and the system setting still wins.
      themeMode: ThemeMode.system,
      home: const _RootShell(),
    );
  }
}

/// Upload and Status as sibling tabs, each keeping its own Scaffold and app
/// bar (Settings stays reachable from Upload's app bar). IndexedStack, not a
/// fresh widget per tab switch, so neither screen's state -- least of all
/// Upload's in-flight engine.run() calls -- gets torn down just from tapping
/// over to Status and back.
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
          NavigationDestination(
            icon: Icon(Icons.arrow_upward),
            label: 'UPLOAD',
          ),
          NavigationDestination(
            icon: Icon(Icons.equalizer),
            label: 'STATUS',
          ),
        ],
      ),
    );
  }
}
