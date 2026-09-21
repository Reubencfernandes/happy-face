import 'package:flutter/material.dart';

/// Happy Drive is dark, always. Photos and the sunrise glow read better on
/// ink than on cream, and one look means one set of decisions.
///
/// The greys are neutral so nothing competes with the photos; the amber is
/// kept for things you can act on — a button, the selected tab, a link.
const ink = Color(0xFF0B0B0C);
const inkSurface = Color(0xFF17171A);

/// Sheets, dialogs and menus sit a step above the page but below a card.
const inkSheet = Color(0xFF131316);
const inkText = Color(0xFFF5F4F2);
const inkMuted = Color(0xFF9A9AA2);
const accent = Color(0xFFF2A33A);

/// The three lights in the welcome screen's sunrise, outside in.
const glowHaze = Color(0xFFF7E7CE);
const glowSun = Color(0xFFF2A33A);
const glowEmber = Color(0xFFE2662B);

/// General Sans, bundled from assets/fonts in regular (400) and semibold (600).
const appFontFamily = 'General Sans';

/// Built once: deriving a scheme from the seed is too much work to redo on
/// every frame, and there is only ever one of them.
final _theme = _build();

/// The app's only theme.
ThemeData buildTheme() => _theme;

/// The gallery's theme, which is simply the app's.
ThemeData buildGalleryTheme() => _theme;

ThemeData _build() {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: accent,
        brightness: Brightness.dark,
      ).copyWith(
        primary: accent,
        onPrimary: ink,
        primaryContainer: accent,
        onPrimaryContainer: ink,
        surface: ink,
        onSurface: inkText,
        onSurfaceVariant: inkMuted,
        // The whole neutral ramp, not just the top of it: Material picks
        // sheets, dialogs and menus out of these, and a seed-derived one
        // would come out warm brown next to the ink.
        surfaceDim: ink,
        surfaceBright: const Color(0xFF232328),
        surfaceContainerLowest: const Color(0xFF060607),
        surfaceContainerLow: const Color(0xFF0F0F11),
        surfaceContainer: inkSheet,
        surfaceContainerHigh: const Color(0xFF151519),
        surfaceContainerHighest: inkSurface,
        outline: const Color(0xFF3A3A42),
        outlineVariant: const Color(0xFF2A2A30),
      );
  return ThemeData(
    useMaterial3: true,
    fontFamily: appFontFamily,
    colorScheme: scheme,
    scaffoldBackgroundColor: ink,
    appBarTheme: AppBarTheme(
      backgroundColor: ink,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 22,
        // General Sans ships 400 and 600 here, so w600 is the real bold.
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
        letterSpacing: -0.3,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: inkSurface,
      hintStyle: const TextStyle(color: inkMuted),
      labelStyle: const TextStyle(color: inkMuted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: accent, width: 2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(54),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: accent),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: inkSheet,
      surfaceTintColor: Colors.transparent,
      dragHandleColor: inkMuted.withValues(alpha: 0.5),
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: inkSheet,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: inkSheet,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: inkMuted,
      textColor: inkText,
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    dividerTheme: const DividerThemeData(color: Color(0xFF2A2A30)),
  );
}
