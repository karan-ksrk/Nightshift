import 'package:flutter/material.dart';

import '../models/local_upload.dart';
import '../theme/app_theme.dart';

/// Aggregate figures for the rows currently on screen. Folded over what's
/// already in memory -- no query, no extra state to keep in sync.
@immutable
class BatchSummary {
  final int totalFiles;
  final int doneFiles;
  final int totalBytes;
  final int sentBytes;

  const BatchSummary({
    required this.totalFiles,
    required this.doneFiles,
    required this.totalBytes,
    required this.sentBytes,
  });

  static const _done = {
    LocalUploadState.confirmed,
    LocalUploadState.deletedLocal,
  };

  factory BatchSummary.from(Iterable<LocalUpload> rows) {
    var total = 0, done = 0, bytes = 0, sent = 0;
    for (final row in rows) {
      total++;
      bytes += row.sizeBytes;
      if (_done.contains(row.state)) {
        done++;
        // A finished file counts its whole size, not its last recorded
        // bytes_sent -- a row confirmed via /init's duplicate path never
        // transferred a byte, and would otherwise drag the total backwards.
        sent += row.sizeBytes;
      } else {
        sent += row.bytesSent;
      }
    }
    return BatchSummary(
      totalFiles: total,
      doneFiles: done,
      totalBytes: bytes,
      sentBytes: sent,
    );
  }

  bool get isComplete => totalFiles > 0 && doneFiles == totalFiles;
  double get fraction => totalBytes == 0 ? 0 : sentBytes / totalBytes;
}

/// The aggregate answer, above the detail: how far through this batch am I.
///
/// The bar carries one segment per file rather than a single continuous
/// track, because the unit of work here is a batch of files, not a
/// percentage -- seven solid, one filling, two empty is countable at a
/// glance without reading the figures above it.
class BatchHeader extends StatelessWidget {
  final BatchSummary summary;
  final List<LocalUpload> rows;

  const BatchHeader({super.key, required this.summary, required this.rows});

  static String formatBytes(int bytes) {
    if (bytes >= 1000 * 1000 * 1000) {
      return (bytes / 1e9).toStringAsFixed(2);
    }
    return (bytes / 1e6).toStringAsFixed(1);
  }

  static String unitFor(int bytes) =>
      bytes >= 1000 * 1000 * 1000 ? 'GB' : 'MB';

  @override
  Widget build(BuildContext context) {
    final ns = context.ns;
    final complete = summary.isComplete;
    final pct = (summary.fraction * 100).clamp(0, 100).toStringAsFixed(0);

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 13),
      decoration: BoxDecoration(
        color: ns.surface,
        border: Border(bottom: BorderSide(color: ns.rule)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                complete ? 'BATCH COMPLETE' : 'BATCH IN PROGRESS',
                style: NsType.label(context),
              ),
              Text(
                '$pct%',
                style: NsType.label(
                  context,
                  color: complete ? ns.stateGood : ns.faint,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _Figure(
                value: '${summary.doneFiles}',
                unit: '/${summary.totalFiles} FILES',
              ),
              _Figure(
                value: formatBytes(summary.sentBytes),
                unit: '/${formatBytes(summary.totalBytes)} '
                    '${unitFor(summary.totalBytes)}',
              ),
            ],
          ),
          const SizedBox(height: 10),
          _SegmentedBar(rows: rows),
        ],
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  final String value;
  final String unit;
  const _Figure({required this.value, required this.unit});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value, style: NsType.figure(context)),
        Text(
          unit,
          style: NsType.data(context, size: 11, color: context.ns.faint),
        ),
      ],
    );
  }
}

/// One segment per file, in list order, coloured by that file's own state.
class _SegmentedBar extends StatelessWidget {
  final List<LocalUpload> rows;
  const _SegmentedBar({required this.rows});

  @override
  Widget build(BuildContext context) {
    final ns = context.ns;
    if (rows.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: 5,
      child: Row(
        // stretch, not the default centre: these segments have no child, and
        // a childless DecoratedBox given loose vertical constraints collapses
        // to zero height -- the bar renders as nothing at all.
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(width: 2),
            Expanded(child: _segment(context, rows[i], ns)),
          ],
        ],
      ),
    );
  }

  Widget _segment(BuildContext context, LocalUpload row, NightshiftColors ns) {
    final radius = BorderRadius.circular(1);

    switch (row.state) {
      case LocalUploadState.confirmed:
        return DecoratedBox(
          decoration: BoxDecoration(color: ns.stateGood, borderRadius: radius),
        );
      case LocalUploadState.deletedLocal:
        return DecoratedBox(
          decoration: BoxDecoration(color: ns.stateGone, borderRadius: radius),
        );
      case LocalUploadState.failed:
      case LocalUploadState.hashMismatch:
        return DecoratedBox(
          decoration: BoxDecoration(color: ns.stateBad, borderRadius: radius),
        );
      case LocalUploadState.uploading:
        // Partially filled, so the in-flight file's own progress is visible
        // in the batch bar rather than only in its row.
        final f = row.sizeBytes > 0
            ? (row.bytesSent / row.sizeBytes).clamp(0.0, 1.0)
            : 0.0;
        return ClipRRect(
          borderRadius: radius,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: ns.track),
              // centerLeft, not the default centre -- progress fills from the
              // start of the segment, not outwards from its middle.
              FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: f == 0 ? 0.04 : f,
                child: ColoredBox(color: ns.stateWorking),
              ),
            ],
          ),
        );
      case LocalUploadState.hashing:
      case LocalUploadState.verifying:
        return DecoratedBox(
          decoration: BoxDecoration(
            color: ns.stateWorking.withValues(alpha: 0.35),
            borderRadius: radius,
          ),
        );
      case LocalUploadState.pending:
      case LocalUploadState.ready:
        return DecoratedBox(
          decoration: BoxDecoration(color: ns.track, borderRadius: radius),
        );
    }
  }
}
