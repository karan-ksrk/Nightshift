// Status screen, against an injected ffi-backed in-memory UploadsDao (same
// reasoning as upload_screen_test.dart) and an injected FakeNightshiftClient
// (same technique as upload_engine_test.dart's) so no real network or
// flutter_secure_storage/shared_preferences platform channel is touched --
// passing `client` directly makes StatusScreen skip Settings entirely.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:nightshift_app/core/api/nightshift_client.dart';
import 'package:nightshift_app/core/db/uploads_dao.dart';
import 'package:nightshift_app/models/local_upload.dart';
import 'package:nightshift_app/screens/status/status_screen.dart';

class FakeNightshiftClient extends NightshiftClient {
  FakeNightshiftClient() : super(host: 'unused', port: 0, token: 'unused');

  Map<String, dynamic> statusResponse = const {
    'counts': <String, dynamic>{},
    'pacific_day': '2026-09-08',
    'uploads_used': 0,
    'daily_upload_budget': 100,
    'bytes_used': 0,
    'daily_byte_budget': null,
    'carry_debt': 0,
    'queued_bytes': 0,
    'estimated_days_to_drain': null,
  };

  List<Map<String, dynamic>> filesResponse = const [];

  @override
  Future<Map<String, dynamic>> status() async => statusResponse;

  @override
  Future<Map<String, dynamic>> files({String? state, int limit = 50, int offset = 0}) async {
    if (offset > 0) return {'total': filesResponse.length, 'files': <Map<String, dynamic>>[]};
    return {'total': filesResponse.length, 'files': filesResponse};
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('Status screen renders the summary card and an empty file list',
      (tester) async {
    final dao = UploadsDao(pathOverride: inMemoryDatabasePath);
    addTearDown(dao.close);
    final client = FakeNightshiftClient()
      ..statusResponse = {
        ...FakeNightshiftClient().statusResponse,
        'counts': {
          'QUEUED': {'files': 3, 'bytes': 300000000},
        },
        'uploads_used': 3,
      };

    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: StatusScreen(dao: dao, client: client)));
      await Future.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    });

    expect(find.textContaining('Uploads: 3 / 100'), findsOneWidget);
    expect(find.textContaining('QUEUED: 3 file(s)'), findsOneWidget);
    expect(find.text('No files picked yet.'), findsOneWidget);
  });

  testWidgets('Status screen merges server_state onto local rows by sha256 on refresh',
      (tester) async {
    final dao = UploadsDao(pathOverride: inMemoryDatabasePath);
    addTearDown(dao.close);

    final client = FakeNightshiftClient()
      ..filesResponse = [
        {'id': 5, 'sha256': 'a' * 64, 'state': 'VERIFIED'},
      ];

    late int id;
    LocalUpload? row;

    // Every DB-touching call here -- including the seed inserts, not just
    // the widget's own indirect calls -- must run inside runAsync(): a
    // plain awaited sqflite_common_ffi call in testWidgets()'s fake-async
    // zone never gets pumped and hangs forever. See upload_screen_test.dart.
    await tester.runAsync(() async {
      id = await dao.insertPending(
        localUri: 'content://media/a.mp4',
        localPath: '/sdcard/a.mp4',
        filename: 'a.mp4',
        sizeBytes: 1000,
      );
      await dao.setHashComputed(id, 'a' * 64);
      await dao.setConfirmed(id, serverFileId: 5, serverState: 'QUEUED');

      await tester.pumpWidget(MaterialApp(home: StatusScreen(dao: dao, client: client)));
      await Future.delayed(const Duration(milliseconds: 100));
      await tester.pump();

      row = await dao.findById(id);
    });

    expect(find.textContaining('Pi: VERIFIED'), findsOneWidget);
    expect(row!.serverState, 'VERIFIED'); // persisted, not just rendered
  });
}
