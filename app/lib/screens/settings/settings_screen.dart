import 'package:flutter/material.dart';

import '../../core/api/api_exceptions.dart';
import '../../core/api/nightshift_client.dart';
import '../../core/config/settings_store.dart';
import '../../core/config/token_store.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

enum _TestState { idle, testing, success, failure }

class _SettingsScreenState extends State<SettingsScreen> {
  final _settingsStore = SettingsStore();
  final _tokenStore = TokenStore();

  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '8000');
  final _tokenController = TextEditingController();

  bool _loading = true;
  bool _saved = false;
  _TestState _testState = _TestState.idle;
  String? _testMessage;

  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    final host = await _settingsStore.getHost();
    final port = await _settingsStore.getPort();
    final token = await _tokenStore.getToken();
    setState(() {
      if (host != null) _hostController.text = host;
      if (port != null) _portController.text = port.toString();
      if (token != null) _tokenController.text = token;
      _loading = false;
    });
  }

  int? get _parsedPort => int.tryParse(_portController.text.trim());

  bool get _fieldsLookValid =>
      _hostController.text.trim().isNotEmpty &&
      _parsedPort != null &&
      _tokenController.text.trim().isNotEmpty;

  Future<void> _testConnection() async {
    if (!_fieldsLookValid) {
      setState(() {
        _testState = _TestState.failure;
        _testMessage = 'Fill in host, a valid port, and the token first.';
      });
      return;
    }

    setState(() {
      _testState = _TestState.testing;
      _testMessage = null;
    });

    // Deliberately built from the current field values, not the persisted
    // ones -- so "Test connection" checks what you just typed, before you've
    // committed to it with Save.
    final client = NightshiftClient(
      host: _hostController.text.trim(),
      port: _parsedPort!,
      token: _tokenController.text.trim(),
    );

    try {
      final status = await client.status();
      final queued = status['counts']?['QUEUED']?['files'] ?? 0;
      if (!mounted) return;
      setState(() {
        _testState = _TestState.success;
        _testMessage = 'Connected. $queued file(s) queued on the Pi.';
      });
    } on NightshiftApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _testState = _TestState.failure;
        _testMessage = _describeFailure(e);
      });
    }
  }

  String _describeFailure(NightshiftApiException e) {
    if (e.isUnauthorized) {
      return 'Wrong token -- rejected by the server.';
    }
    if (e.isNetworkFailure) {
      return "Couldn't reach $host:$port -- check the host/port and that "
          "you're on the same network as the Pi.";
    }
    return 'Server error (HTTP ${e.statusCode}): ${e.message}';
  }

  String get host => _hostController.text.trim();
  int get port => _parsedPort ?? 0;

  Future<void> _save() async {
    if (!_fieldsLookValid) return;
    await _settingsStore.save(host: host, port: port);
    await _tokenStore.saveToken(_tokenController.text.trim());
    if (!mounted) return;
    setState(() => _saved = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Saved.')),
    );
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Server settings')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            TextField(
              controller: _hostController,
              decoration: const InputDecoration(
                labelText: 'Host',
                hintText: '100.92.47.48 or 192.168.1.23',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {
                _saved = false;
                _testState = _TestState.idle;
              }),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _portController,
              decoration: const InputDecoration(
                labelText: 'Port',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() {
                _saved = false;
                _testState = _TestState.idle;
              }),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tokenController,
              decoration: const InputDecoration(
                labelText: 'X-Nightshift-Token',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
              onChanged: (_) => setState(() {
                _saved = false;
                _testState = _TestState.idle;
              }),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _testState == _TestState.testing
                        ? null
                        : _testConnection,
                    child: _testState == _TestState.testing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Test connection'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _fieldsLookValid ? _save : null,
                    child: Text(_saved ? 'Saved' : 'Save'),
                  ),
                ),
              ],
            ),
            if (_testMessage != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _testState == _TestState.success
                      ? Colors.green.withValues(alpha: 0.15)
                      : Colors.red.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      _testState == _TestState.success
                          ? Icons.check_circle
                          : Icons.error,
                      color: _testState == _TestState.success
                          ? Colors.green
                          : Colors.red,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_testMessage!)),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
