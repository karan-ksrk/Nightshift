// UploadEngine's resume logic (M4), against a real sqflite_common_ffi DAO
// and a FakeNightshiftClient -- a plain subclass of NightshiftClient that
// overrides the four methods the engine calls, so no real dio/network is
// involved. These are plain test()s, not testWidgets(), so none of
// upload_screen_test.dart's fake-async-zone workaround is needed here --
// sqflite_common_ffi's cross-isolate calls run fine when directly awaited
// outside a widget test's zone.

import 'dart:io';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:nightshift_app/core/api/api_exceptions.dart';
import 'package:nightshift_app/core/api/nightshift_client.dart';
import 'package:nightshift_app/core/db/uploads_dao.dart';
import 'package:nightshift_app/core/upload/upload_engine.dart';
import 'package:nightshift_app/models/local_upload.dart';

/// Records calls and lets each test script canned responses/failures for
/// the handful of methods UploadEngine actually calls. Never touches the
/// network -- the constructor's host/port/token are throwaway.
class FakeNightshiftClient extends NightshiftClient {
  FakeNightshiftClient() : super(host: 'unused', port: 0, token: 'unused');

  int offsetCalls = 0;
  int initCalls = 0;
  int chunkCalls = 0;
  int completeCalls = 0;
  final List<int> chunkStarts = [];

  Object? Function()? onOffset; // returns int, or throws
  Object? Function()? onInit; // returns String upload_id, or throws
  Object? Function()? onComplete; // returns (int,String,bool), or throws

  @override
  Future<int> uploadOffset(String uploadId) async {
    offsetCalls++;
    final result = onOffset!();
    if (result is Exception) throw result;
    return result as int;
  }

  @override
  Future<String> initUpload({
    required String filename,
    required int sizeBytes,
    required String sha256,
    String? capturedAt,
  }) async {
    initCalls++;
    final result = onInit!();
    if (result is Exception) throw result;
    return result as String;
  }

  @override
  Future<int> uploadChunk({
    required String uploadId,
    required List<int> bytes,
    required int start,
    required int end,
    required int total,
    void Function(int sent, int total)? onSendProgress,
    CancelToken? cancelToken,
  }) async {
    chunkCalls++;
    chunkStarts.add(start);
    return end + 1; // pretend the server received exactly what was sent
  }

