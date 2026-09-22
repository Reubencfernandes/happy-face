import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:happy_drive/ui/skeleton.dart';
import 'package:happy_drive/ui/theme.dart';

Future<void> pump(WidgetTester tester, Widget child, {bool still = false}) =>
    tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: still),
          child: Scaffold(body: Center(child: child)),
        ),
      ),
    );

/// The gradient a skeleton is painted with on this frame, if it has one.
Gradient? gradientOf(WidgetTester tester) {
  final box = tester.widget<DecoratedBox>(
    find.descendant(
      of: find.byType(Skeleton),
      matching: find.byType(DecoratedBox),
    ),
  );
  return (box.decoration as BoxDecoration).gradient;
}

void main() {
  testWidgets('a block takes the size it is given', (tester) async {
    await pump(tester, const Skeleton(width: 120, height: 30));
    expect(tester.getSize(find.byType(Skeleton)), const Size(120, 30));
  });

  testWidgets('the sweep moves between frames', (tester) async {
    await pump(tester, const Skeleton(width: 200));
    final first = gradientOf(tester) as LinearGradient?;
    expect(first, isNotNull, reason: 'it shimmers');

    await tester.pump(const Duration(milliseconds: 400));
    final later = gradientOf(tester) as LinearGradient?;
    expect(
      later!.begin,
      isNot(first!.begin),
      reason: 'the light travels across the block',
    );

    // A repeating animation would otherwise fail the test on pending timers.
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('someone who asked for less motion gets a still block', (
    tester,
  ) async {
    await pump(tester, const Skeleton(width: 200), still: true);
    expect(gradientOf(tester), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a line takes a share of the width it is offered', (
    tester,
  ) async {
    await pump(
      tester,
      const SizedBox(width: 300, child: Skeleton(widthFactor: 0.5)),
    );
    expect(tester.getSize(find.byType(Skeleton)).width, 300);
    final inner = tester.getSize(
      find.descendant(
        of: find.byType(FractionallySizedBox),
        matching: find.byType(DecoratedBox),
      ),
    );
    expect(inner.width, 150);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
