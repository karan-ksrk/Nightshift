import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;

import '../../core/api/nightshift_client.dart';
import '../../core/config/settings_store.dart';
import '../../core/config/token_store.dart';
import '../../core/db/uploads_dao.dart';
import '../../core/delete/media_delete_channel.dart';
import '../../core/upload/upload_engine.dart';
import '../../models/local_upload.dart';
import '../../widgets/progress_row.dart';
import '../settings/settings_screen.dart';

class UploadScreen extends StatefulWidget {
  // Injectable for tests -- defaults to the real, on-device implementations
  // in production. Without this, a widget test would hit sqflite's real
  // platform channel in initState (via UploadsDao()) before any test gets
  // a chance to mock it, the same class of hang the Settings screen's
  // tests had to work around for flutter_secure_storage.
  final UploadsDao dao;
  final SettingsStore settingsStore;
  final TokenStore tokenStore;
  final MediaDeleteChannel mediaDeleteChannel;

  UploadScreen({
    super.key,
    UploadsDao? dao,
    SettingsStore? settingsStore,
    TokenStore? tokenStore,
    MediaDeleteChannel? mediaDeleteChannel,
  })  : dao = dao ?? UploadsDao(),
        settingsStore = settingsStore ?? SettingsStore(),
        tokenStore = tokenStore ?? TokenStore(),
        mediaDeleteChannel = mediaDeleteChannel ?? MediaDeleteChannel();

  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen> {
  UploadsDao get _dao => widget.dao;
  SettingsStore get _settingsStore => widget.settingsStore;
  TokenStore get _tokenStore => widget.tokenStore;
  MediaDeleteChannel get _mediaDeleteChannel => widget.mediaDeleteChannel;

  // In-memory mirror of the DB, keyed by id, so the UI updates live without
  // re-querying on every progress tick. The DAO stays the source of truth
  // -- this is just what's currently rendered.
  final Map<int, LocalUpload> _rows = {};

  bool _picking = false;
  bool _processing = false;

  @override
  void initState() {
    super.initState();
    _loadExisting();
  }

  // Rows left mid-flight by a force-quit or crash -- picked but not yet
  // hashed, hashed but not init'd, mid-upload, mid-verify, or caught in a
  // hash-mismatch retry -- get swept back into the engine on launch. The
  // engine itself decides how to pick each one up: hashing restarts from 0
  // (no partial-hash checkpoint), and anything with a server_upload_id
  // already set reconciles against GET /offset rather than trusting
  // whatever bytes_sent this row was last saved with (M4). Terminal states
  // (confirmed/failed/deletedLocal) are left alone -- failed needs a manual
  // Retry tap, not an automatic one.
  static const _resumableStates = {
    LocalUploadState.pending,
    LocalUploadState.hashing,
    LocalUploadState.ready,
    LocalUploadState.uploading,
    LocalUploadState.verifying,
    LocalUploadState.hashMismatch,
  };

  Future<void> _loadExisting() async {
    final all = await _dao.all();
    if (!mounted) return;
    setState(() {
      for (final row in all) {
        if (row.id != null) _rows[row.id!] = row;
      }
    });

    final resumeIds = [
      for (final row in all)
        if (_resumableStates.contains(row.state) && row.id != null) row.id!,
    ];
    if (resumeIds.isNotEmpty) await _processQueue(resumeIds);
  }

  Future<NightshiftClient> _buildClient() async {
    final host = await _settingsStore.getHost();
    final port = await _settingsStore.getPort();
    final token = await _tokenStore.getToken();
    if (host == null || port == null || token == null) {
      throw StateError('Set up the server in Settings first.');
    }
    return NightshiftClient(host: host, port: port, token: token);
  }

  Future<void> _pickFiles() async {
    setState(() => _picking = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.video,
        allowMultiple: true,
      );
      if (result == null || result.files.isEmpty) return;

      final ids = <int>[];
      for (final f in result.files) {
        final path = f.path;
        if (path == null) continue; // shouldn't happen for FileType.video
        // f.identifier is the original content:// URI on Android (SAF
        // picks), not the cache-copy path -- needed later for M6's manual
        // delete, which has to target the real document, not the cache
        // copy this app reads bytes from.
        final uri = f.identifier ?? path;
        // Right now, before anything else -- the transient grant from the
        // pick is at its freshest here. Upgraded to a persistable one so
        // Delete still works even after the app's process gets killed in
        // the background mid-upload, which a large batch gives Android
        // plenty of time to do (confirmed for real during M7).
        await _mediaDeleteChannel.persistAccess(uri);
        final id = await _dao.insertPending(
          localUri: uri,
          localPath: path,
          filename: f.name,
          sizeBytes: f.size,
        );
        ids.add(id);
        final row = await _dao.findById(id);
        if (row != null && mounted) setState(() => _rows[id] = row);
      }

      if (ids.isNotEmpty) await _processQueue(ids);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Pick failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _processQueue(List<int> ids) async {
    setState(() => _processing = true);
    try {
      final client = await _buildClient();
      final engine = UploadEngine(client: client, dao: _dao);
      // Serial, one file at a time -- simple, and sufficient for a
      // personal-project LAN transfer (matches the chunk loop itself
      // being serial per the plan).
      for (final id in ids) {
        await engine.run(id, onUpdate: (row) {
          if (!mounted || row.id == null) return;
          setState(() => _rows[row.id!] = row);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _retry(int id) => _processQueue([id]);

  /// Unlock condition is CONFIRMED (either /complete or an /init 409
  /// duplicate) -- ProgressRow only ever wires this to a visible button for
  /// rows in that state, not the Pi's own VERIFIED stage. Confirmation
  /// dialog first, per the plan, since this is an irreversible on-device
  /// action even though the content is safely archived either way.
  Future<void> _delete(LocalUpload row) async {
    if (row.id == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete from phone?'),
        content: Text(
          '${row.filename}\n\n'
          'This only removes it from your phone -- already confirmed on the Pi.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final removed = await _mediaDeleteChannel.delete(row.localUri);
      if (removed) {
        await _dao.setDeletedLocal(row.id!);
        final updated = await _dao.findById(row.id!);
        if (updated != null && mounted) setState(() => _rows[row.id!] = updated);
      } else if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Not deleted.')));
      }
    } on PlatformException catch (e) {
      if (!mounted) return;
      if (e.code == 'permission_denied') {
        // Nothing left to retry automatically -- offer to at least get it
        // out of the list, right where the failure happened.
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text(
            "Can't delete automatically -- permission expired. Remove it "
            'manually from your Files app if you want it gone.',
          ),
          action: SnackBarAction(label: 'Remove from list', onPressed: () => _hide(row)),
          duration: const Duration(seconds: 6),
        ));
      } else {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Delete failed: ${e.message}')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }

  /// Local-only: drops the row out of view without touching the phone file,
  /// the Pi, or the row itself (see UploadsDao.hideFromList). Reachable via
  /// long-press on any row, or directly from the permission_denied SnackBar
  /// above.
  Future<void> _hide(LocalUpload row) async {
    if (row.id == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove from list?'),
        content: Text(
          '${row.filename}\n\n'
          "This only removes it from this app's list -- it doesn't touch "
          'the file on your phone or the Pi.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _dao.hideFromList(row.id!);
    if (mounted) setState(() => _rows.remove(row.id));
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows.values.toList()
      ..sort((a, b) => a.addedAt.compareTo(b.addedAt));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nightshift'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: rows.isEmpty
          ? const Center(child: Text('No files picked yet.'))
          : ListView.builder(
              itemCount: rows.length,
              itemBuilder: (context, i) {
                final row = rows[i];
                return ProgressRow(
                  row: row,
                  onRetry: () => _retry(row.id!),
                  onDelete: () => _delete(row),
                  onHide: () => _hide(row),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: (_picking || _processing) ? null : _pickFiles,
        icon: const Icon(Icons.video_library),
        label: Text(_processing ? 'Uploading…' : 'Pick videos'),
      ),
    );
  }
}
