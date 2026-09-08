/// FastAPI's HTTPException(status_code, detail={...}) nests the payload
/// under a "detail" key -- {"detail": {"error": "gap", "offset": 123}} --
/// not flat. Every error path from server.py comes through here so callers
/// deal with one typed exception, not raw dio DioException/response shapes.
library;

/// Thrown for any non-2xx response from the Nightshift server, or for a
/// network-level failure (no response at all).
class NightshiftApiException implements Exception {
  /// HTTP status code, or null if the request never got a response
  /// (timeout, DNS failure, connection refused -- can't reach the Pi at all).
  final int? statusCode;

  /// The machine-readable error tag from `detail.error`, when the server
  /// sent one (e.g. "duplicate", "gap", "hash_mismatch", "incomplete").
  /// Null for errors that aren't shaped that way (401, plain 404/500 text,
  /// or a network failure).
  final String? errorTag;

  /// The full decoded `detail` payload (dict or string), for callers that
  /// need more than just the error tag -- e.g. `file_id`/`state` on a
  /// duplicate, or `offset` on a gap.
  final dynamic detail;

  final String message;

  const NightshiftApiException({
    required this.message,
    this.statusCode,
    this.errorTag,
    this.detail,
  });

  bool get isNetworkFailure => statusCode == null;
  bool get isUnauthorized => statusCode == 401;
  bool get isDuplicate => errorTag == 'duplicate';
  bool get isGap => errorTag == 'gap';
  bool get isHashMismatch => errorTag == 'hash_mismatch';
  bool get isIncomplete => errorTag == 'incomplete';
  bool get isUnknownUploadId => statusCode == 404;

  /// The `file_id` from a 409 duplicate body, if present.
  int? get duplicateFileId {
    if (detail is Map && detail['file_id'] is int) {
      return detail['file_id'] as int;
    }
    return null;
  }

  /// The `state` from a 409 duplicate body, if present.
  String? get duplicateState {
    if (detail is Map && detail['state'] is String) {
      return detail['state'] as String;
    }
    return null;
  }

  /// The `offset` from a 416 gap body -- where the server actually is,
  /// which the caller must resume from rather than guessing.
  int? get gapOffset {
    if (detail is Map && detail['offset'] is int) {
      return detail['offset'] as int;
    }
    return null;
  }

  @override
  String toString() => 'NightshiftApiException($statusCode, $errorTag: $message)';
}
