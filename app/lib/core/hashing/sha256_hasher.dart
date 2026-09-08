import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

/// Streams [path] through SHA-256 in a background isolate. Never loads the
/// whole file into memory -- reads and hashes in whatever chunks
/// [File.openRead] yields -- which matters for a multi-GB video, and keeps
/// the UI thread free while it runs.
///
/// No live byte-progress callback: `Isolate.run`'s closure can't safely
/// call back into the host isolate without setting up its own SendPort/
/// ReceivePort pair, which isn't worth the complexity for M3's scope. The
/// Upload screen shows an indeterminate spinner during HASHING instead of
/// a percentage -- fine for now; add ports here if per-byte progress turns
/// out to matter in practice.
Future<String> sha256File(String path) {
  return Isolate.run(() async {
    final sink = _SingleDigestSink();
    final input = sha256.startChunkedConversion(sink);
    await for (final chunk in File(path).openRead()) {
      input.add(chunk);
    }
    input.close();
    return sink.digest.toString();
  });
}

class _SingleDigestSink implements Sink<Digest> {
  Digest? _digest;

  Digest get digest => _digest!;

  @override
  void add(Digest data) => _digest = data;

  @override
  void close() {}
}
