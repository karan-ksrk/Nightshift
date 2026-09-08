import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The server's shared-secret token (X-Nightshift-Token) is a credential,
/// not a preference -- Android Keystore-backed encrypted storage, not plain
/// SharedPreferences.
class TokenStore {
  static const _tokenKey = 'server_token';
  final _storage = const FlutterSecureStorage();

  Future<String?> getToken() => _storage.read(key: _tokenKey);

  Future<void> saveToken(String token) =>
      _storage.write(key: _tokenKey, value: token);

  Future<void> clear() => _storage.delete(key: _tokenKey);
}
