/// The phone's own transfer-progress lifecycle -- distinct from, but
/// analogous to, the Pi's QUEUED/UPLOADING/PROCESSING/VERIFIED/DELETED/
/// FAILED (tracked separately as `serverState`, informational only).
///
///   PENDING -> HASHING -> READY -> UPLOADING -> VERIFYING -> CONFIRMED -> DELETED_LOCAL
///                                       \-> HASH_MISMATCH (capped auto-retry) -> FAILED
///
/// A 409 duplicate from /init jumps straight READY -> CONFIRMED: both paths
/// are proven by the same sha256 match, so both unlock the delete button.
enum LocalUploadState {
  pending,
  hashing,
  ready,
  uploading,
  verifying,
  hashMismatch,
  confirmed,
  failed,
  deletedLocal;

  static LocalUploadState fromName(String name) =>
      LocalUploadState.values.firstWhere((s) => s.name == name);
}

/// One row = one picked file, mirroring db.py's philosophy: rows persist
/// through state changes rather than being replaced or removed (the sole
/// exception is a PENDING row collapsing onto an existing match once
/// hashing reveals it's a re-pick of already-tracked content -- see
/// UploadsDao.setHashComputed).
class LocalUpload {
  final int? id;

  /// Original content:// URI (file_picker's PlatformFile.identifier) --
  /// needed for delete, since [localPath] is often a cached copy, not the
  /// real document.
  final String localUri;

  /// Readable path used for hashing/reading bytes.
  final String localPath;

  final String filename;
  final int sizeBytes;

  /// Null until hashing completes. UNIQUE once set -- SQLite's UNIQUE
  /// constraint allows multiple NULLs, so several not-yet-hashed PENDING
  /// rows coexist fine; only real hashes collide.
  final String? sha256;

  /// Best-effort only -- the server has its own ffprobe/mtime fallback.
  final String? capturedAt;

  final DateTime addedAt;
  final DateTime updatedAt;

  final LocalUploadState state;

  /// uuid hex from POST /upload/init.
  final String? serverUploadId;

  /// From POST /upload/complete's response, or a 409 duplicate body.
  final int? serverFileId;

  /// Last observed Pi-side state (QUEUED/UPLOADING/.../VERIFIED/...),
  /// refreshed by the Status screen. Informational only -- gates nothing.
  final String? serverState;

  /// Cache only. A resume always re-confirms via GET /offset before
  /// trusting this -- see the upload engine (M4).
  final int bytesSent;

  final int attempts;
  final String? lastError;

  /// Set the moment /complete succeeds OR /init returns 409 duplicate --
  /// this is what gates the manual delete button, not reaching VERIFIED.
  final DateTime? confirmedAt;

  final DateTime? deletedAt;

  /// Local-only: dropped from the default list view (see
  /// UploadsDao.hideFromList) without touching the phone file, the Pi, or
  /// the row itself. Never displayed as a state -- just a UI filter.
  final bool hiddenFromList;

  const LocalUpload({
    this.id,
    required this.localUri,
    required this.localPath,
    required this.filename,
    required this.sizeBytes,
    this.sha256,
    this.capturedAt,
    required this.addedAt,
    required this.updatedAt,
    required this.state,
    this.serverUploadId,
    this.serverFileId,
    this.serverState,
    this.bytesSent = 0,
    this.attempts = 0,
    this.lastError,
    this.confirmedAt,
    this.deletedAt,
    this.hiddenFromList = false,
  });

  bool get isConfirmed => state == LocalUploadState.confirmed;

  factory LocalUpload.fromMap(Map<String, Object?> m) => LocalUpload(
        id: m['id'] as int?,
        localUri: m['local_uri'] as String,
        localPath: m['local_path'] as String,
        filename: m['filename'] as String,
        sizeBytes: m['size_bytes'] as int,
        sha256: m['sha256'] as String?,
        capturedAt: m['captured_at'] as String?,
        addedAt: DateTime.parse(m['added_at'] as String),
        updatedAt: DateTime.parse(m['updated_at'] as String),
        state: LocalUploadState.fromName(m['state'] as String),
        serverUploadId: m['server_upload_id'] as String?,
        serverFileId: m['server_file_id'] as int?,
        serverState: m['server_state'] as String?,
        bytesSent: m['bytes_sent'] as int? ?? 0,
        attempts: m['attempts'] as int? ?? 0,
        lastError: m['last_error'] as String?,
        confirmedAt: m['confirmed_at'] != null
            ? DateTime.parse(m['confirmed_at'] as String)
            : null,
        deletedAt: m['deleted_at'] != null
            ? DateTime.parse(m['deleted_at'] as String)
            : null,
        hiddenFromList: (m['hidden_from_list'] as int? ?? 0) == 1,
      );
}
