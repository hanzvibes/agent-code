import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:code_harness/core/contrast.dart';
import 'package:code_harness/core/theme.dart';
import 'package:code_harness/core/ui.dart';
import 'package:code_harness/utils/syntax_highlighter.dart';

void main() {
  group('ContrastUtils', () {
    test('computes relative luminance of black and white', () {
      expect(
        ContrastUtils.relativeLuminance(Colors.black),
        closeTo(0.0, 0.001),
      );
      expect(
        ContrastUtils.relativeLuminance(Colors.white),
        closeTo(1.0, 0.001),
      );
    });

    test(
      'computes contrast ratio between pure black and pure white as 21:1',
      () {
        final ratio = ContrastUtils.contrastRatio(Colors.black, Colors.white);
        expect(ratio, closeTo(21.0, 0.1));
      },
    );

    test('identical colors have contrast ratio of 1:1', () {
      final ratio = ContrastUtils.contrastRatio(Colors.red, Colors.red);
      expect(ratio, closeTo(1.0, 0.01));
    });
  });

  group('SyntaxPalette contrast compliance (>= 4.5:1)', () {
    const bgLight = Colors.white;
    const bgDark = Colors.black;

    test('all Light syntax palette tokens meet at least 4.5:1 on white', () {
      const palette = SyntaxPalette.light;
      final tokens = {
        'keyword': palette.keyword,
        'string': palette.string,
        'comment': palette.comment,
        'number': palette.number,
        'identifier': palette.identifier,
        'plain': palette.plain,
      };

      for (final entry in tokens.entries) {
        final ratio = ContrastUtils.contrastRatio(entry.value, bgLight);
        expect(
          ratio >= 4.5,
          isTrue,
          reason:
              'Light syntax token "${entry.key}" (${entry.value}) has ratio $ratio < 4.5:1 against white',
        );
      }
    });

    test('all Dark syntax palette tokens meet at least 4.5:1 on black', () {
      const palette = SyntaxPalette.dark;
      final tokens = {
        'keyword': palette.keyword,
        'string': palette.string,
        'comment': palette.comment,
        'number': palette.number,
        'identifier': palette.identifier,
        'plain': palette.plain,
      };

      for (final entry in tokens.entries) {
        final ratio = ContrastUtils.contrastRatio(entry.value, bgDark);
        expect(
          ratio >= 4.5,
          isTrue,
          reason:
              'Dark syntax token "${entry.key}" (${entry.value}) has ratio $ratio < 4.5:1 against black',
        );
      }
    });
  });

  group('AppTokens contrast compliance', () {
    testWidgets('Light theme design tokens meet contrast requirements', (
      tester,
    ) async {
      late AppTokens tokens;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(isDark: false),
          home: Builder(
            builder: (ctx) {
              tokens = AppTokens.of(ctx);
              return const SizedBox();
            },
          ),
        ),
      );

      // Normal text on background >= 4.5:1
      expect(
        ContrastUtils.contrastRatio(tokens.text, tokens.bg) >= 4.5,
        isTrue,
        reason: 'Text on bg should be >= 4.5:1',
      );
      expect(
        ContrastUtils.contrastRatio(tokens.muted, tokens.bg) >= 4.5,
        isTrue,
        reason: 'Muted on bg should be >= 4.5:1',
      );
      expect(
        ContrastUtils.contrastRatio(tokens.text, tokens.surface) >= 4.5,
        isTrue,
        reason: 'Text on surface should be >= 4.5:1',
      );
      expect(
        ContrastUtils.contrastRatio(tokens.muted, tokens.surfacePressed) >= 4.5,
        isTrue,
        reason: 'Disabled text on surface should be >= 4.5:1',
      );
      expect(
        ContrastUtils.contrastRatio(tokens.accent, tokens.surface) >= 4.5,
        isTrue,
        reason: 'Accent text on surface should be >= 4.5:1',
      );

      // Status labels on bg >= 4.5:1
      expect(
        ContrastUtils.contrastRatio(tokens.green, tokens.bg) >= 4.5,
        isTrue,
        reason: 'Green on bg should be >= 4.5:1',
      );
      expect(
        ContrastUtils.contrastRatio(tokens.orange, tokens.bg) >= 4.5,
        isTrue,
        reason: 'Orange on bg should be >= 4.5:1',
      );
      expect(
        ContrastUtils.contrastRatio(tokens.red, tokens.bg) >= 4.5,
        isTrue,
        reason: 'Red on bg should be >= 4.5:1',
      );

      // Text on primary button >= 4.5:1
      expect(
        ContrastUtils.contrastRatio(tokens.onPrimary, tokens.primaryFill) >=
            4.5,
        isTrue,
        reason: 'On-primary text on primary button fill should be >= 4.5:1',
      );

      // Control outlines / sheet grab handles >= 3:1
      expect(
        ContrastUtils.contrastRatio(tokens.sheetHandle, tokens.sheetBg) >= 3.0,
        isTrue,
        reason: 'Sheet handle on sheet background should be >= 3.0:1',
      );
      expect(
        ContrastUtils.contrastRatio(tokens.controlOutline, tokens.bg) >= 3.0,
        isTrue,
        reason: 'Control outline on bg should be >= 3.0:1',
      );
      expect(
        ContrastUtils.contrastRatio(tokens.controlOutline, tokens.surface) >=
            3.0,
        isTrue,
        reason: 'Control outline on surface should be >= 3.0:1',
      );

      final theme = buildTheme(isDark: false);
      final disabledStates = {WidgetState.disabled};
      final disabledText = theme.textButtonTheme.style!.foregroundColor!
          .resolve(disabledStates)!;
      final disabledFill = theme.filledButtonTheme.style!.backgroundColor!
          .resolve(disabledStates)!;
      final disabledFilledText = theme.filledButtonTheme.style!.foregroundColor!
          .resolve(disabledStates)!;
      expect(
        ContrastUtils.contrastRatio(disabledText, tokens.surfacePressed) >= 4.5,
        isTrue,
        reason: 'Disabled text button label should be >= 4.5:1',
      );
      expect(
        ContrastUtils.contrastRatio(disabledFilledText, disabledFill) >= 4.5,
        isTrue,
        reason: 'Disabled filled button label should be >= 4.5:1',
      );
    });

    testWidgets('Dark theme design tokens meet contrast requirements', (
      tester,
    ) async {
      late AppTokens tokens;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(isDark: true),
          home: Builder(
            builder: (ctx) {
              tokens = AppTokens.of(ctx);
              return const SizedBox();
            },
          ),
        ),
      );

      // Normal text on background >= 4.5:1
      expect(
        ContrastUtils.contrastRatio(tokens.text, tokens.bg) >= 4.5,
        isTrue,
        reason: 'Dark text on bg should be >= 4.5:1',
      );
      expect(
        ContrastUtils.contrastRatio(tokens.muted, tokens.bg) >= 4.5,
        isTrue,
        reason: 'Dark muted on bg should be >= 4.5:1',
      );
      expect(
        ContrastUtils.contrastRatio(tokens.text, tokens.surface) >= 4.5,
        isTrue,
        reason: 'Dark text on surface should be >= 4.5:1',
      );
      expect(
        ContrastUtils.contrastRatio(tokens.muted, tokens.surfacePressed) >= 4.5,
        isTrue,
        reason: 'Dark disabled text on surface should be >= 4.5:1',
      );
      expect(
        ContrastUtils.contrastRatio(tokens.accent, tokens.surface) >= 4.5,
        isTrue,
        reason: 'Dark accent text on surface should be >= 4.5:1',
      );

      // Status labels on bg >= 4.5:1
      expect(
        ContrastUtils.contrastRatio(tokens.green, tokens.bg) >= 4.5,
        isTrue,
        reason: 'Dark green on bg should be >= 4.5:1',
      );
      expect(
        ContrastUtils.contrastRatio(tokens.orange, tokens.bg) >= 4.5,
        isTrue,
        reason: 'Dark orange on bg should be >= 4.5:1',
      );
      expect(
        ContrastUtils.contrastRatio(tokens.red, tokens.bg) >= 4.5,
        isTrue,
        reason: 'Dark red on bg should be >= 4.5:1',
      );

      // Text on primary button >= 4.5:1
      expect(
        ContrastUtils.contrastRatio(tokens.onPrimary, tokens.primaryFill) >=
            4.5,
        isTrue,
        reason:
            'Dark on-primary text on primary button fill should be >= 4.5:1',
      );

      // Control outlines / sheet grab handles >= 3:1
      expect(
        ContrastUtils.contrastRatio(tokens.sheetHandle, tokens.sheetBg) >= 3.0,
        isTrue,
        reason: 'Dark sheet handle on sheet background should be >= 3.0:1',
      );
      expect(
        ContrastUtils.contrastRatio(tokens.controlOutline, tokens.bg) >= 3.0,
        isTrue,
        reason: 'Dark control outline on bg should be >= 3.0:1',
      );
      expect(
        ContrastUtils.contrastRatio(tokens.controlOutline, tokens.surface) >=
            3.0,
        isTrue,
        reason: 'Dark control outline on surface should be >= 3.0:1',
      );

      final theme = buildTheme(isDark: true);
      final disabledStates = {WidgetState.disabled};
      final disabledText = theme.textButtonTheme.style!.foregroundColor!
          .resolve(disabledStates)!;
      final disabledFill = theme.filledButtonTheme.style!.backgroundColor!
          .resolve(disabledStates)!;
      final disabledFilledText = theme.filledButtonTheme.style!.foregroundColor!
          .resolve(disabledStates)!;
      expect(
        ContrastUtils.contrastRatio(disabledText, tokens.surfacePressed) >= 4.5,
        isTrue,
        reason: 'Dark disabled text button label should be >= 4.5:1',
      );
      expect(
        ContrastUtils.contrastRatio(disabledFilledText, disabledFill) >= 4.5,
        isTrue,
        reason: 'Dark disabled filled button label should be >= 4.5:1',
      );
    });
  });

  group('Custom button contrast', () {
    for (final isDark in [false, true]) {
      testWidgets(
        '${isDark ? 'Dark' : 'Light'} disabled and destructive buttons remain readable',
        (tester) async {
          late AppTokens tokens;
          late TonalButton destructive;
          await tester.pumpWidget(
            MaterialApp(
              theme: buildTheme(isDark: isDark),
              home: Builder(
                builder: (ctx) {
                  tokens = AppTokens.of(ctx);
                  destructive = TonalButton.destructive(
                    ctx,
                    label: 'Discard',
                    onTap: () {},
                  );
                  return Scaffold(
                    body: Column(
                      children: [
                        const SizedBox(height: 8),
                        const PrimaryButton(
                          label: 'Disabled primary',
                          onPressed: null,
                        ),
                        const PillButton(
                          label: 'Disabled pill',
                          onPressed: null,
                        ),
                        destructive,
                      ],
                    ),
                  );
                },
              ),
            ),
          );

          final primaryLabel = tester.widget<Text>(
            find.text('Disabled primary'),
          );
          final pillLabel = tester.widget<Text>(find.text('Disabled pill'));
          expect(
            ContrastUtils.contrastRatio(
                  primaryLabel.style!.color!,
                  tokens.surfacePressed,
                ) >=
                4.5,
            isTrue,
          );
          expect(
            ContrastUtils.contrastRatio(
                  pillLabel.style!.color!,
                  tokens.surfacePressed,
                ) >=
                4.5,
            isTrue,
          );
          expect(
            ContrastUtils.contrastRatio(destructive.color, destructive.fill) >=
                4.5,
            isTrue,
          );
        },
      );
    }
  });
}
