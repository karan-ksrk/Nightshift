import 'package:flutter/material.dart';

import '../models/local_upload.dart';

class ProgressRow extends StatelessWidget {
  final LocalUpload row;
  final VoidCallback onRetry;

  const ProgressRow({super.key, required this.row, required this.onRetry});

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
              ? const Icon(Icons.check_circle, color: Colors.green)
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
