import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../../models/local_upload.dart';
import 'schema.dart';

/// Hand-written SQL over the `uploads` table -- see schema.dart. One
/// instance per app run in production (default constructor); tests pass
/// `pathOverride: inMemoryDatabasePath` for an isolated in-memory db per
/// test, after pointing sqflite's global `databaseFactory` at
/// sqflite_common_ffi (see uploads_dao_test.dart).
class UploadsDao {
  final String? _pathOverride;
  Database? _db;

  UploadsDao({String? pathOverride}) : _pathOverride = pathOverride;

  Future<Database> get _database async {
    if (_db != null) return _db!;
    final dbPath = _pathOverride ??
        path.join(await getDatabasesPath(), 'nightshift_uploads.db');
    _db = await openDatabase(
      dbPath,
      version: schemaVersion,
      onCreate: (db, version) async {
        await db.execute(createUploadsTableSql);
        await db.execute(createStateIndexSql);
      },
      // Guarded ALTERs per version bump, same shape as db.py's _migrate()
      // -- never rewrite createUploadsTableSql for an already-shipped
      // version, since onCreate only runs for a brand-new database file.
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(alterAddHiddenFromListSql);
        }
      },
    );
    return _db!;
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  String get _now => DateTime.now().toIso8601String();

  /// A file was just picked; hashing hasn't run yet, so sha256 is unknown.
  /// Returns the new row's id.
  Future<int> insertPending({
    required String localUri,
    required String localPath,
    required String filename,
    required int sizeBytes,
  }) async {
    final db = await _database;
    final now = _now;
    return db.insert('uploads', {
      'local_uri': localUri,
      'local_path': localPath,
      'filename': filename,
      'size_bytes': sizeBytes,
      'state': LocalUploadState.pending.name,
      'added_at': now,
      'updated_at': now,
      'bytes_sent': 0,
      'attempts': 0,
    });
  }

  Future<void> markHashing(int id) => _setState(id, LocalUploadState.hashing);

  /// Hashing completed with [sha256]. If another row already holds this
  /// exact hash (re-picking the same file), the just-created PENDING row
  /// for [id] is a transient duplicate -- not manifest data, since it was
  /// never a confirmed pick of distinct content -- so it's deleted outright
  /// rather than left to collide with the UNIQUE constraint. Returns the id
  /// the caller should track from here on (either [id] itself, now READY,
  /// or the pre-existing row's id).
  Future<int> setHashComputed(int id, String sha256) async {
    final db = await _database;
    final existing = await findBySha256(sha256);
    if (existing != null && existing.id != id) {
      await db.delete('uploads', where: 'id = ?', whereArgs: [id]);
      return existing.id!;
    }
    await db.update(
      'uploads',
      {
        'sha256': sha256,
        'state': LocalUploadState.ready.name,
        'updated_at': _now,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    return id;
  }

  Future<void> setServerUploadId(int id, String serverUploadId) async {
    final db = await _database;
    await db.update(
      'uploads',
      {
        'server_upload_id': serverUploadId,
        'state': LocalUploadState.uploading.name,
        'updated_at': _now,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> setBytesSent(int id, int bytesSent) async {
    final db = await _database;
    await db.update(
      'uploads',
      {'bytes_sent': bytesSent, 'updated_at': _now},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> markVerifying(int id) =>
      _setState(id, LocalUploadState.verifying);

  Future<void> markHashMismatch(int id, {required String lastError}) async {
    final db = await _database;
    await db.update(
      'uploads',
      {
        'state': LocalUploadState.hashMismatch.name,
        'bytes_sent': 0, // full-file resend, per the plan's retry rule
        'attempts': (await findById(id))!.attempts + 1,
        'last_error': lastError,
        'updated_at': _now,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> markFailed(int id, {required String lastError}) async {
    final db = await _database;
    await db.update(
      'uploads',
      {
        'state': LocalUploadState.failed.name,
        'last_error': lastError,
        'updated_at': _now,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// /complete succeeded, OR /init returned 409 duplicate -- both are
  /// proven by the same sha256 match, so both land here identically. This
  /// is what unlocks the manual delete button, not reaching the Pi's
  /// VERIFIED (YouTube-processing) stage.
  Future<void> setConfirmed(
    int id, {
    required int serverFileId,
    required String serverState,
  }) async {
    final db = await _database;
    await db.update(
      'uploads',
      {
        'state': LocalUploadState.confirmed.name,
        'server_file_id': serverFileId,
        'server_state': serverState,
        'confirmed_at': _now,
        'updated_at': _now,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Refreshes the last-observed Pi-side state (Status screen polling).
  /// Informational only -- never changes the local [state] or gates
  /// anything.
  Future<void> setServerState(int id, String serverState) async {
    final db = await _database;
    await db.update(
      'uploads',
      {'server_state': serverState, 'updated_at': _now},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> setDeletedLocal(int id) async {
    final db = await _database;
    await db.update(
      'uploads',
      {
        'state': LocalUploadState.deletedLocal.name,
        'deleted_at': _now,
        'updated_at': _now,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Local-only: drops the row out of the default list view without
  /// touching the phone file, the Pi, or the row itself (still queryable
  /// with `includeHidden: true`). For rows the Delete button can never
  /// resolve -- most commonly a pick made before persistAccess existed.
  Future<void> hideFromList(int id) async {
    final db = await _database;
    await db.update(
      'uploads',
      {'hidden_from_list': 1, 'updated_at': _now},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<LocalUpload?> findById(int id) async {
    final db = await _database;
    final rows = await db.query('uploads', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : LocalUpload.fromMap(rows.first);
  }

  Future<LocalUpload?> findBySha256(String sha256) async {
    final db = await _database;
    final rows =
        await db.query('uploads', where: 'sha256 = ?', whereArgs: [sha256]);
    return rows.isEmpty ? null : LocalUpload.fromMap(rows.first);
  }

  /// All rows, oldest pick first. Optionally scoped to one state (e.g. the
  /// resume sweep on app launch looks for UPLOADING/VERIFYING rows).
  /// Excludes rows hidden via [hideFromList] unless [includeHidden] is set
  /// -- the manifest row itself is never actually removed.
  Future<List<LocalUpload>> all({
    LocalUploadState? state,
    bool includeHidden = false,
  }) async {
    final db = await _database;
    final conditions = <String>[];
    final args = <Object?>[];
    if (state != null) {
      conditions.add('state = ?');
      args.add(state.name);
    }
    if (!includeHidden) {
      conditions.add('hidden_from_list = 0');
    }
    final rows = await db.query(
      'uploads',
      where: conditions.isEmpty ? null : conditions.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'added_at ASC',
    );
    return rows.map(LocalUpload.fromMap).toList();
  }

  Future<void> _setState(int id, LocalUploadState state) async {
    final db = await _database;
    await db.update(
      'uploads',
      {'state': state.name, 'updated_at': _now},
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
