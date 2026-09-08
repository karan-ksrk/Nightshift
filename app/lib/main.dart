import 'package:flutter/material.dart';

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
      // M3: Upload is home, Settings reachable via its AppBar action. The
      // Status screen (M5) turns this into a bottom-nav shell.
      home: UploadScreen(),
    );
  }
}
