/// Latest-wins play request while [setDataSource] is still opening media.
class PlayIntent {
  const PlayIntent({
    this.play = true,
    this.repeat = false,
    this.hideControls = true,
    this.position,
  });

  final bool play;
  final bool repeat;
  final bool hideControls;
  final Duration? position;

  PlayIntent merge(PlayIntent next) {
    return PlayIntent(
      play: next.play,
      repeat: next.repeat,
      hideControls: next.hideControls,
      position: next.position ?? position,
    );
  }
}

/// Dedupes [play] calls that arrive while an open is in flight.
///
/// A processing-time [play] is not dropped: it is stored and should be
/// flushed when processing ends, keeping the latest autoplay/resume intent.
class PlayCoalesce {
  PlayIntent? pending;

  bool get hasPendingPlay => pending?.play == true;

  /// Returns true if the caller should start playback immediately.
  bool note({required bool processing, required PlayIntent intent}) {
    if (!processing) {
      pending = intent.play ? null : intent;
      return intent.play;
    }
    pending = pending == null ? intent : pending!.merge(intent);
    return false;
  }

  PlayIntent? take() {
    final value = pending;
    pending = null;
    return value;
  }
}

/// Whether returning to a video page must reopen media and/or resume.
class PageResumeIntent {
  const PageResumeIntent({required this.reopen, required this.play});

  final bool reopen;
  final bool play;

  static PageResumeIntent decide({
    required bool playerReady,
    required bool isLive,
    required int? playerCid,
    required int pageCid,
    bool? wasPlaying,
  }) {
    final stolen = !playerReady || isLive || playerCid != pageCid;
    // Reopen when the singleton was stolen or never opened. Resume unless
    // the previous page explicitly recorded a pause.
    final play = wasPlaying ?? stolen;
    return PageResumeIntent(reopen: stolen, play: play);
  }
}