  @override
  Future<(int, String, bool)> completeUpload(String uploadId) async {
    completeCalls++;
    final result = onComplete!();
    if (result is Exception) throw result;
    return result as (int, String, bool);
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late UploadsDao dao;
  late FakeNightshiftClient client;
  late UploadEngine engine;
  late Directory tmpDir;

  setUp(() async {
    dao = UploadsDao(pathOverride: inMemoryDatabasePath);
    client = FakeNightshiftClient();
    engine = UploadEngine(client: client, dao: dao);
    tmpDir = await Directory.systemTemp.createTemp('nightshift_engine_test');
  });

  tearDown(() async {
    await dao.close();
    await tmpDir.delete(recursive: true);
  });

  Future<int> pickWithFile(String name, List<int> bytes) async {
    final file = File('${tmpDir.path}/$name');
    await file.writeAsBytes(bytes);
    return dao.insertPending(
      localUri: 'content://media/$name',
      localPath: file.path,
      filename: name,
      sizeBytes: bytes.length,
    );
  }

  group('progress reporting', () {
    test('onUpdate fires with growing bytes_sent after every chunk, not just once at the end',
        () async {
      // Regression test: _uploadRemainingChunks used to persist bytes_sent
      // per chunk but never call back into onUpdate until the whole file
      // was done, so the UI saw UPLOADING once at 0% and CONFIRMED once at
      // the end with nothing in between -- no progress bar animation.
      final bytes = List<int>.filled(20 * 1024 * 1024, 5); // 3 chunks of 8MiB
      final id = await pickWithFile('e.mp4', bytes);
      await dao.setHashComputed(id, 'e' * 64);

      client.onInit = () => 'sess-progress';
      client.onComplete = () => (8, 'QUEUED', false);

      final seenBytesSent = <int>[];
      await engine.run(id, onUpdate: (row) {
        if (row.state == LocalUploadState.uploading) {
          seenBytesSent.add(row.bytesSent);
        }
      });

      // One callback when the session opens (bytes_sent still 0) plus one
      // per chunk (3) -- each strictly further along than the last, not a
      // single jump from 0 straight to done.
      expect(seenBytesSent.length, greaterThanOrEqualTo(4));
      expect(seenBytesSent.first, 0);
      expect(seenBytesSent.last, bytes.length);
      for (var i = 1; i < seenBytesSent.length; i++) {
        expect(seenBytesSent[i], greaterThan(seenBytesSent[i - 1]));
      }
    });
  });

  group('resume via GET /offset', () {
    test(
        'a row already fully received server-side skips straight to complete, no chunks resent',
        () async {
      final bytes = List<int>.filled(100, 1);
      final id = await pickWithFile('a.mp4', bytes);
      await dao.setHashComputed(id, 'a' * 64);
      await dao.setServerUploadId(id, 'sess-1');
      // Locally cached bytes_sent is stale/wrong -- the app died before
      // this ever got recorded. The server, however, has it all.
      await dao.setBytesSent(id, 0);

      client.onOffset = () => bytes.length;
      client.onComplete = () => (42, 'QUEUED', false);

      await engine.run(id, onUpdate: (_) {});

      final row = await dao.findById(id);
      expect(row!.state, LocalUploadState.confirmed);
      expect(row.serverFileId, 42);
      expect(client.offsetCalls, 1);
      expect(client.chunkCalls, 0); // nothing left to send
      expect(client.completeCalls, 1);
    });

    test('a row partially received server-side resumes from the reported offset, not from 0',
        () async {
      final bytes = List<int>.filled(20 * 1024 * 1024, 2); // 3 chunks of 8MiB
      final id = await pickWithFile('b.mp4', bytes);
      await dao.setHashComputed(id, 'b' * 64);
      await dao.setServerUploadId(id, 'sess-2');
      await dao.setBytesSent(id, 0); // stale local cache

      const serverOffset = 8 * 1024 * 1024; // server already has chunk 1
      client.onOffset = () => serverOffset;
      client.onComplete = () => (7, 'QUEUED', false);

      await engine.run(id, onUpdate: (_) {});

      final row = await dao.findById(id);
      expect(row!.state, LocalUploadState.confirmed);
      // First resumed chunk must start exactly where the server said it
      // was, never from 0 and never guessed as offset+1-off-by-something.
      expect(client.chunkStarts.first, serverOffset);
      expect(client.chunkCalls, 2); // the remaining two 8MiB chunks
    });
  });

  group('resume via /init dedupe-probe when the session is gone', () {
    test('a vanished session that already completed server-side reaches CONFIRMED with no resend',
        () async {
      final bytes = List<int>.filled(100, 3);
      final id = await pickWithFile('c.mp4', bytes);
      await dao.setHashComputed(id, 'c' * 64);
      await dao.setServerUploadId(id, 'sess-gone');
      await dao.setBytesSent(id, 100);

      client.onOffset = () =>
          const NightshiftApiException(message: 'not found', statusCode: 404);
      client.onInit = () => const NightshiftApiException(
            message: 'duplicate',
            statusCode: 409,
            errorTag: 'duplicate',
            detail: {'error': 'duplicate', 'file_id': 99, 'state': 'VERIFIED'},
          );

      await engine.run(id, onUpdate: (_) {});

      final row = await dao.findById(id);
      expect(row!.state, LocalUploadState.confirmed);
      expect(row.serverFileId, 99);
      expect(row.serverState, 'VERIFIED');
      expect(client.chunkCalls, 0);
      expect(client.completeCalls, 0); // never even reached /complete
    });

    test('a vanished session that was genuinely never finished restarts the upload from 0',
        () async {
      final bytes = List<int>.filled(100, 4);
      final id = await pickWithFile('d.mp4', bytes);
      await dao.setHashComputed(id, 'd' * 64);
      await dao.setServerUploadId(id, 'sess-gone-2');
      await dao.setBytesSent(id, 100); // stale -- claims fully sent

      client.onOffset = () =>
          const NightshiftApiException(message: 'not found', statusCode: 404);
      client.onInit = () => 'sess-fresh';
      client.onComplete = () => (5, 'QUEUED', false);

      await engine.run(id, onUpdate: (_) {});

      final row = await dao.findById(id);
      expect(row!.state, LocalUploadState.confirmed);
      expect(row.serverUploadId, 'sess-fresh');
      expect(client.initCalls, 1);
      expect(client.chunkStarts, [0]); // full resend, not skipped
      expect(client.chunkCalls, 1);
    });
  });
}
