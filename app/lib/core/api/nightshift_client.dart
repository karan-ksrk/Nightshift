import 'package:dio/dio.dart';

import 'api_exceptions.dart';

/// Thin wrapper over the Phase 2 server API (server.py). One instance per
/// set of credentials -- the Settings screen's "Test connection" builds a
/// throwaway instance from the not-yet-saved fields, the rest of the app
/// uses one built from persisted settings.
///
/// Every call throws [NightshiftApiException] on any non-2xx response or
/// network failure -- callers never touch dio's exception types directly.
class NightshiftClient {
  final Dio _dio;

  NightshiftClient({
    required String host,
    required int port,
    required String token,
    Duration connectTimeout = const Duration(seconds: 10),
  }) : _dio = Dio(
          BaseOptions(
            baseUrl: 'http://$host:$port',
            connectTimeout: connectTimeout,
            // No receive timeout: a chunk PUT over a slow WiFi link can
            // legitimately take a while for an 8MiB body; the connect
            // timeout is what actually catches an unreachable host fast.
            headers: {'X-Nightshift-Token': token},
          ),
        );

  /// GET /status -- counts by state, today's ledger, estimated days to drain.
  /// Used both for the Status screen and as the Settings screen's
  /// "Test connection" probe.
  Future<Map<String, dynamic>> status() async {
    final resp = await _get('/status');
    return resp.data as Map<String, dynamic>;
  }

  /// GET /files?state=&limit=&offset= -- paginated file rows.
  Future<Map<String, dynamic>> files({
    String? state,
    int limit = 50,
    int offset = 0,
  }) async {
    final resp = await _get('/files', queryParameters: {
      'state': ?state,
      'limit': limit,
      'offset': offset,
    });
    return resp.data as Map<String, dynamic>;
  }

  /// POST /upload/init -- returns the upload_id, or throws with
  /// isDuplicate=true (and duplicateFileId/duplicateState set) if this
  /// content is already archived. That's a done signal, not a retry signal.
  Future<String> initUpload({
    required String filename,
    required int sizeBytes,
    required String sha256,
    String? capturedAt,
  }) async {
    final resp = await _post('/upload/init', data: {
      'filename': filename,
      'size_bytes': sizeBytes,
      'sha256': sha256,
      'captured_at': capturedAt,
    });
    return (resp.data as Map<String, dynamic>)['upload_id'] as String;
  }

  /// PUT /upload/{id}/chunk -- raw bytes, exact Content-Range. Returns the
  /// server's own count of bytes now on disk (trust this over any locally
  /// assumed end+1). Throws with isGap=true (and gapOffset set) if `start`
  /// is past what the server has.
  Future<int> uploadChunk({
    required String uploadId,
    required List<int> bytes,
    required int start,
    required int end,
    required int total,
    void Function(int sent, int total)? onSendProgress,
    CancelToken? cancelToken,
  }) async {
    final resp = await _dio.put<Map<String, dynamic>>(
      '/upload/$uploadId/chunk',
      data: Stream.fromIterable([bytes]),
      options: Options(
        headers: {
          'Content-Range': 'bytes $start-$end/$total',
          Headers.contentLengthHeader: bytes.length,
        },
      ),
      onSendProgress: onSendProgress,
      cancelToken: cancelToken,
    ).catchError(_rethrowAsApiException);
    return resp.data!['received'] as int;
  }

  /// GET /upload/{id}/offset -- the resume authority. Never trust a locally
  /// cached byte count; ask the server what it actually has.
  Future<int> uploadOffset(String uploadId) async {
    final resp = await _get('/upload/$uploadId/offset');
    return (resp.data as Map<String, dynamic>)['offset'] as int;
  }

  /// POST /upload/{id}/complete -- re-hashes the assembled bytes server-side.
  /// Returns (fileId, state, isDuplicate). Throws with isHashMismatch=true
  /// (session stays open server-side, caller should re-send and retry) or
  /// isIncomplete=true (resync bytes_sent to detail['received'] and resume).
  Future<(int fileId, String state, bool isDuplicate)> completeUpload(
    String uploadId,
  ) async {
    final resp = await _post('/upload/$uploadId/complete');
    final data = resp.data as Map<String, dynamic>;
    return (
      data['file_id'] as int,
      data['state'] as String,
      data['duplicate'] == true,
    );
  }

  Future<Response> _get(String path, {Map<String, dynamic>? queryParameters}) {
    return _dio
        .get(path, queryParameters: queryParameters)
        .catchError(_rethrowAsApiException);
  }

  Future<Response> _post(String path, {Map<String, dynamic>? data}) {
    return _dio.post(path, data: data).catchError(_rethrowAsApiException);
  }

  Never _rethrowAsApiException(Object error) {
    if (error is DioException) {
      final response = error.response;
      if (response == null) {
        // Never reached the server at all -- wrong host/port, phone not on
        // the same network, Pi's server down, etc.
        throw NightshiftApiException(
          message: error.message ?? 'Network error',
        );
      }
      final body = response.data;
      // FastAPI's HTTPException(status, detail={...}) nests under "detail".
      // A plain string detail (e.g. 401's own message) has no error tag.
      final detail = (body is Map) ? body['detail'] : null;
      final errorTag = (detail is Map) ? detail['error'] as String? : null;
      throw NightshiftApiException(
        message: (detail is String) ? detail : (detail?.toString() ?? 'HTTP ${response.statusCode}'),
        statusCode: response.statusCode,
        errorTag: errorTag,
        detail: detail,
      );
    }
    throw NightshiftApiException(message: error.toString());
  }
}
