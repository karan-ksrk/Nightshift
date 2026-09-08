// Smoke test for the Upload screen. Uses an injected, ffi-backed in-memory
// UploadsDao (see UploadScreen's constructor) so initState's _loadExisting
// never touches sqflite's real platform channel, which doesn't exist in a
// widget test. Never taps "Pick videos" -- file_picker's channel isn't
// mocked here, and exercising the actual pick/hash/upload pipeline against
// a real file and a real server is what the manual on-device runs (M3's
// checkpoint) and UploadEngine's own tests are for.
//
// Every DB-touching interaction below runs inside tester.runAsync(). Two
// separate things make that necessary, not just one:
//   1. sqflite_common_ffi proxies actual SQL execution through a background
//      isolate. Flutter's testWidgets() body runs in a fake-async test
//      zone by default; a real cross-isolate message awaited directly in
//      that zone never gets pumped and hangs forever (confirmed by
//      bisecting: identical DAO calls in a plain `test()` -- no fake-async
//      zone -- pass instantly).
//   2. Even when that real call is triggered *indirectly*, from inside a
//      widget's initState rather than awaited directly in the test body,
//      pumpAndSettle() alone doesn't wait for it either -- it only tracks
//      fake-scheduled frames/animations, not arbitrary outstanding real
//      Futures. A naive first version of this test "passed" while
//      asserting the empty state, but only because empty-before-load and
//      empty-after-a-never-completed-load render identically; the DB read
//      had never actually finished.
// The fix for both: do the real work inside runAsync(), and follow it with
// a real (not pump-scheduled) delay before the final pump() so the async
// gap actually closes.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:nightshift_app/core/db/uploads_dao.dart';
import 'package:nightshift_app/core/delete/media_delete_channel.dart';
import 'package:nightshift_app/screens/upload/upload_screen.dart';
import 'package:nightshift_app/theme/app_theme.dart';

/// Overrides the real platform channel call -- never touches
/// MethodChannel('nightshift/delete'), so no native mock/binding is needed.
class FakeMediaDeleteChannel extends MediaDeleteChannel {
  FakeMediaDeleteChannel(this.result);
  final bool result;
  int calls = 0;
  String? lastUri;

  @override
  Future<bool> delete(String uri) async {
    calls++;
    lastUri = uri;
    return result;
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('Upload screen renders empty state and the pick button', (tester) async {
    final dao = UploadsDao(pathOverride: inMemoryDatabasePath);
    addTearDown(dao.close);

    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark,
        home: UploadScreen(dao: dao),
      ));
      await Future.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    });

    expect(find.text('NO BATCH LOADED'), findsOneWidget);
    expect(find.text('PICK VIDEOS'), findsOneWidget);
  });

  testWidgets('Upload screen loads existing rows from the DAO on start', (tester) async {
    final dao = UploadsDao(pathOverride: inMemoryDatabasePath);
    addTearDown(dao.close);

    await tester.runAsync(() async {
      final id = await dao.insertPending(
        localUri: 'content://media/a.mp4',
        localPath: '/sdcard/a.mp4',
        filename: 'a.mp4',
        sizeBytes: 12345,
      );
      await dao.setHashComputed(id, 'a' * 64);

      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark,
        home: UploadScreen(dao: dao),
      ));
      await Future.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    });

    expect(find.text('NO BATCH LOADED'), findsNothing);
    expect(find.textContaining('a.mp4'), findsOneWidget);
    expect(find.textContaining('READY'), findsOneWidget);
  });

  testWidgets(
      'M6: deleting a CONFIRMED row prompts, then calls the channel and marks DELETED_LOCAL',
      (tester) async {
    final dao = UploadsDao(pathOverride: inMemoryDatabasePath);
    addTearDown(dao.close);
    final deleteChannel = FakeMediaDeleteChannel(true);

    await tester.runAsync(() async {
      final id = await dao.insertPending(
        localUri: 'content://com.android.providers.media.documents/document/video:123',
        localPath: '/sdcard/a.mp4',
        filename: 'a.mp4',
        sizeBytes: 12345,
      );
      await dao.setHashComputed(id, 'a' * 64);
      await dao.setConfirmed(id, serverFileId: 1, serverState: 'QUEUED');

      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark,
        home: UploadScreen(dao: dao, mediaDeleteChannel: deleteChannel),
      ));
      await Future.delayed(const Duration(milliseconds: 100));
      await tester.pump();

      // Confirmed row shows the delete button, not a retry button.
      await tester.tap(find.text('DELETE'));
      await tester.pump();

      // Confirmation dialog appears first -- must not delete without it.
      expect(find.text('Delete from phone?'), findsOneWidget);
      expect(deleteChannel.calls, 0);

      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await Future.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    });

    expect(deleteChannel.calls, 1);
    expect(deleteChannel.lastUri,
        'content://com.android.providers.media.documents/document/video:123');
    expect(find.textContaining('DELETED'), findsOneWidget);
  });

  testWidgets('M6: declining the confirmation dialog never calls the channel',
      (tester) async {
    final dao = UploadsDao(pathOverride: inMemoryDatabasePath);
    addTearDown(dao.close);
    final deleteChannel = FakeMediaDeleteChannel(true);

    await tester.runAsync(() async {
      final id = await dao.insertPending(
        localUri: 'content://media/a.mp4',
        localPath: '/sdcard/a.mp4',
        filename: 'a.mp4',
        sizeBytes: 12345,
      );
      await dao.setHashComputed(id, 'a' * 64);
      await dao.setConfirmed(id, serverFileId: 1, serverState: 'QUEUED');

      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark,
        home: UploadScreen(dao: dao, mediaDeleteChannel: deleteChannel),
      ));
      await Future.delayed(const Duration(milliseconds: 100));
      await tester.pump();

      await tester.tap(find.text('DELETE'));
      await tester.pump();
      await tester.tap(find.text('Cancel'));
      await Future.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    });

    expect(deleteChannel.calls, 0);
    expect(find.textContaining('CONFIRMED'), findsOneWidget);
  });
}
