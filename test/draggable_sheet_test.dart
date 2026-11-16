import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:code_harness/core/contrast.dart';
import 'package:code_harness/core/ui.dart';
import 'package:code_harness/controllers/review_controller.dart';
import 'package:code_harness/views/review/review_view.dart';

void main() {
  group('Draggable App Sheet & Dialog Replacement', () {
    testWidgets(
      'showAppSheet renders DraggableScrollableSheet with grab handle and accessible contrast',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.light(),
            home: Scaffold(
              body: Builder(
                builder: (ctx) => Center(
                  child: ElevatedButton(
                    onPressed: () {
                      showAppSheet<void>(
                        ctx,
                        title: 'Test Sheet Title',
                        subtitle: 'Test Sheet Subtitle',
                        builder: (sheetCtx, scrollController) => ListView(
                          controller: scrollController,
                          children: const [
                            Text('Sheet Item 1'),
                            Text('Sheet Item 2'),
                          ],
                        ),
                      );
                    },
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          ),
        );

        // Tap to open sheet
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();

        // Verify DraggableScrollableSheet exists
        expect(find.byType(DraggableScrollableSheet), findsOneWidget);

        // Verify title and subtitle
        expect(find.text('Test Sheet Title'), findsOneWidget);
        expect(find.text('Test Sheet Subtitle'), findsOneWidget);
        expect(find.text('Sheet Item 1'), findsOneWidget);

        // Verify grab handle exists
        final handleFinder = find.byWidgetPredicate((widget) {
          if (widget is Container && widget.decoration is BoxDecoration) {
            final box = widget.decoration as BoxDecoration;
            if (box.borderRadius != null &&
                widget.constraints?.maxWidth == 36) {
              return true;
            }
          }
          return false;
        });
        expect(handleFinder, findsWidgets);

        // Verify grab handle contrast >= 3:1 against sheet background
        final element = tester.element(find.byType(DraggableScrollableSheet));
        final tokens = AppTokens.of(element);
        expect(
          ContrastUtils.contrastRatio(tokens.sheetHandle, tokens.sheetBg) >=
              3.0,
          isTrue,
        );
      },
    );

    testWidgets(
      'confirmSheet opens draggable sheet and returns user confirmation',
      (tester) async {
        bool? confirmed;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.light(),
            home: Scaffold(
              body: Builder(
                builder: (ctx) => Center(
                  child: ElevatedButton(
                    onPressed: () async {
                      confirmed = await confirmSheet(
                        ctx,
                        title: 'Delete file?',
                        message: 'This cannot be undone.',
                        confirmLabel: 'Delete',
                        destructive: true,
                      );
                    },
                    child: const Text('Show Confirm'),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Show Confirm'));
        await tester.pumpAndSettle();

        expect(find.text('Delete file?'), findsOneWidget);
        expect(find.text('This cannot be undone.'), findsOneWidget);
        expect(find.text('Cancel'), findsOneWidget);
        expect(find.text('Delete'), findsOneWidget);

        // Tap confirm button
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();

        expect(confirmed, isTrue);
      },
    );

    testWidgets(
      'showUnsavedChangesSheet presents Save, Discard, Cancel actions',
      (tester) async {
        String? actionResult;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.light(),
            home: Scaffold(
              body: Builder(
                builder: (ctx) => Center(
                  child: ElevatedButton(
                    onPressed: () async {
                      actionResult = await showUnsavedChangesSheet(ctx);
                    },
                    child: const Text('Show Unsaved'),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Show Unsaved'));
        await tester.pumpAndSettle();

        expect(find.text('Unsaved changes'), findsOneWidget);
        expect(find.text('Save this file before continuing?'), findsOneWidget);
        expect(find.text('Save changes'), findsOneWidget);
        expect(find.text('Discard changes'), findsOneWidget);
        expect(find.text('Cancel'), findsOneWidget);

        // Tap Discard changes
        await tester.tap(find.text('Discard changes'));
        await tester.pumpAndSettle();

        expect(actionResult, 'discard');
      },
    );

    testWidgets('review error state renders without layout exceptions', (
      tester,
    ) async {
      final controller = ReviewController();
      controller.loadPatch('not a supported diff', const {});

      await tester.pumpWidget(
        GetMaterialApp(
          home: ReviewView(ctrl: controller, onApply: () {}, onDiscard: () {}),
        ),
      );

      expect(find.text('Could not apply patch'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
