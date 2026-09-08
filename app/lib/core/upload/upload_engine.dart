import 'dart:io';

import '../../models/local_upload.dart';
import '../api/api_exceptions.dart';
import '../api/nightshift_client.dart';
import '../db/uploads_dao.dart';
import '../hashing/sha256_hasher.dart';

/// Drives one row through pick -> hash -> init -> chunks -> complete ->
/// CONFIRMED. Handles three self-correcting responses the protocol
/// defines: a 416 gap (the server tells us where it actually is; we resume
/// from there), a 409 hash_mismatch on /complete (capped full-file resend),
/// and -- M4 -- authoritative resume whenever [run] is called on a row that
/// already has a server_upload_id, whether that's a manual Retry or an
/// app-restart resume sweep. That last case never trusts a locally cached
/// bytes_sent: it's reconciled against a live GET /offset (or, if the
/// session itself is gone, an /init dedupe-probe) before any chunk is sent.
/// See [_reconcileSession].
///
/// Any other failure -- network drop, unexpected error -- marks the row
/// FAILED (or leaves it wherever it was) and stops; [run] is safe to call
/// again on the same id, since it always starts from the row's current
/// persisted state, not from scratch.
class UploadEngine {
  final NightshiftClient client;
  final UploadsDao dao;

  static const chunkSize = 8 * 1024 * 1024; // 8 MiB, see the plan for why
  static const maxHashMismatchRetries = 3;

  UploadEngine({required this.client, required this.dao});

  Future<void> run(int id, {required void Function(LocalUpload) onUpdate}) async {
    Future<LocalUpload?> reload() async {
      final row = await dao.findById(id);
      if (row != null) onUpdate(row);
      return row;
    }

    try {
      var row = await dao.findById(id);
      if (row == null) return;

      if (row.sha256 == null) {
        await dao.markHashing(id);
        await reload();

        final digest = await sha256File(row.localPath);
        final resolvedId = await dao.setHashComputed(id, digest);
        if (resolvedId != id) {
          // Collapsed onto an existing row -- this pick was a duplicate of
          // content already tracked. Nothing more to do for THIS id; the
          // row it collapsed onto carries whatever state it already had.
          final existing = await dao.findById(resolvedId);
          if (existing != null) onUpdate(existing);
          return;
        }
        row = await reload();
      }

      if (row!.state == LocalUploadState.confirmed) return;

      if (row.serverUploadId == null) {
        try {
          final uploadId = await client.initUpload(
            filename: row.filename,
            sizeBytes: row.sizeBytes,
            sha256: row.sha256!,
            capturedAt: row.capturedAt,
          );
          await dao.setServerUploadId(id, uploadId);
          row = await reload();
        } on NightshiftApiException catch (e) {
          if (e.isDuplicate) {
            // Not a retry signal -- the server already has this content.
            await dao.setConfirmed(
              id,
              serverFileId: e.duplicateFileId!,
              serverState: e.duplicateState ?? 'QUEUED',
            );
          } else {
            await dao.markFailed(id, lastError: e.message);
          }
          await reload();
          return;
        }
      } else {
        // This run() call started with a server_upload_id already on the
        // row -- either a manual Retry or the app-launch resume sweep
        // picking up a row left mid-flight by a force-quit. Either way,
        // never trust whatever bytes_sent was last saved; ask the server.
        row = await _reconcileSession(row);
        if (row.state == LocalUploadState.confirmed) {
          await reload();
          return;
        }
      }

      for (var attempt = 0; attempt < maxHashMismatchRetries; attempt++) {
        await _uploadRemainingChunks(row!, onChunkSent: onUpdate);
        await dao.markVerifying(id);
        row = await reload();

        try {
          final (fileId, state, _) = await client.completeUpload(row!.serverUploadId!);
          await dao.setConfirmed(id, serverFileId: fileId, serverState: state);
          await reload();
          return;
        } on NightshiftApiException catch (e) {
          if (!e.isHashMismatch) {
            await dao.markFailed(id, lastError: e.message);
            await reload();
            return;
          }

          final isLastAttempt = attempt == maxHashMismatchRetries - 1;
          if (isLastAttempt) {
            await dao.markFailed(
              id,
              lastError: 'hash mismatch after $maxHashMismatchRetries attempts',
            );
            await reload();
            return;
          }
          // markHashMismatch resets bytes_sent to 0 -- the next loop
          // iteration's _uploadRemainingChunks resends the whole file,
          // since the client can't know which specific bytes were wrong.
          await dao.markHashMismatch(
            id,
            lastError: 'server hash mismatch, retrying (attempt ${attempt + 1})',
          );
          row = await reload();
        }
      }
    } catch (e) {
      await dao.markFailed(id, lastError: e.toString());
      await reload();
    }
  }

