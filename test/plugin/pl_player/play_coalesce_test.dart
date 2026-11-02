import 'package:PiliPlus/plugin/pl_player/models/play_coalesce.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PlayCoalesce', () {
    test('tap starts playback when not processing', () {
      final coalesce = PlayCoalesce();
      expect(
        coalesce.note(
          processing: false,
          intent: const PlayIntent(play: true),
        ),
        isTrue,
      );
      expect(coalesce.hasPendingPlay, isFalse);
    });

    test('play during processing is kept and flushed with latest intent', () {
      final coalesce = PlayCoalesce();
      expect(
        coalesce.note(
          processing: true,
          intent: const PlayIntent(play: true, hideControls: true),
        ),
        isFalse,
      );
      expect(coalesce.hasPendingPlay, isTrue);
      expect(
        coalesce.note(
          processing: true,
          intent: const PlayIntent(
            play: true,
            hideControls: false,
            position: Duration(seconds: 27),
          ),
        ),
        isFalse,
      );
      final pending = coalesce.take();
      expect(pending, isNotNull);
      expect(pending!.play, isTrue);
      expect(pending.hideControls, isFalse);
      expect(pending.position, const Duration(seconds: 27));
      expect(coalesce.hasPendingPlay, isFalse);
    });

    test('a later skip does not drop an earlier play intent', () {
      final coalesce = PlayCoalesce();
      coalesce.note(
        processing: true,
        intent: const PlayIntent(play: true),
      );
      coalesce.note(
        processing: true,
        intent: const PlayIntent(play: true, repeat: true),
      );
      final pending = coalesce.take()!;
      expect(pending.play, isTrue);
      expect(pending.repeat, isTrue);
    });
  });

  group('PageResumeIntent', () {
    test('quick back reopens and resumes the previous page', () {
      final stolen = PageResumeIntent.decide(
        playerReady: true,
        isLive: false,
        playerCid: 222,
        pageCid: 111,
        wasPlaying: true,
      );
      expect(stolen.reopen, isTrue);
      expect(stolen.play, isTrue);

      final relatedOnlyLoaded = PageResumeIntent.decide(
        playerReady: true,
        isLive: false,
        playerCid: 222,
        pageCid: 111,
        wasPlaying: null,
      );
      expect(relatedOnlyLoaded.reopen, isTrue);
      expect(relatedOnlyLoaded.play, isTrue);
    });

    test('same page with an explicit pause stays paused', () {
      final same = PageResumeIntent.decide(
        playerReady: true,
        isLive: false,
        playerCid: 111,
        pageCid: 111,
        wasPlaying: false,
      );
      expect(same.reopen, isFalse);
      expect(same.play, isFalse);
    });

    test('missing player always reopens', () {
      final missing = PageResumeIntent.decide(
        playerReady: false,
        isLive: false,
        playerCid: null,
        pageCid: 111,
        wasPlaying: true,
      );
      expect(missing.reopen, isTrue);
      expect(missing.play, isTrue);
    });
  });

  testWidgets('tap starts playback after an in-flight open finishes', (
    tester,
  ) async {
    final host = _PlayHost();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnimatedBuilder(
            animation: host,
            builder: (_, _) => _TapStartsPlayback(host: host),
          ),
        ),
      ),
    );
    host.beginOpen();
    await tester.tap(find.text('Play'));
    await tester.pump();
    expect(host.playing, isFalse);
    expect(find.text('paused'), findsOneWidget);
    host.finishOpen();
    await tester.pump();
    expect(host.playing, isTrue);
    expect(find.text('playing'), findsOneWidget);
  });

  testWidgets('quick back reopens and resumes the previous page', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: _QuickBackResume(),
        ),
      ),
    );
    expect(find.text('page-a playing'), findsNothing);
    await tester.tap(find.text('Back'));
    await tester.pump();
    expect(find.text('page-a playing'), findsOneWidget);
  });
}

class _PlayHost extends ChangeNotifier {
  bool processing = false;
  bool playing = false;
  final PlayCoalesce coalesce = PlayCoalesce();

  void beginOpen() {
    processing = true;
    notifyListeners();
  }

  void requestPlay() {
    final startNow = coalesce.note(
      processing: processing,
      intent: const PlayIntent(play: true),
    );
    if (startNow) playing = true;
    notifyListeners();
  }

  void finishOpen() {
    processing = false;
    final pending = coalesce.take();
    if (pending?.play == true) playing = true;
    notifyListeners();
  }
}

class _TapStartsPlayback extends StatefulWidget {
  const _TapStartsPlayback({required this.host});

  final _PlayHost host;

  @override
  State<_TapStartsPlayback> createState() => _TapStartsPlaybackState();
}

class _TapStartsPlaybackState extends State<_TapStartsPlayback> {
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(widget.host.playing ? 'playing' : 'paused'),
        TextButton(
          onPressed: () {
            widget.host.requestPlay();
            setState(() {});
          },
          child: const Text('Play'),
        ),
      ],
    );
  }
}

class _QuickBackResume extends StatefulWidget {
  const _QuickBackResume();

  @override
  State<_QuickBackResume> createState() => _QuickBackResumeState();
}

class _QuickBackResumeState extends State<_QuickBackResume> {
  var resumed = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (resumed) const Text('page-a playing'),
        TextButton(
          onPressed: () {
            final intent = PageResumeIntent.decide(
              playerReady: true,
              isLive: false,
              playerCid: 222,
              pageCid: 111,
              wasPlaying: true,
            );
            setState(() => resumed = intent.reopen && intent.play);
          },
          child: const Text('Back'),
        ),
      ],
    );
  }
}
