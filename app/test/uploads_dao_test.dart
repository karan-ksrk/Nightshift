// UploadsDao against a real SQLite engine (sqflite_common_ffi), one fresh
// in-memory database per test -- not a mock, not the plugin's platform
// channel (which doesn't exist on a host machine). This exercises the
// actual SQL in uploads_dao.dart/schema.dart, including the UNIQUE
// constraint's NULL-tolerance and the dedupe-collapse logic.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:nightshift_app/core/db/uploads_dao.dart';
import 'package:nightshift_app/models/local_upload.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late UploadsDao dao;

  setUp(() {
    // inMemoryDatabasePath -- a fresh db per test, nothing persisted to
    // disk, no cross-test bleed.
    dao = UploadsDao(pathOverride: inMemoryDatabasePath);
  });

  tearDown(() => dao.close());

  Future<int> pick(String name, {int size = 1000}) => dao.insertPending(
        localUri: 'content://media/$name',
        localPath: '/sdcard/DCIM/$name',
        filename: name,
        sizeBytes: size,
      );

  group('insert', () {
    test('a freshly picked file starts PENDING with no hash yet', () async {
      final id = await pick('a.mp4');
      final row = await dao.findById(id);

      expect(row, isNotNull);
      expect(row!.state, LocalUploadState.pending);
      expect(row.sha256, isNull);
      expect(row.filename, 'a.mp4');
      expect(row.bytesSent, 0);
      expect(row.attempts, 0);
    });

    test('several not-yet-hashed rows coexist despite sha256 UNIQUE',
        () async {
      // The whole point of sha256 being nullable-UNIQUE rather than
      // NOT NULL UNIQUE: SQLite doesn't treat NULLs as equal to each
      // other, so multiple PENDING picks don't collide before hashing.
      final a = await pick('a.mp4');
      final b = await pick('b.mp4');

      expect(a, isNot(b));
      expect((await dao.findById(a))!.sha256, isNull);
      expect((await dao.findById(b))!.sha256, isNull);
    });
  });

  group('unique-sha256 conflict / dedupe collapse', () {
    test('hashing to a new sha256 moves the row to READY', () async {
      final id = await pick('a.mp4');
      await dao.markHashing(id);
      expect((await dao.findById(id))!.state, LocalUploadState.hashing);

      final resultId = await dao.setHashComputed(id, 'a' * 64);

      expect(resultId, id); // no collision -- same row carries on
      final row = await dao.findById(id);
      expect(row!.state, LocalUploadState.ready);
      expect(row.sha256, 'a' * 64);
    });

    test('re-picking the same content collapses onto the existing row',
        () async {
      final first = await pick('a.mp4');
      await dao.setHashComputed(first, 'deadbeef' * 8);

      // User picks the same file again (e.g. from a different folder, or
      // just re-taps it) -- a second PENDING row exists until its hash is
      // known to match.
      final second = await pick('a-copy.mp4');
      final resolvedId = await dao.setHashComputed(second, 'deadbeef' * 8);

      // Collapses onto the first row's id, not a new one.
      expect(resolvedId, first);
      // The transient duplicate PENDING row is gone, not left dangling.
      expect(await dao.findById(second), isNull);

      final all = await dao.all();
      expect(all.length, 1);
    });

    test('two distinct hashes never collide', () async {
      final a = await pick('a.mp4');
      final b = await pick('b.mp4');
      await dao.setHashComputed(a, 'a' * 64);
      await dao.setHashComputed(b, 'b' * 64);

      final all = await dao.all();
      expect(all.length, 2);
    });
  });

  group('state transitions', () {
    test('the full happy path: PENDING -> ... -> CONFIRMED', () async {
      final id = await pick('a.mp4');
      await dao.markHashing(id);
      await dao.setHashComputed(id, 'a' * 64);
      await dao.setServerUploadId(id, 'upload-123');
      expect((await dao.findById(id))!.state, LocalUploadState.uploading);
      expect((await dao.findById(id))!.serverUploadId, 'upload-123');

      await dao.setBytesSent(id, 500);
      expect((await dao.findById(id))!.bytesSent, 500);

      await dao.markVerifying(id);
      expect((await dao.findById(id))!.state, LocalUploadState.verifying);

      await dao.setConfirmed(id, serverFileId: 42, serverState: 'QUEUED');
      final row = await dao.findById(id);
      expect(row!.state, LocalUploadState.confirmed);
      expect(row.isConfirmed, isTrue);
      expect(row.serverFileId, 42);
      expect(row.serverState, 'QUEUED');
      expect(row.confirmedAt, isNotNull);
    });

    test('init-duplicate path reaches CONFIRMED without ever uploading',
        () async {
      // A 409 duplicate from /init is treated identically to a successful
      // /complete for delete-eligibility -- both proven by the same
      // sha256 match. No server_upload_id is ever set on this path.
      final id = await pick('a.mp4');
      await dao.setHashComputed(id, 'a' * 64);

      await dao.setConfirmed(id, serverFileId: 7, serverState: 'VERIFIED');

      final row = await dao.findById(id);
      expect(row!.isConfirmed, isTrue);
      expect(row.serverUploadId, isNull);
    });

    test('hash mismatch resets bytes_sent to 0 and increments attempts',
        () async {
      final id = await pick('a.mp4');
      await dao.setHashComputed(id, 'a' * 64);
      await dao.setServerUploadId(id, 'upload-1');
      await dao.setBytesSent(id, 900);

      await dao.markHashMismatch(id, lastError: 'server hash did not match');

      final row = await dao.findById(id);
      expect(row!.state, LocalUploadState.hashMismatch);
      expect(row.bytesSent, 0); // full-file resend, per the retry rule
      expect(row.attempts, 1);
      expect(row.lastError, contains('did not match'));
    });

    test('repeated hash mismatches keep incrementing attempts', () async {
      final id = await pick('a.mp4');
      await dao.setHashComputed(id, 'a' * 64);

      await dao.markHashMismatch(id, lastError: 'try 1');
      await dao.markHashMismatch(id, lastError: 'try 2');
      await dao.markHashMismatch(id, lastError: 'try 3');

      expect((await dao.findById(id))!.attempts, 3);
    });

    test('markFailed records the terminal state and error', () async {
      final id = await pick('a.mp4');

      await dao.markFailed(id, lastError: 'gave up after 3 retries');

      final row = await dao.findById(id);
      expect(row!.state, LocalUploadState.failed);
      expect(row.lastError, 'gave up after 3 retries');
    });

    test('setServerState refreshes server_state without touching local state',
        () async {
      final id = await pick('a.mp4');
      await dao.setHashComputed(id, 'a' * 64);
      await dao.setConfirmed(id, serverFileId: 1, serverState: 'QUEUED');

      await dao.setServerState(id, 'VERIFIED');

      final row = await dao.findById(id);
      expect(row!.serverState, 'VERIFIED');
      expect(row.state, LocalUploadState.confirmed); // unchanged
    });

    test('setDeletedLocal keeps the row -- manifest philosophy', () async {
      final id = await pick('a.mp4');
      await dao.setHashComputed(id, 'a' * 64);
      await dao.setConfirmed(id, serverFileId: 1, serverState: 'VERIFIED');

      await dao.setDeletedLocal(id);

      final row = await dao.findById(id);
      expect(row, isNotNull); // row survives, per db.py's own convention
      expect(row!.state, LocalUploadState.deletedLocal);
      expect(row.deletedAt, isNotNull);
      expect(row.serverFileId, 1); // manifest data intact
    });
  });

  group('queries', () {
    test('all() orders oldest pick first', () async {
      final b = await pick('b.mp4');
      await Future.delayed(const Duration(milliseconds: 5));
      final a = await pick('a.mp4');

      final rows = await dao.all();

      expect(rows.map((r) => r.id).toList(), [b, a]);
    });

    test('all(state: ...) scopes to one state, e.g. the resume sweep',
        () async {
      final uploading = await pick('a.mp4');
      await dao.setHashComputed(uploading, 'a' * 64);
      await dao.setServerUploadId(uploading, 'up-1');

      final confirmed = await pick('b.mp4');
      await dao.setHashComputed(confirmed, 'b' * 64);
      await dao.setConfirmed(confirmed, serverFileId: 1, serverState: 'QUEUED');

      final resumeCandidates = await dao.all(state: LocalUploadState.uploading);

      expect(resumeCandidates.length, 1);
      expect(resumeCandidates.first.id, uploading);
    });

    test('findBySha256 returns null for an unknown hash', () async {
      expect(await dao.findBySha256('c' * 64), isNull);
    });
  });
}
