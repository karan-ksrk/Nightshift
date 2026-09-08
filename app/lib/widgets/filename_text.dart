import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Renders a filename so a list of near-identical ones stays scannable.
///
/// The problem, with real data: ten picked files named
/// `dji_mimo_20251215_084218_0_1765814413242_video.mp4`,
/// `dji_mimo_20251215_091428_0_1765814449054_video.mp4`, ... are identical
/// for their first eighteen characters and again for their last ten. Plain
/// text with an ellipsis renders ten rows that look the same.
///
/// So: dim whatever prefix every visible filename shares, show the run that
/// follows it at full weight, and dim the rest. In a monospace face the
/// shared prefix is the same width on every row, which puts each file's
/// distinguishing run at the same x-position down the whole list -- you scan
/// vertically instead of reading each line.
///
/// The shared prefix is computed from the actual list on screen
/// ([longestCommonPrefix]) rather than pattern-matched against DJI's naming,
/// so it adapts to whatever gets picked -- screen recordings, camera exports,
/// anything. When files share nothing, nothing is dimmed and this degrades to
/// ordinary text.
class FilenameText extends StatelessWidget {
  final String filename;

  /// Prefix shared across every filename currently listed. Empty disables
  /// the treatment.
  final String sharedPrefix;

  final double fontSize;

  const FilenameText({
    super.key,
    required this.filename,
    this.sharedPrefix = '',
    this.fontSize = 11.5,
  });

  /// Longest prefix common to every entry. Returns '' for fewer than two
  /// entries -- one file shares nothing with anything, and dimming all of it
  /// would just make the only row unreadable.
  static String longestCommonPrefix(Iterable<String> names) {
    final list = names.toList();
    if (list.length < 2) return '';
    var prefix = list.first;
    for (final name in list.skip(1)) {
      prefix = prefix.substring(0, _commonLength(prefix, name));
      if (prefix.isEmpty) return '';
    }
    return prefix;
  }

  /// Per-name dimmable prefix: the longest prefix each name shares with *any
  /// other* name in the list, rather than one prefix common to all of them.
  ///
  /// A prefix shared by every row is the wrong rule for a real list. Picking
  /// nine DJI exports plus one screen recording collapses the common prefix
  /// to nothing, and the treatment silently switches itself off in exactly
  /// the case it exists for. Pairwise, the nine still dim their shared
  /// `dji_mimo_20251215_` and the odd one out simply doesn't participate.
  ///
  /// O(n²) over the visible rows -- tens of items, a few hundred character
  /// comparisons, cheaper than the layout pass that follows it.
  static Map<String, String> sharedPrefixes(Iterable<String> names) {
    final list = names.toList();
    final result = <String, String>{};
    if (list.length < 2) {
      for (final name in list) {
        result[name] = '';
      }
      return result;
    }

    for (var i = 0; i < list.length; i++) {
      var best = 0;
      for (var j = 0; j < list.length; j++) {
        if (i == j) continue;
        final n = _commonLength(list[i], list[j]);
        // An exact duplicate name would otherwise dim the whole string.
        if (n == list[i].length && n == list[j].length) continue;
        if (n > best) best = n;
      }
      result[list[i]] = _trimToSeparator(list[i].substring(0, best));
    }
    return result;
  }

  /// Pulls a prefix back to the last field separator inside it.
  ///
  /// Without this the shared run ends wherever two strings happen to diverge,
  /// which lands mid-field and — worse — at a *different* length per row:
  /// `..._084218` and `..._091428` share 19 characters (both timestamps start
  /// `0`), while `..._112332` shares only 18. Three rows would then emphasise
  /// their distinguishing digits at three different x-positions, destroying
  /// the column alignment this whole treatment exists to create. Snapping to
  /// a separator makes the boundary the same for every row in the group.
  static String _trimToSeparator(String prefix) {
    for (var i = prefix.length - 1; i >= 0; i--) {
      if ('_-. '.contains(prefix[i])) return prefix.substring(0, i + 1);
    }
    return prefix;
  }

  static int _commonLength(String a, String b) {
    var i = 0;
    final max = a.length < b.length ? a.length : b.length;
    while (i < max && a.codeUnitAt(i) == b.codeUnitAt(i)) {
      i++;
    }
    return i;
  }

  @override
  Widget build(BuildContext context) {
    final ns = context.ns;
    final base = TextStyle(
      fontFamily: NsType.mono,
      fontSize: fontSize,
      letterSpacing: -0.2,
      height: 1.25,
      color: ns.faint,
    );
    final emphasis = base.copyWith(
      color: ns.ink,
      fontWeight: FontWeight.w600,
    );

    // Only worth dimming if the shared run is substantial and still leaves
    // something distinguishing behind.
    final usePrefix = sharedPrefix.length >= 4 &&
        filename.startsWith(sharedPrefix) &&
        filename.length - sharedPrefix.length >= 3;

    if (!usePrefix) {
      return Text(
        filename,
        style: emphasis,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }

    final rest = filename.substring(sharedPrefix.length);
    // The distinguishing run ends at the next separator -- for these names
    // that isolates the timestamp, which is the part actually worth reading.
    var cut = rest.indexOf(RegExp(r'[_.\- ]'));
    if (cut <= 0) cut = rest.length;

    return RichText(
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: base,
        children: [
          TextSpan(text: sharedPrefix),
          TextSpan(text: rest.substring(0, cut), style: emphasis),
          if (cut < rest.length) TextSpan(text: rest.substring(cut)),
        ],
      ),
    );
  }
}
