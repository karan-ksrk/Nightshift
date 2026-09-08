import 'package:flutter/material.dart';

/// The app's own colour tokens, hung off ThemeData so widgets read them via
/// `Theme.of(context).extension<NightshiftColors>()!` instead of importing
/// literal colours. Two rules hold this together:
///
///  - [accent] is for things you can press. It never describes a file.
///  - The `state*` colours only ever describe what a file is doing. They are
///    deliberately not derived from the accent, so an amber "working" row
///    can't be mistaken for a button.
@immutable
class NightshiftColors extends ThemeExtension<NightshiftColors> {
  final Color ground;
  final Color surface;
  final Color raised;
  final Color rule;
  final Color ink;
  final Color soft;
  final Color faint;
  final Color accent;
  final Color track;

  final Color stateIdle;
  final Color stateWorking;
  final Color stateGood;
  final Color stateBad;
  final Color stateGone;

  const NightshiftColors({
    required this.ground,
    required this.surface,
    required this.raised,
    required this.rule,
    required this.ink,
    required this.soft,
    required this.faint,
    required this.accent,
    required this.track,
    required this.stateIdle,
    required this.stateWorking,
    required this.stateGood,
    required this.stateBad,
    required this.stateGone,
  });

  static const dark = NightshiftColors(
    ground: Color(0xFF0D1017),
    surface: Color(0xFF141A24),
    raised: Color(0xFF1B2230),
    rule: Color(0xFF242D3D),
    ink: Color(0xFFE4E9F2),
    soft: Color(0xFF96A1B5),
    faint: Color(0xFF5E697C),
    accent: Color(0xFF7B8CE8),
    track: Color(0xFF202838),
    stateIdle: Color(0xFF66718A),
    stateWorking: Color(0xFFE0A24E),
    stateGood: Color(0xFF46C79A),
    stateBad: Color(0xFFE8685D),
    stateGone: Color(0xFF4C5668),
  );

  static const light = NightshiftColors(
    ground: Color(0xFFF1F3F8),
    surface: Color(0xFFFFFFFF),
    raised: Color(0xFFFFFFFF),
    rule: Color(0xFFDCE1EC),
    ink: Color(0xFF121620),
    soft: Color(0xFF525C70),
    faint: Color(0xFF7C8598),
    accent: Color(0xFF3D4FB0),
    track: Color(0xFFE2E6F0),
    stateIdle: Color(0xFF737E93),
    stateWorking: Color(0xFFA96C0C),
    stateGood: Color(0xFF157F62),
    stateBad: Color(0xFFBF473B),
    stateGone: Color(0xFF909AAC),
  );

  @override
  NightshiftColors copyWith({
    Color? ground,
    Color? surface,
    Color? raised,
    Color? rule,
    Color? ink,
    Color? soft,
    Color? faint,
    Color? accent,
    Color? track,
    Color? stateIdle,
    Color? stateWorking,
    Color? stateGood,
    Color? stateBad,
    Color? stateGone,
  }) {
    return NightshiftColors(
      ground: ground ?? this.ground,
      surface: surface ?? this.surface,
      raised: raised ?? this.raised,
      rule: rule ?? this.rule,
      ink: ink ?? this.ink,
      soft: soft ?? this.soft,
      faint: faint ?? this.faint,
      accent: accent ?? this.accent,
      track: track ?? this.track,
      stateIdle: stateIdle ?? this.stateIdle,
      stateWorking: stateWorking ?? this.stateWorking,
      stateGood: stateGood ?? this.stateGood,
      stateBad: stateBad ?? this.stateBad,
      stateGone: stateGone ?? this.stateGone,
    );
  }

