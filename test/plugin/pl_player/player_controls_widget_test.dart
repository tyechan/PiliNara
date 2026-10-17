import 'dart:io';

import 'package:PiliPlus/common/widgets/pip_control_button.dart';
import 'package:PiliPlus/common/widgets/player_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// Replica of the on-screen chrome (header PlayerBar + bottom buttons +
/// lock/screenshot). Matches HeaderControl after Starfallan 2.1.6: title is
/// Stack/Padding/Column, never Expanded/Spacer.
class _PlayerControlsChrome extends StatelessWidget {
  const _PlayerControlsChrome({
    required this.fullscreen,
    required this.showControls,
    this.title = '《少数派报告》',
    this.onlineTotal,
  });

  final bool fullscreen;
  final RxBool showControls;
  final String title;
  final RxInt? onlineTotal;

  @override
  Widget build(BuildContext context) {
    Widget? barTitle = Padding(
      padding: const EdgeInsets.only(right: 10),
      child: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white, fontSize: 16),
      ),
    );
    if (onlineTotal != null) {
      barTitle = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          barTitle,
          Obx(
            () => Text(
              '${onlineTotal!.value}人正在看',
              style: const TextStyle(color: Colors.white, fontSize: 11),
            ),
          ),
        ],
      );
    }

    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Color(0xFF101010)),
          Positioned.fill(
            child: Obx(
              () => Offstage(
                offstage: !showControls.value,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: PlayerBar(
                        left: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.arrow_back, color: Colors.white),
                            Icon(Icons.home_outlined, color: Colors.white),
                          ],
                        ),
                        right: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.comment_outlined, color: Colors.white),
                            Icon(Icons.more_vert, color: Colors.white),
                          ],
                        ),
                        title: barTitle,
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(12, 0, 12, 16),
                      child: Row(
                        children: [
                          Icon(Icons.pause, color: Colors.white),
                          SizedBox(width: 8),
                          Text(
                            '01:23 / 12:34',
                            style: TextStyle(color: Colors.white, fontSize: 12),
                          ),
                          Spacer(),
                          Text(
                            '1.0X',
                            style: TextStyle(color: Colors.white, fontSize: 13),
                          ),
                          Icon(Icons.fullscreen, color: Colors.white),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (fullscreen) ...[
            const Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.only(left: 24),
                child: Icon(Icons.lock_open, color: Colors.white),
              ),
            ),
            const Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: EdgeInsets.only(right: 24),
                child: Icon(Icons.photo_camera_outlined, color: Colors.white),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Replica of the in-app floating mini window chrome (video or live).
class _MiniWindowChrome extends StatelessWidget {
  const _MiniWindowChrome({required this.live});

  final bool live;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: Color(0xFF202020))),
            const Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(color: Color(0x66000000)),
              ),
            ),
            const Positioned(
              top: 2,
              left: 4,
              child: PipControlButton(
                targetSize: 28,
                onTap: _noop,
                icon: Icon(Icons.close, color: Colors.white, size: 21),
              ),
            ),
            const Positioned(
              top: 2,
              right: 4,
              child: PipControlButton(
                targetSize: 28,
                onTap: _noop,
                icon: Icon(Icons.open_in_full, color: Colors.white, size: 19),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 4,
              child: Row(
                children: [
                  if (live)
                    const Expanded(child: SizedBox.shrink())
                  else
                    const Expanded(
                      child: Center(
                        child: PipControlButton(
                          targetSize: 40,
                          onTap: _noop,
                          icon: Icon(
                            Icons.replay_10,
                            color: Colors.white,
                            size: 22,
                          ),
                        ),
                      ),
                    ),
                  if (!live) const SizedBox(width: 8),
                  const Expanded(
                    child: Center(
                      child: PipPlayPauseButton(
                        targetSize: 40,
                        onToggle: _noop,
                      ),
                    ),
                  ),
                  if (!live) const SizedBox(width: 8),
                  Expanded(
                    child: Center(
                      child: PipControlButton(
                        targetSize: 40,
                        onTap: _noop,
                        icon: Icon(
                          live ? Icons.refresh : Icons.forward_10,
                          color: Colors.white,
                          size: 22,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void _noop() {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('HeaderControl no longer wraps PlayerBar.title in Expanded/Spacer', () {
    final src = File(
      'lib/pages/video/widgets/header_control.dart',
    ).readAsStringSync();
    expect(src.contains('title = Expanded('), isFalse);
    expect(src.contains('title = const Spacer()'), isFalse);
    expect(src.contains('PlayerBar('), isTrue);
  });

  test('mini-window overlays do not Obx a non-Rx playerStatus', () {
    for (final path in [
      'lib/services/pip_overlay_service.dart',
      'lib/services/live_pip_overlay_service.dart',
    ]) {
      final src = File(path).readAsStringSync();
      expect(src.contains('PipPlayPauseButton('), isTrue, reason: path);
      expect(
        src.contains('playerStatus'),
        isTrue,
        reason: '$path still reads status on tap, but not inside Obx',
      );
      expect(RegExp(r'Obx\(\(\)\s*\{[^}]*playerStatus').hasMatch(src), isFalse);
    }
  });

  testWidgets(
    'PlayerBar title slot throws FlutterError when given Expanded (the 1014 grey box)',
    (tester) async {
      final errors = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (details) {
        errors.add(details);
      };

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 48,
              child: PlayerBar(
                left: Icon(Icons.arrow_back),
                right: Icon(Icons.more_vert),
                title: Expanded(child: Text('title')),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      FlutterError.onError = previous;
      final exception = tester.takeException();
      final messages = [
        ...errors.map((e) => e.exceptionAsString()),
        if (exception != null) exception.toString(),
      ].join('\n');
      expect(
        messages,
        anyOf(
          contains('ParentDataWidget'),
          contains('Expanded'),
          contains('FlexParentData'),
        ),
      );
    },
  );

  testWidgets(
    'player controls chrome pumps without FlutterError (half-screen + fullscreen)',
    (tester) async {
      final showControls = true.obs;
      final online = 1234.obs;
      final errors = <FlutterErrorDetails>[];
      final previousOnError = FlutterError.onError;
      final previousPresent = FlutterError.presentError;
      FlutterError.onError = (details) {
        errors.add(details);
        previousOnError?.call(details);
      };
      FlutterError.presentError = (details) {
        errors.add(details);
        previousPresent(details);
      };

      addTearDown(() {
        FlutterError.onError = previousOnError;
        FlutterError.presentError = previousPresent;
      });

      Future<void> pumpChrome({required bool fullscreen}) async {
        final size = fullscreen ? const Size(800, 450) : const Size(400, 225);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            home: MediaQuery(
              data: MediaQueryData(size: size),
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: _PlayerControlsChrome(
                  fullscreen: fullscreen,
                  showControls: showControls,
                  onlineTotal: online,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await pumpChrome(fullscreen: false);
      expect(tester.takeException(), isNull);
      expect(find.text('《少数派报告》'), findsOneWidget);
      expect(find.text('1234人正在看'), findsOneWidget);
      expect(find.text('01:23 / 12:34'), findsOneWidget);
      expect(find.byIcon(Icons.pause), findsOneWidget);
      expect(find.byType(ErrorWidget), findsNothing);

      await expectLater(
        find.byType(_PlayerControlsChrome),
        matchesGoldenFile('goldens/player_controls_half_screen.png'),
      );

      await pumpChrome(fullscreen: true);
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.lock_open), findsOneWidget);
      expect(find.byIcon(Icons.photo_camera_outlined), findsOneWidget);
      expect(find.byType(ErrorWidget), findsNothing);

      await expectLater(
        find.byType(_PlayerControlsChrome),
        matchesGoldenFile('goldens/player_controls_fullscreen.png'),
      );

      showControls.value = false;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(ErrorWidget), findsNothing);

      expect(
        errors,
        isEmpty,
        reason: errors.map((e) => e.exceptionAsString()).join('\n---\n'),
      );
    },
  );

  testWidgets(
    'Obx that does not read an Rx throws (mini-window 1015 grey box)',
    (tester) async {
      final errors = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (details) {
        errors.add(details);
      };

      const playing = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 240,
              height: 136,
              child: Row(
                children: [
                  const Expanded(child: SizedBox.shrink()),
                  Expanded(
                    child: Obx(
                      () => Icon(
                        playing ? Icons.pause : Icons.play_arrow,
                      ),
                    ),
                  ),
                  const Expanded(child: SizedBox.shrink()),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      FlutterError.onError = previous;
      final exception = tester.takeException();
      final messages = [
        ...errors.map((e) => e.exceptionAsString()),
        if (exception != null) exception.toString(),
      ].join('\n');
      expect(messages, contains('improper use of a GetX'));
    },
  );

  testWidgets(
    'mini window and live mini window controls pump without FlutterError',
    (tester) async {
      final errors = <FlutterErrorDetails>[];
      final previousOnError = FlutterError.onError;
      final previousPresent = FlutterError.presentError;
      FlutterError.onError = (details) {
        errors.add(details);
        previousOnError?.call(details);
      };
      FlutterError.presentError = (details) {
        errors.add(details);
        previousPresent(details);
      };
      addTearDown(() {
        FlutterError.onError = previousOnError;
        FlutterError.presentError = previousPresent;
      });

      Future<void> pumpMini({required bool live}) async {
        const size = Size(240, 136);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            home: MediaQuery(
              data: const MediaQueryData(size: size),
              child: SizedBox(
                width: 240,
                height: 136,
                child: _MiniWindowChrome(live: live),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await pumpMini(live: false);
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(find.byIcon(Icons.open_in_full), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      expect(find.byIcon(Icons.replay_10), findsOneWidget);
      expect(find.byIcon(Icons.forward_10), findsOneWidget);
      expect(find.byType(ErrorWidget), findsNothing);
      await expectLater(
        find.byType(_MiniWindowChrome),
        matchesGoldenFile('goldens/player_controls_mini_window.png'),
      );

      await pumpMini(live: true);
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.refresh), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      expect(find.byType(ErrorWidget), findsNothing);
      await expectLater(
        find.byType(_MiniWindowChrome),
        matchesGoldenFile('goldens/player_controls_live_mini_window.png'),
      );

      expect(
        errors,
        isEmpty,
        reason: errors.map((e) => e.exceptionAsString()).join('\n---\n'),
      );
    },
  );
}
