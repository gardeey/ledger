import 'package:flutter/material.dart';

/// Brand accent: Robinhood-style green; negative uses coral.
const kGain = Color(0xFF00C805);
const kLoss = Color(0xFFFF5000);

/// Categorical palette for flows (validated for both themes: mid-lightness, distinct hues).
const kPalette = <Color>[
  Color(0xFF5B8DEF), Color(0xFFF2994A), Color(0xFF9B6BDF), Color(0xFF2EC4B6),
  Color(0xFFEB5E8B), Color(0xFFE0B341), Color(0xFF7FB069), Color(0xFF6C7A99),
];

ThemeData buildTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: kGain,
    brightness: b,
    surface: dark ? const Color(0xFF0B0D0E) : const Color(0xFFF6F7F8),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    cardTheme: CardThemeData(
      elevation: 0,
      color: dark ? const Color(0xFF15181A) : Colors.white,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: dark ? const Color(0xFF23282B) : const Color(0xFFE6E8EA)),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface, elevation: 0, scrolledUnderElevation: 0,
    ),
    textTheme: Typography.material2021().black.apply(fontFamily: null).copyWith().apply(
          bodyColor: scheme.onSurface, displayColor: scheme.onSurface),
  );
}
