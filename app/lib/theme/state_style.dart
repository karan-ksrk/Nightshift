import 'package:flutter/material.dart';

import '../models/local_upload.dart';
import 'app_theme.dart';

/// One place that decides how every state looks. Widgets never branch on
/// [LocalUploadState] themselves -- they ask here -- so adding a state means
/// touching this file and nothing else.
///
/// Labels are the state machine's own vocabulary in the machine's own case
/// (UPLOADING, CONFIRMED, not "Sending…" or "All done!"). This is a tool that
/// reports what it is doing; the words match the log lines, the server states
/// and the docs, which is exactly what you want at 2am when something is
/// wrong.
@immutable
class StateStyle {
  final String label;
  final Color color;

  /// Trailing glyph, or null where the row's action button says it better.
  final IconData? icon;

  /// True while the file is actively doing something -- drives whether a
  /// progress bar is shown at all.
  final bool isWorking;

  const StateStyle({
    required this.label,
    required this.color,
    this.icon,
    this.isWorking = false,
  });

  static StateStyle of(BuildContext context, LocalUpload row) {
    final ns = context.ns;
    switch (row.state) {
      case LocalUploadState.pending:
        return StateStyle(label: 'QUEUED', color: ns.stateIdle);
      case LocalUploadState.hashing:
        return StateStyle(
          label: 'HASHING',
          color: ns.stateWorking,
          isWorking: true,
        );
      case LocalUploadState.ready:
        return StateStyle(label: 'READY', color: ns.stateIdle);
      case LocalUploadState.uploading:
        final pct = row.sizeBytes > 0
            ? (row.bytesSent / row.sizeBytes * 100).clamp(0, 100).toStringAsFixed(0)
            : '0';
        return StateStyle(
          label: 'UPLOADING $pct%',
          color: ns.stateWorking,
          isWorking: true,
        );
      case LocalUploadState.verifying:
        return StateStyle(
          label: 'VERIFYING',
          color: ns.stateWorking,
          isWorking: true,
        );
      case LocalUploadState.hashMismatch:
        return StateStyle(
          label: 'MISMATCH',
          color: ns.stateBad,
          isWorking: true,
        );
      case LocalUploadState.confirmed:
        return StateStyle(
          label: 'CONFIRMED',
          color: ns.stateGood,
          icon: Icons.check,
        );
      case LocalUploadState.failed:
        return StateStyle(label: 'FAILED', color: ns.stateBad);
      case LocalUploadState.deletedLocal:
        return StateStyle(label: 'DELETED', color: ns.stateGone);
    }
  }

  /// The Pi-side state travels separately from the phone's own -- a file can
  /// be CONFIRMED here and still QUEUED there, and that gap is the entire
  /// point of the system, so it gets its own colour rather than being folded
  /// into the local state.
  static Color serverColor(BuildContext context, String? serverState) {
    final ns = context.ns;
    switch (serverState) {
      case 'VERIFIED':
        return ns.stateGood;
      case 'UPLOADING':
      case 'PROCESSING':
        return ns.stateWorking;
      case 'FAILED':
        return ns.stateBad;
      case 'DELETED':
        return ns.stateGone;
      default:
        return ns.faint;
    }
  }
}
