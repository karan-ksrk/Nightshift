import 'package:flutter/material.dart';

import '../../core/api/api_exceptions.dart';
import '../../core/api/nightshift_client.dart';
import '../../core/config/settings_store.dart';
import '../../core/config/token_store.dart';
import '../../theme/app_theme.dart';

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
    if (!mounted) return;
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
      final counts = (status['counts'] as Map<String, dynamic>?) ?? {};
      var files = 0;
      for (final v in counts.values) {
        files += ((v['files'] as num?) ?? 0).toInt();
      }
      if (!mounted) return;
      setState(() {
        _testState = _TestState.success;
        _testMessage = 'CONNECTED · $files FILES ARCHIVED';
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

  void _dirty() => setState(() {
        _saved = false;
        _testState = _TestState.idle;
      });

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ns = context.ns;
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('SERVER')),
      body: Column(
        children: [
          if (_testMessage != null) _ConnBanner(
            state: _testState,
            message: _testMessage!,
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                _Field(
                  label: 'HOST',
                  controller: _hostController,
                  hint: '192.168.1.23',
                  onChanged: _dirty,
                ),
                _Field(
                  label: 'PORT',
                  controller: _portController,
                  hint: '8000',
                  keyboardType: TextInputType.number,
                  onChanged: _dirty,
                ),
                _Field(
                  label: 'X-NIGHTSHIFT-TOKEN',
                  controller: _tokenController,
                  obscure: true,
                  onChanged: _dirty,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 16, 14, 0),
                  child: Text(
                    'Chunk size is fixed at 8 MiB. Uploads run one file at a '
                    'time, only while this app is open.',
                    style: TextStyle(fontSize: 12.5, color: ns.faint),
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
            decoration: BoxDecoration(
              color: ns.surface,
              border: Border(top: BorderSide(color: ns.rule)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed:
                        _testState == _TestState.testing ? null : _testConnection,
                    child: _testState == _TestState.testing
                        ? SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: ns.soft,
                            ),
                          )
                        : const Text('TEST'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: _fieldsLookValid ? _save : null,
                    child: Text(_saved ? 'SAVED' : 'SAVE'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String? hint;
  final bool obscure;
  final TextInputType? keyboardType;
  final VoidCallback onChanged;

  const _Field({
    required this.label,
    required this.controller,
    required this.onChanged,
    this.hint,
    this.obscure = false,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    final ns = context.ns;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: ns.rule)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: NsType.label(context)),
          TextField(
            controller: controller,
            obscureText: obscure,
            keyboardType: keyboardType,
            onChanged: (_) => onChanged(),
            style: TextStyle(
              fontFamily: NsType.mono,
              fontSize: 14,
              color: ns.ink,
            ),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: TextStyle(
                fontFamily: NsType.mono,
                fontSize: 14,
                color: ns.faint,
              ),
              filled: false,
              isDense: true,
              contentPadding: const EdgeInsets.only(top: 6, bottom: 2),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
            ),
          ),
        ],
      ),
    );
  }
}

/// Connection state as a readout line rather than a coloured card -- it
/// reports a fact about the link, so it reads like the rest of the
/// instrumentation.
class _ConnBanner extends StatelessWidget {
  final _TestState state;
  final String message;
  const _ConnBanner({required this.state, required this.message});

  @override
  Widget build(BuildContext context) {
    final ns = context.ns;
    final ok = state == _TestState.success;
    final color = ok ? ns.stateGood : ns.stateBad;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border(bottom: BorderSide(color: ns.rule)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 4),
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              message,
              style: ok
                  ? NsType.data(context, size: 10.5, color: color)
                  : TextStyle(fontSize: 12.5, color: ns.ink, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
