import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Utilities for calculating WCAG 2.1 relative luminance and contrast ratios.
class ContrastUtils {
  ContrastUtils._();

  /// Calculates the relative luminance of a color according to WCAG 2.1 specifications.
  /// Returns a value between 0.0 (darkest black) and 1.0 (lightest white).
  static double relativeLuminance(Color color) {
    double transform(double channel) {
      if (channel <= 0.04045) {
        return channel / 12.92;
      }
      return math.pow((channel + 0.055) / 1.055, 2.4).toDouble();
    }

    // Use floating-point RGB components in [0.0, 1.0].
    final r = transform(color.r);
    final g = transform(color.g);
    final b = transform(color.b);

    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  }

  /// Calculates the contrast ratio between two colors according to WCAG 2.1 specifications.
  /// Contrast ratio formula: (L1 + 0.05) / (L2 + 0.05), where L1 is the lighter luminance.
  /// Returns a value between 1.0 and 21.0.
  static double contrastRatio(Color foreground, Color background) {
    final l1 = relativeLuminance(foreground);
    final l2 = relativeLuminance(background);

    final lighter = math.max(l1, l2);
    final darker = math.min(l1, l2);

    return (lighter + 0.05) / (darker + 0.05);
  }

  /// Returns true if the contrast ratio between [foreground] and [background]
  /// is at least 4.5:1 (WCAG AA requirement for normal text).
  static bool meetsNormalTextContrast(Color foreground, Color background) {
    return contrastRatio(foreground, background) >= 4.5;
  }

  /// Returns true if the contrast ratio between [foreground] and [background]
  /// is at least 3.0:1 (WCAG AA requirement for large text and UI components / icons).
  static bool meetsLargeTextOrIconContrast(Color foreground, Color background) {
    return contrastRatio(foreground, background) >= 3.0;
  }
}