  /// The resume authority for a row that already has a server_upload_id
  /// going into this [run] call. GET /offset is asked, never assumed: the
  /// locally cached bytes_sent could lag what the server actually has (a
  /// chunk landed but the app died before the response was recorded) or
  /// overstate it (the write itself never completed) -- either way, only
  /// the server knows.
  ///
  /// If the session itself is gone (404 -- server restarted, session
  /// expired, the .part file was cleaned up) falls back to re-running
  /// /init with the cached sha256 as a dedupe probe: if the file was
  /// actually fully received and /complete already ran before the app
  /// could record it, /init's own dedupe check now returns 409 duplicate
  /// and the row jumps straight to CONFIRMED with nothing re-sent.
  /// Otherwise it's a genuinely fresh session and the chunk loop restarts
  /// from 0 -- see [_reinitAsDedupeProbe].
  Future<LocalUpload> _reconcileSession(LocalUpload row) async {
    try {
      final offset = await client.uploadOffset(row.serverUploadId!);
      if (offset != row.bytesSent) {
        await dao.setBytesSent(row.id!, offset);
      }
      return (await dao.findById(row.id!))!;
    } on NightshiftApiException catch (e) {
      if (!e.isUnknownUploadId) rethrow;
      return _reinitAsDedupeProbe(row);
    }
  }

  Future<LocalUpload> _reinitAsDedupeProbe(LocalUpload row) async {
    try {
      final uploadId = await client.initUpload(
        filename: row.filename,
        sizeBytes: row.sizeBytes,
        sha256: row.sha256!,
        capturedAt: row.capturedAt,
      );
      // A fresh session starts empty server-side -- the old one, and
      // whatever it had received, is gone with it.
      await dao.setServerUploadId(row.id!, uploadId);
      await dao.setBytesSent(row.id!, 0);
      return (await dao.findById(row.id!))!;
    } on NightshiftApiException catch (e) {
      if (e.isDuplicate) {
        await dao.setConfirmed(
          row.id!,
          serverFileId: e.duplicateFileId!,
          serverState: e.duplicateState ?? 'QUEUED',
        );
        return (await dao.findById(row.id!))!;
      }
      rethrow;
    }
  }

  /// [onChunkSent], when given, is called with the freshly-reloaded row
  /// after every chunk's bytes_sent is persisted -- this is the only place
  /// progress actually changes mid-upload, so without wiring this through,
  /// a caller's UI never animates: it would see UPLOADING once at the
  /// start and CONFIRMED once at the end, with nothing in between.
  Future<void> _uploadRemainingChunks(
    LocalUpload row, {
    void Function(LocalUpload)? onChunkSent,
  }) async {
    if (row.bytesSent >= row.sizeBytes) return;

    Future<void> reportProgress() async {
      if (onChunkSent == null) return;
      final updated = await dao.findById(row.id!);
      if (updated != null) onChunkSent(updated);
    }

    final file = await File(row.localPath).open();
    try {
      var sent = row.bytesSent;
      while (sent < row.sizeBytes) {
        final end =
            (sent + chunkSize > row.sizeBytes) ? row.sizeBytes : sent + chunkSize;
        await file.setPosition(sent);
        final bytes = await file.read(end - sent);

        int received;
        try {
          received = await client.uploadChunk(
            uploadId: row.serverUploadId!,
            bytes: bytes,
            start: sent,
            end: end - 1,
            total: row.sizeBytes,
          );
        } on NightshiftApiException catch (e) {
          if (e.isGap && e.gapOffset != null) {
            // The server knows better than our local cache -- resume from
            // where it actually is, don't guess.
            sent = e.gapOffset!;
            await dao.setBytesSent(row.id!, sent);
            await reportProgress();
            continue;
          }
          rethrow;
        }

        sent = received; // trust the server's count, not an assumed end+1
        await dao.setBytesSent(row.id!, sent);
        await reportProgress();
      }
    } finally {
      await file.close();
    }
  }
}
