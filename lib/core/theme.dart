import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Code Harness theme builder.
/// Attribution: adapted from MIT-licensed design system (see THIRD_PARTY_NOTICES.md).
ThemeData buildTheme({required bool isDark}) {
  final base = isDark ? ThemeData.dark() : ThemeData.light();
  final bg = isDark ? Colors.black : Colors.white;
  final surface = isDark ? const Color(0xFF141416) : const Color(0xFFF5F5F7);
  final accent = isDark ? const Color(0xFF60A5FA) : const Color(0xFF0052CC);
  final onSurface = isDark ? const Color(0xFFF9FAFB) : const Color(0xFF0F0F10);
  final muted = isDark ? const Color(0xFF9CA3AF) : const Color(0xFF52525B);
  final primaryFill = isDark
      ? const Color(0xFF2563EB)
      : const Color(0xFF0055D6);
  final onPrimary = isDark ? Colors.black : Colors.white;
  final disabledSurface = isDark
      ? const Color(0xFF1E1E21)
      : const Color(0xFFEBEBED);
  final controlOutline = isDark
      ? const Color(0xFF64748B)
      : const Color(0xFF6B7280);

  return base.copyWith(
    scaffoldBackgroundColor: bg,
    colorScheme: (isDark ? const ColorScheme.dark() : const ColorScheme.light())
        .copyWith(
          primary: accent,
          onPrimary: onPrimary,
          surface: bg,
          onSurface: onSurface,
        ),
    disabledColor: muted,
    appBarTheme: AppBarTheme(
      backgroundColor: bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      iconTheme: IconThemeData(color: onSurface),
      titleTextStyle: GoogleFonts.inter(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.6,
        color: onSurface,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: surface,
      indicatorColor: accent.withValues(alpha: 0.15),
      labelTextStyle: WidgetStateProperty.all(
        GoogleFonts.inter(fontSize: 11, letterSpacing: -0.1),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled) ? muted : accent,
        ),
        minimumSize: WidgetStateProperty.all(const Size(44, 44)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled) ? muted : accent,
        ),
        side: WidgetStateProperty.all(BorderSide(color: controlOutline)),
        minimumSize: WidgetStateProperty.all(const Size(44, 48)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.disabled) ? muted : Colors.white,
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? disabledSurface
              : primaryFill,
        ),
        minimumSize: WidgetStateProperty.all(const Size(44, 48)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        iconColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled) ? muted : onSurface,
        ),
        minimumSize: WidgetStateProperty.all(const Size(44, 44)),
      ),
    ),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.black.withValues(alpha: 0.08),
        ),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: isDark
          ? Colors.white.withValues(alpha: 0.07)
          : Colors.black.withValues(alpha: 0.06),
      thickness: 0.5,
      space: 0,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: controlOutline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: controlOutline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: accent, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    ),
    textTheme: GoogleFonts.interTextTheme(base.textTheme),
  );
}