  @override
  NightshiftColors lerp(ThemeExtension<NightshiftColors>? other, double t) {
    if (other is! NightshiftColors) return this;
    return NightshiftColors(
      ground: Color.lerp(ground, other.ground, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      raised: Color.lerp(raised, other.raised, t)!,
      rule: Color.lerp(rule, other.rule, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      soft: Color.lerp(soft, other.soft, t)!,
      faint: Color.lerp(faint, other.faint, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      track: Color.lerp(track, other.track, t)!,
      stateIdle: Color.lerp(stateIdle, other.stateIdle, t)!,
      stateWorking: Color.lerp(stateWorking, other.stateWorking, t)!,
      stateGood: Color.lerp(stateGood, other.stateGood, t)!,
      stateBad: Color.lerp(stateBad, other.stateBad, t)!,
      stateGone: Color.lerp(stateGone, other.stateGone, t)!,
    );
  }
}

/// Shorthand: `context.ns.stateGood`.
///
/// Falls back to the palette matching the ambient brightness when the
/// extension is absent, rather than asserting. A widget that can't find its
/// theme should render in the wrong shade, not crash the screen -- and this
/// keeps any subtree built under a plain `MaterialApp` (a test harness, a
/// route pushed with its own theme) working.
extension NightshiftTheme on BuildContext {
  NightshiftColors get ns {
    final theme = Theme.of(this);
    return theme.extension<NightshiftColors>() ??
        (theme.brightness == Brightness.dark
            ? NightshiftColors.dark
            : NightshiftColors.light);
  }
}

/// Type roles. `mono` is the workhorse -- every number, state label and
/// filename uses it, which is what lets values line up column-wise down a
/// list. Prose falls back to the platform font.
abstract final class NsType {
  static const mono = 'PlexMono';

  /// Small uppercase key, letterspaced. Section headers, field labels.
  static TextStyle label(BuildContext context, {Color? color}) => TextStyle(
        fontFamily: mono,
        fontSize: 9.5,
        fontWeight: FontWeight.w500,
        letterSpacing: 1.3,
        height: 1.3,
        color: color ?? context.ns.faint,
      );

  /// State words: UPLOADING, CONFIRMED. Reads as the machine's own vocabulary.
  static TextStyle state(BuildContext context, Color color) => TextStyle(
        fontFamily: mono,
        fontSize: 10,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.0,
        color: color,
      );

  /// Byte counts, percentages, anything that should align vertically.
  static TextStyle data(BuildContext context, {Color? color, double size = 10}) =>
      TextStyle(
        fontFamily: mono,
        fontSize: size,
        letterSpacing: 0.5,
        fontFeatures: const [FontFeature.tabularFigures()],
        color: color ?? context.ns.soft,
      );

  /// The big readouts: batch counts, days-to-drain.
  static TextStyle figure(BuildContext context, {double size = 21, Color? color}) =>
      TextStyle(
        fontFamily: mono,
        fontSize: size,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
        height: 1.1,
        fontFeatures: const [FontFeature.tabularFigures()],
        color: color ?? context.ns.ink,
      );
}

abstract final class AppTheme {
  static ThemeData _build(NightshiftColors ns, Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: ns.accent,
      brightness: brightness,
    ).copyWith(
      surface: ns.ground,
      primary: ns.accent,
      error: ns.stateBad,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: ns.ground,
      extensions: [ns],
      dividerTheme: DividerThemeData(color: ns.rule, thickness: 1, space: 1),
      appBarTheme: AppBarTheme(
        backgroundColor: ns.surface,
        surfaceTintColor: Colors.transparent,
        foregroundColor: ns.ink,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: NsType.mono,
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: 2.2,
          color: ns.ink,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: ns.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: Colors.transparent,
        height: 58,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontFamily: NsType.mono,
            fontSize: 9.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
            color: selected ? ns.accent : ns.faint,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(size: 19, color: selected ? ns.accent : ns.faint);
        }),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: ns.raised,
        contentTextStyle: TextStyle(color: ns.ink, fontSize: 13),
        actionTextColor: ns.accent,
        behavior: SnackBarBehavior.floating,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: ns.raised,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: ns.accent,
          foregroundColor: ns.ground,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
          textStyle: const TextStyle(
            fontFamily: NsType.mono,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.1,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ns.soft,
          side: BorderSide(color: ns.rule),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
          textStyle: const TextStyle(
            fontFamily: NsType.mono,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.1,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: ns.soft,
          textStyle: const TextStyle(
            fontFamily: NsType.mono,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.1,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: ns.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(3),
          borderSide: BorderSide(color: ns.rule),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(3),
          borderSide: BorderSide(color: ns.rule),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(3),
          borderSide: BorderSide(color: ns.accent, width: 1.5),
        ),
        labelStyle: TextStyle(
          fontFamily: NsType.mono,
          fontSize: 11,
          letterSpacing: 1.2,
          color: ns.faint,
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        linearTrackColor: ns.track,
        color: ns.stateWorking,
        linearMinHeight: 3,
      ),
    );
  }

  static ThemeData get dark => _build(NightshiftColors.dark, Brightness.dark);
  static ThemeData get light => _build(NightshiftColors.light, Brightness.light);
}
