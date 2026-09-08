import 'package:flutter/material.dart';

import '../models/local_upload.dart';
import '../theme/app_theme.dart';
import '../theme/state_style.dart';
import 'filename_text.dart';

/// One file. State is carried three ways, in decreasing order of how fast
/// they read: the coloured stripe down the left edge, then the state word in
/// the machine's own vocabulary, then the progress bar if it's moving. The
/// stripe means a failed row is distinguishable from a confirmed one at
/// arm's length without reading anything.
class ProgressRow extends StatelessWidget {
  final LocalUpload row;
  final VoidCallback onRetry;

  /// Only wired to a visible control when [row] is CONFIRMED -- the unlock
  /// condition is a proven hash on the Pi, not the Pi's own VERIFIED stage.
  final VoidCallback onDelete;

  /// Local-only "remove from list" -- long-press. Doesn't touch the phone
  /// file, the Pi, or the row.
  final VoidCallback onHide;

  /// Prefix shared by every filename on screen, dimmed so the distinguishing
  /// part of each name lands in the same column. See [FilenameText].
  final String sharedPrefix;

  const ProgressRow({
    super.key,
    required this.row,
    required this.onRetry,
    required this.onDelete,
    required this.onHide,
    this.sharedPrefix = '',
  });

  @override
  Widget build(BuildContext context) {
    final ns = context.ns;
    final style = StateStyle.of(context, row);
    final canRetry = row.state == LocalUploadState.failed ||
        row.state == LocalUploadState.hashMismatch;
    final isConfirmed = row.state == LocalUploadState.confirmed;
    final showSecondLine =
        isConfirmed || canRetry || row.serverState != null;

    return InkWell(
      onLongPress: onHide,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: ns.rule)),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 3, color: style.color),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 10, 12, 11),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FilenameText(
                        filename: row.filename,
                        sharedPrefix: sharedPrefix,
                      ),
                      const SizedBox(height: 6),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            _size(row.sizeBytes),
                            style: NsType.data(context),
                          ),
                          const Spacer(),
                          Text(
                            style.label,
                            style: NsType.state(context, style.color),
                          ),
                        ],
                      ),
                      if (style.isWorking) ...[
                        const SizedBox(height: 6),
                        _Bar(row: row, color: style.color),
                      ],
                      if (showSecondLine) ...[
                        const SizedBox(height: 6),
                        _SecondLine(
                          row: row,
                          canRetry: canRetry,
                          isConfirmed: isConfirmed,
                          onRetry: onRetry,
                          onDelete: onDelete,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _size(int bytes) {
    if (bytes >= 1000 * 1000 * 1000) {
      return '${(bytes / 1e9).toStringAsFixed(2)} GB';
    }
    return '${(bytes / 1e6).toStringAsFixed(1)} MB';
  }
}

/// The Pi-side state and the row's action share a line. A confirmed file
/// still reading `PI: QUEUED` is the honest picture -- the transfer is done,
/// the archive isn't -- and collapsing that into a single tick would hide
/// the one distinction the whole system exists to make.
class _SecondLine extends StatelessWidget {
  final LocalUpload row;
  final bool canRetry;
  final bool isConfirmed;
  final VoidCallback onRetry;
  final VoidCallback onDelete;

  const _SecondLine({
    required this.row,
    required this.canRetry,
    required this.isConfirmed,
    required this.onRetry,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final ns = context.ns;

    Widget? left;
    if (canRetry && row.lastError != null) {
      left = Text(
        row.lastError!,
        style: NsType.data(context, color: ns.stateBad),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    } else if (row.serverState != null) {
      left = Text(
        'PI: ${row.serverState}',
        style: NsType.data(
          context,
          color: StateStyle.serverColor(context, row.serverState),
        ),
      );
    }

    return Row(
      children: [
        if (left != null) Flexible(child: left),
        const Spacer(),
        if (canRetry)
          _Action(label: 'RETRY', onTap: onRetry)
        else if (isConfirmed)
          _Action(label: 'DELETE', onTap: onDelete),
      ],
    );
  }
}

class _Action extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _Action({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          label,
          style: NsType.state(context, context.ns.accent),
        ),
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  final LocalUpload row;
  final Color color;
  const _Bar({required this.row, required this.color});

  @override
  Widget build(BuildContext context) {
    final ns = context.ns;
    final determinate = row.state == LocalUploadState.uploading &&
        row.sizeBytes > 0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: LinearProgressIndicator(
        value: determinate ? (row.bytesSent / row.sizeBytes).clamp(0.0, 1.0) : null,
        minHeight: 3,
        backgroundColor: ns.track,
        valueColor: AlwaysStoppedAnimation(color),
      ),
    );
  }
}
