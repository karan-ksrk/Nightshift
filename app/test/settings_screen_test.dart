// Smoke test for the Settings screen: fields render, and Save stays
// disabled until host/port/token all look filled in -- _fieldsLookValid
// gating actually works, not just visually present.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nightshift_app/screens/settings/settings_screen.dart';
import 'package:nightshift_app/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // SettingsStore hits shared_preferences, which has an official
    // test-friendly in-memory backend.
    SharedPreferences.setMockInitialValues({});

    // TokenStore hits flutter_secure_storage, which has no platform
    // implementation at all in the test environment -- without this, its
    // MethodChannel call never returns and the Settings screen's initState
    // load hangs forever (that's what caused pumpAndSettle to time out).
    // Mock it to answer "no token saved yet", same as a real fresh install.
    const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'read':
          return null;
        case 'write':
        case 'delete':
          return null;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  // The real theme, not a bare MaterialApp -- these screens read colour and
  // type tokens from a ThemeExtension, so testing without it would exercise
  // a configuration that never ships.
  Widget wrap(Widget child) => MaterialApp(theme: AppTheme.dark, home: child);

  testWidgets('Settings screen renders host/port/token fields', (tester) async {
    await tester.pumpWidget(wrap(const SettingsScreen()));
    await tester.pumpAndSettle();

    expect(find.text('HOST'), findsOneWidget);
    expect(find.text('PORT'), findsOneWidget);
    expect(find.text('X-NIGHTSHIFT-TOKEN'), findsOneWidget);
    expect(find.text('TEST'), findsOneWidget);
  });

  testWidgets('Save is disabled until host/port/token are all filled', (tester) async {
    await tester.pumpWidget(wrap(const SettingsScreen()));
    await tester.pumpAndSettle();

    final saveButton = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(saveButton.onPressed, isNull, reason: 'nothing filled in yet');

    // Field labels sit beside their TextField rather than inside the
    // decoration, so target by position: host, port, token, in order.
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '192.168.1.23');
    await tester.enterText(fields.at(1), '8000');
    await tester.enterText(fields.at(2), 'test-token');
    await tester.pump();

    final saveButtonAfter =
        tester.widget<FilledButton>(find.byType(FilledButton));
    expect(saveButtonAfter.onPressed, isNotNull);
  });
}
