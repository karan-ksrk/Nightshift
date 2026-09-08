import 'package:flutter/services.dart';

/// Thin wrapper over the native "nightshift/delete" platform channel -- see
/// MainActivity.kt for the actual delete logic: DocumentsContract, for the
/// SAF document URIs file_picker's Android implementation actually hands
/// back (checked against its source, not assumed), with a
/// MediaStore.createDeleteRequest / RecoverableSecurityException fallback
/// for any picker path that returns a raw MediaStore URI instead.
///
/// Returns true if the file was actually removed, or was already gone.
/// Returns false only when a system confirmation dialog was shown and the
/// user explicitly declined it -- distinct from throwing.
///
/// Throws [PlatformException] for a genuine failure. Most notably code
/// "permission_denied": file_picker never takes a persistable grant on the
/// picked URI, so the one-time permission from the original pick can
/// already be gone by the time Delete is tapped (most likely across an app
/// restart) -- there's nothing to retry automatically for that case.
class MediaDeleteChannel {
  static const _channel = MethodChannel('nightshift/delete');

  Future<bool> delete(String uri) async {
    final result = await _channel.invokeMethod<bool>('delete', {'uri': uri});
    return result ?? false;
  }
}
