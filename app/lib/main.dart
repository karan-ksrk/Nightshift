import 'package:flutter/material.dart';

import 'screens/settings/settings_screen.dart';

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
      // M1: Settings is the only screen. Upload/Status get added and this
      // becomes a bottom-nav shell in later milestones.
      home: const SettingsScreen(),
    );
  }
}
