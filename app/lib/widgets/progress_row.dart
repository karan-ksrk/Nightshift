import 'package:flutter/material.dart';

import '../models/local_upload.dart';

class ProgressRow extends StatelessWidget {
  final LocalUpload row;
  final VoidCallback onRetry;

  /// Only ever invoked when [row.state] is CONFIRMED -- the delete button
  /// isn't shown otherwise. See the plan: unlock condition is CONFIRMED
  /// (either /complete or an /init 409 duplicate), not the Pi's own
  /// VERIFIED (YouTube-processing) stage.
  final VoidCallback onDelete;

  const ProgressRow({
    super.key,
    required this.row,
    required this.onRetry,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final canRetry = row.state == LocalUploadState.failed ||
        row.state == LocalUploadState.hashMismatch;
    final sizeMb = (row.sizeBytes / 1e6).toStringAsFixed(1);

    return ListTile(
      title: Text(row.filename, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$sizeMb MB — ${_label(row.state)}'),
          if (row.state == LocalUploadState.uploading)
            LinearProgressIndicator(
              value: row.sizeBytes > 0 ? row.bytesSent / row.sizeBytes : 0,
            )
          else if (row.state == LocalUploadState.hashing ||
              row.state == LocalUploadState.verifying)
            const LinearProgressIndicator(), // indeterminate
          if (canRetry && row.lastError != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                row.lastError!,
                style: const TextStyle(color: Colors.red, fontSize: 12),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
      trailing: canRetry
          ? IconButton(icon: const Icon(Icons.refresh), onPressed: onRetry)
          : row.isConfirmed
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.check_circle, color: Colors.green),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Delete from phone',
                      onPressed: onDelete,
                    ),
                  ],
                )
              : row.state == LocalUploadState.deletedLocal
                  ? const Icon(Icons.delete_forever, color: Colors.grey)
                  : null,
    );
  }

  String _label(LocalUploadState s) => switch (s) {
        LocalUploadState.pending => 'Pending',
        LocalUploadState.hashing => 'Hashing…',
        LocalUploadState.ready => 'Ready',
        LocalUploadState.uploading => 'Uploading',
        LocalUploadState.verifying => 'Verifying',
        LocalUploadState.hashMismatch => 'Hash mismatch, retrying',
        LocalUploadState.confirmed => 'Confirmed',
        LocalUploadState.failed => 'Failed',
        LocalUploadState.deletedLocal => 'Deleted from phone',
      };
}
