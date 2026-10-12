import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const pathAndQuery = '/upgcxcode/00/00/1.m4s?deadline=1&os=upos';

  test('rotates a known host to the next fallback', () {
    final url = 'https://upos-sz-mirrorali.bilivideo.com$pathAndQuery';
    final rotated = VideoUtils.rotateMediaHost(url);
    expect(
      rotated,
      'https://upos-sz-mirrorhw.bilivideo.com$pathAndQuery',
    );
  });

  test('cosov (not in fallback list) jumps to ali', () {
    final url = 'https://upos-sz-mirrorcosov.bilivideo.com$pathAndQuery';
    final rotated = VideoUtils.rotateMediaHost(url);
    expect(
      rotated,
      'https://${VideoUtils.rotateFallbackHosts.first}$pathAndQuery',
    );
  });

  test('leaves non-media hosts unchanged', () {
    const url = 'https://api.bilibili.com/x/player/playurl';
    expect(VideoUtils.rotateMediaHost(url), url);
  });
}
