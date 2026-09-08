import 'package:shared_preferences/shared_preferences.dart';

/// Host and port -- not secret, plain key-value via shared_preferences.
/// The server token lives separately in TokenStore (flutter_secure_storage),
/// since it's a credential, not a preference.
class SettingsStore {
  static const _hostKey = 'server_host';
  static const _portKey = 'server_port';

  Future<String?> getHost() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_hostKey);
  }

  Future<int?> getPort() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_portKey);
  }

  Future<void> save({required String host, required int port}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_hostKey, host);
    await prefs.setInt(_portKey, port);
  }
}
