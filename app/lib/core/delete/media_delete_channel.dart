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

  /// Call once, right after picking, before hashing/uploading even starts.
  /// Upgrades file_picker's transient SAF read/write grant into one that
  /// survives the app's own process being killed in the background --
  /// which a multi-hundred-MB upload batch gives Android plenty of time to
  /// do, confirmed for real during the M7 run: uploads survived that kind
  /// of restart via the resume logic, but Delete failed afterward on every
  /// file picked before this existed, since the transient grant didn't
  /// survive it. Best-effort and silent on failure -- not every
  /// DocumentsProvider supports persisting, and this must never block or
  /// fail the pick/upload flow either way.
  Future<void> persistAccess(String uri) async {
    try {
      await _channel.invokeMethod<bool>('persistAccess', {'uri': uri});
    } catch (_) {
      // Best-effort only -- the pick/upload continues regardless.
    }
  }
}
