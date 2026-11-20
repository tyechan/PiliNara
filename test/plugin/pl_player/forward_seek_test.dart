import 'package:PiliPlus/plugin/pl_player/widgets/backward_seek.dart';
import 'package:PiliPlus/plugin/pl_player/widgets/forward_seek.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('double-tap accumulate wait is 250ms', () {
    expect(
      ForwardSeekIndicatorState.accumulateDelay,
      const Duration(milliseconds: 250),
    );
    expect(
      BackwardSeekIndicatorState.accumulateDelay,
      const Duration(milliseconds: 250),
    );
  });

  testWidgets('forward taps accumulate and submit once', (tester) async {
    Duration? submitted;
    await tester.pumpWidget(
      MaterialApp(
        home: ForwardSeekIndicator(
          duration: const Duration(seconds: 5),
          onSubmitted: (value) => submitted = value,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(submitted, isNull);
    await tester.tap(find.byType(ForwardSeekIndicator));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(submitted, isNull);
    await tester.pump(const Duration(milliseconds: 60));
    expect(submitted, const Duration(seconds: 10));
  });
}
