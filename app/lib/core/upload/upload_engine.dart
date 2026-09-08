import 'dart:io';

import '../../models/local_upload.dart';
import '../api/api_exceptions.dart';
import '../api/nightshift_client.dart';
import '../db/uploads_dao.dart';
import '../hashing/sha256_hasher.dart';

/// Drives one row through pick -> hash -> init -> chunks -> complete ->
/// CONFIRMED. M3 scope: straight-through, single app session. Authoritative
/// resume-after-app-restart (reconciling against a live GET /offset call
/// rather than trusting locally-cached bytes_sent) is M4's job -- see the
/// plan. Within a single run, though, this already handles the two
/// self-correcting responses the protocol defines: a 416 gap (the server
/// tells us where it actually is; we resume from there) and a 409
/// hash_mismatch on /complete (capped full-file resend).
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
      }

      for (var attempt = 0; attempt < maxHashMismatchRetries; attempt++) {
        await _uploadRemainingChunks(row!);
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

  Future<void> _uploadRemainingChunks(LocalUpload row) async {
    if (row.bytesSent >= row.sizeBytes) return;

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
            continue;
          }
          rethrow;
        }

        sent = received; // trust the server's count, not an assumed end+1
        await dao.setBytesSent(row.id!, sent);
      }
    } finally {
      await file.close();
    }
  }
}
