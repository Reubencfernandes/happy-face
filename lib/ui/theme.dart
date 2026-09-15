import 'package:flutter/material.dart';

/// A warm, friendly palette: sunny amber on soft cream, deep ink text.
const _seed = Color(0xFFF2A33A);

ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
  final light = brightness == Brightness.light;
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: light
        ? const Color(0xFFFFFBF5)
        : const Color(0xFF16130F),
    appBarTheme: AppBarTheme(
      backgroundColor: light
          ? const Color(0xFFFFFBF5)
          : const Color(0xFF16130F),
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: scheme.onSurface,
        letterSpacing: -0.3,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(
        alpha: light ? 0.5 : 0.35,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(54),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: light
          ? const Color(0xFFFFF6EA)
          : const Color(0xFF211C16),
      indicatorColor: scheme.primaryContainer,
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
