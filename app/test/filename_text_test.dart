// The filename dimming rule. This is pure logic behind a visual effect --
// if it silently returns '' the UI still renders, just without the treatment
// that makes a list of near-identical names scannable. That failure mode is
// invisible in a screenshot, which is exactly why it gets tests: the first
// on-device build shipped with the whole feature inert and looked fine.

import 'package:flutter_test/flutter_test.dart';

import 'package:nightshift_app/widgets/filename_text.dart';

void main() {
  group('sharedPrefixes', () {
    test('real DJI exports share their stem, cut at the field boundary', () {
      final names = [
        'dji_mimo_20251215_084218_0_1765814413242_video.mp4',
        'dji_mimo_20251215_091428_0_1765814449054_video.mp4',
        'dji_mimo_20251215_112332_0_1765814495390_video.mp4',
      ];

      final prefixes = FilenameText.sharedPrefixes(names);

      // Every row must get the SAME prefix length, or the emphasised
      // timestamps stop lining up in a column. The raw pairwise answer
      // doesn't give that -- 084218 and 091428 share a leading '0' that
      // 112332 doesn't -- so the prefix is snapped back to the last
      // separator.
      for (final name in names) {
        expect(prefixes[name], 'dji_mimo_20251215_',
            reason: 'the timestamp is where these names start differing');
      }
    });

    test('one odd name out does not switch the treatment off for the rest',
        () {
      // The regression that shipped: longestCommonPrefix across ALL rows
      // collapsed to '' the moment a single unrelated filename appeared, so
      // the DJI files stopped being dimmed too. Pairwise, they still are.
      final names = [
        'dji_mimo_20251215_084218_0_1765814413242_video.mp4',
        'dji_mimo_20251215_091428_0_1765814449054_video.mp4',
        '2026-09-05-10-29-14-660.mp4',
      ];

      final prefixes = FilenameText.sharedPrefixes(names);

      expect(prefixes[names[0]], 'dji_mimo_20251215_');
      expect(prefixes[names[1]], 'dji_mimo_20251215_');
      expect(prefixes['2026-09-05-10-29-14-660.mp4'], '',
          reason: 'shares nothing, so nothing is dimmed');
    });

    test('two unrelated names dim nothing', () {
      final prefixes = FilenameText.sharedPrefixes(['alpha.mp4', 'beta.mp4']);
      expect(prefixes['alpha.mp4'], '');
      expect(prefixes['beta.mp4'], '');
    });

    test('a single name is never dimmed', () {
      final prefixes = FilenameText.sharedPrefixes(['only_one_file.mp4']);
      expect(prefixes['only_one_file.mp4'], '');
    });

    test('identical names do not dim each other away entirely', () {
      // Two rows can legitimately carry the same filename from different
      // folders. Dimming the whole string would leave nothing readable.
      final prefixes = FilenameText.sharedPrefixes(['same.mp4', 'same.mp4']);
      expect(prefixes['same.mp4'], '');
    });

    test('empty input is handled', () {
      expect(FilenameText.sharedPrefixes(const []), isEmpty);
    });
  });

  group('longestCommonPrefix', () {
    test('returns the prefix every name shares', () {
      expect(
        FilenameText.longestCommonPrefix(['abc_1.mp4', 'abc_2.mp4']),
        'abc_',
      );
    });

    test('returns empty when one name breaks the run', () {
      expect(
        FilenameText.longestCommonPrefix(['abc_1.mp4', 'abc_2.mp4', 'zzz.mp4']),
        '',
      );
    });

    test('returns empty for fewer than two names', () {
      expect(FilenameText.longestCommonPrefix(['solo.mp4']), '');
      expect(FilenameText.longestCommonPrefix(const []), '');
    });
  });
}
