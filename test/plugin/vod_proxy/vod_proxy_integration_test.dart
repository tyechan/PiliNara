import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:PiliPlus/plugin/vod_proxy/vod_http_proxy.dart';
import 'package:PiliPlus/plugin/vod_proxy/vod_host_pool.dart';
import 'package:PiliPlus/plugin/vod_proxy/vod_proxy_log.dart';
import 'package:flutter_test/flutter_test.dart';

class _MockCdn {
  _MockCdn(
    this.bytes, {
    this.resetAfter,
    this.widerWindow = false,
    this.timeoutAt,
    this.timeoutFor = const Duration(seconds: 2),
    this.hangEveryMatching = false,
    this.hangAfterStart = false,
    this.slowAt,
    this.slowFor = const Duration(seconds: 7),
    this.advertiseHost = '127.0.0.1',
  });

  final Uint8List bytes;
  final int? resetAfter;
  final bool widerWindow;
  final int? timeoutAt;
  final Duration timeoutFor;
  final bool hangEveryMatching;
  final bool hangAfterStart;
  final int? slowAt;
  final Duration slowFor;
  final String advertiseHost;
  HttpServer? _server;
  int resets = 0;
  int timeouts = 0;
  int rangeHits = 0;
  int requests = 0;

  String get url => 'http://$advertiseHost:${_server!.port}/file.bin';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((request) async {
      final response = request.response;
      try {
        final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
        var start = 0;
        var end = bytes.length - 1;
        if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
          final spec = rangeHeader.substring(6);
          final parts = spec.split('-');
          start = int.tryParse(parts[0]) ?? 0;
          end = parts.length > 1 && parts[1].isNotEmpty
              ? int.parse(parts[1])
              : bytes.length - 1;
        }
        if (widerWindow && end - start < 4095) {
          end = min(start + 4095, bytes.length - 1);
        }
        start = start.clamp(0, bytes.length);
        end = end.clamp(start, bytes.length - 1);
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${bytes.length}',
        );
        response.headers.contentLength = end - start + 1;
        if (request.method == 'HEAD') {
          await response.close();
          return;
        }
        requests++;
        if (start == (timeoutAt ?? -1) || (hangAfterStart && start > 0)) {
          rangeHits++;
        }
        final hangThis = hangAfterStart
            ? start > 0
            : timeoutAt != null &&
                start == timeoutAt &&
                (hangEveryMatching || timeouts < 1);
        if (hangThis) {
          timeouts++;
          await Future<void>.delayed(timeoutFor);
          (await response.detachSocket()).destroy();
          return;
        }
        if (slowAt != null && start == slowAt) {
          await Future<void>.delayed(slowFor);
        }
        var sent = 0;
        const step = 8 * 1024;
        var offset = start;
        while (offset <= end) {
          final take = min(step, end - offset + 1);
          if (resetAfter != null && resets < 2 && sent + take > resetAfter!) {
            final leftover = resetAfter! - sent;
            if (leftover > 0) {
              response.add(bytes.sublist(offset, offset + leftover));
            }
            resets++;
            (await response.detachSocket()).destroy();
            return;
          }
          response.add(bytes.sublist(offset, offset + take));
          await response.flush();
          offset += take;
          sent += take;
        }
        await response.close();
      } catch (_) {
        try {
          await response.close();
        } catch (_) {}
      }
    });
  }

  Future<void> stop() async {
    await _server?.close(force: true);
  }
}

Future<Uint8List> _fetchAll(
  String url, {
  Duration timeout = const Duration(seconds: 15),
  int start = 0,
}) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    if (start > 0) {
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-');
    }
    final resp = await req.close().timeout(timeout);
    if (resp.statusCode >= 400) {
      throw HttpException('http ${resp.statusCode}', uri: Uri.parse(url));
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in resp.timeout(timeout)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  } finally {
    client.close(force: true);
  }
}

String? _which(String name) {
  final result = Process.runSync('which', [name]);
  if (result.exitCode != 0) return null;
  final path = (result.stdout as String).trim();
  return path.isEmpty ? null : path;
}

Future<void> _run(String exe, List<String> args) async {
  final result = await Process.run(exe, args);
  if (result.exitCode != 0) {
    fail('$exe ${args.join(' ')}\n${result.stdout}\n${result.stderr}');
  }
}

void main() {
  setUpAll(() {
    HttpOverrides.global = null;
  });

  late Uint8List payload;

  setUp(() async {
    payload = Uint8List.fromList(
      List<int>.generate(96 * 1024 + 77, (i) => (i * 31 + 7) & 0xff),
    );
    await VodHttpProxy.instance.resetForTest();
  });

  tearDown(() async {
    await VodHttpProxy.instance.resetForTest();
  });

  test('proxy serves the full file byte-for-byte via HTTP Range', () async {
    final cdn = _MockCdn(payload, widerWindow: true);
    await cdn.start();
    addTearDown(cdn.stop);
    final proxyUrl = await VodHttpProxy.instance.openRaw(
      cdn.url,
      chunkSize: 16 * 1024,
      windowBytes: 64 * 1024,
      workers: 3,
    );
    expect(proxyUrl, isNotNull);
    final got = await _fetchAll(proxyUrl!);
    expect(got, payload);
  }, timeout: const Timeout(Duration(seconds: 25)));

  test('mid-response chunk timeout still serves the full file', () async {
    final cdn = _MockCdn(
      payload,
      timeoutAt: 32 * 1024,
      timeoutFor: const Duration(seconds: 2),
    );
    await cdn.start();
    addTearDown(cdn.stop);
    final proxyUrl = await VodHttpProxy.instance.openRaw(
      cdn.url,
      chunkSize: 16 * 1024,
      windowBytes: 64 * 1024,
      workers: 3,
      attemptTimeout: const Duration(milliseconds: 400),
      fetchBudget: const Duration(seconds: 8),
    );
    expect(proxyUrl, isNotNull);
    final got = await _fetchAll(proxyUrl!).timeout(const Duration(seconds: 20));
    expect(got, payload);
    expect(cdn.timeouts, 1);
    expect(
      VodProxyLog.memoryLines.where((l) => l.contains('abort id=')),
      isEmpty,
    );
  }, timeout: const Timeout(Duration(seconds: 25)));

  test('slow chunk longer than the old ffmpeg timeout still delivers the full file', () async {
    final cdn = _MockCdn(
      payload,
      slowAt: 32 * 1024,
      slowFor: const Duration(seconds: 7),
    );
    await cdn.start();
    addTearDown(cdn.stop);
    final proxyUrl = await VodHttpProxy.instance.openRaw(
      cdn.url,
      chunkSize: 16 * 1024,
      windowBytes: 64 * 1024,
      workers: 3,
      // CDN body is delayed 7s — longer than the old ~5s lavf timeout —
      // but the proxy must keep the client socket open and finish.
      attemptTimeout: const Duration(seconds: 12),
      fetchBudget: const Duration(seconds: 25),
      cursorWatchdog: const Duration(seconds: 20),
    );
    expect(proxyUrl, isNotNull);
    final sw = Stopwatch()..start();
    final got = await _fetchAll(
      proxyUrl!,
      timeout: const Duration(seconds: 30),
    ).timeout(const Duration(seconds: 35));
    expect(got, payload);
    expect(sw.elapsed, greaterThan(const Duration(seconds: 6)));
    expect(
      VodProxyLog.memoryLines.where((l) => l.contains('abort id=')),
      isEmpty,
    );
  }, timeout: const Timeout(Duration(seconds: 45)));

  test('banned host is not retried for the cursor chunk; other host serves it', () async {
    final bad = _MockCdn(
      payload,
      timeoutAt: 32 * 1024,
      timeoutFor: const Duration(seconds: 5),
      hangEveryMatching: true,
      advertiseHost: '127.0.0.1',
    );
    final good = _MockCdn(payload, advertiseHost: 'localhost');
    await bad.start();
    await good.start();
    addTearDown(bad.stop);
    addTearDown(good.stop);
    final proxyUrl = await VodHttpProxy.instance.openRaw(
      bad.url,
      extras: [good.url],
      chunkSize: 16 * 1024,
      windowBytes: 64 * 1024,
      workers: 2,
      attemptTimeout: const Duration(seconds: 4),
      fetchBudget: const Duration(seconds: 10),
      cursorWatchdog: const Duration(seconds: 8),
    );
    expect(proxyUrl, isNotNull);
    final session = VodHttpProxy.instance.debugSessions.first;
    final fetch = _fetchAll(proxyUrl!).timeout(const Duration(seconds: 20));
    await Future<void>.delayed(const Duration(milliseconds: 250));
    for (var i = 0; i < VodHostPool.banAfterErrors; i++) {
      session.pool.recordFailure(bad.url, reason: 'TimeoutException');
    }
    final got = await fetch;
    expect(got, payload);
    expect(good.requests, greaterThan(0));
    expect(
      VodProxyLog.memoryLines.any((l) => l.contains('ban host=127.0.0.1')),
      isTrue,
    );
    expect(
      VodProxyLog.memoryLines.any((l) => l.contains('requeue id=')),
      isTrue,
    );
    final afterBan = VodProxyLog.memoryLines.skipWhile(
      (l) => !l.contains('ban host=127.0.0.1'),
    );
    expect(
      afterBan.where(
        (l) =>
            l.contains('retry id=') &&
            l.contains('range=bytes 32768-49151') &&
            l.contains('from=127.0.0.1') &&
            !l.contains('kicked'),
      ),
      isEmpty,
      reason: 'cursor chunk must not keep retrying the banned host',
    );
  }, timeout: const Timeout(Duration(seconds: 25)));

  test('ffmpeg copies a real MP4 through a mid-chunk CDN timeout', () async {
    final ffmpeg = _which('ffmpeg');
    if (ffmpeg == null) {
      // ignore: avoid_print
      print('SKIP ffmpeg not installed');
      return;
    }
    final dir = await Directory.systemTemp.createTemp('vodproxy');
    addTearDown(() => dir.delete(recursive: true));
    final src = File('${dir.path}/src.mp4');
    await _run(ffmpeg, [
      '-y',
      '-f',
      'lavfi',
      '-i',
      'testsrc=duration=2:size=320x240:rate=15',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440:duration=2',
      '-c:v',
      'libx264',
      '-pix_fmt',
      'yuv420p',
      '-c:a',
      'aac',
      src.path,
    ]);
    final bytes = Uint8List.fromList(await src.readAsBytes());
    expect(bytes.length, greaterThan(20 * 1024));
    final cdn = _MockCdn(
      bytes,
      timeoutAt: 16 * 1024,
      timeoutFor: const Duration(seconds: 2),
    );
    await cdn.start();
    addTearDown(cdn.stop);
    final proxyUrl = await VodHttpProxy.instance.openRaw(
      cdn.url,
      chunkSize: 16 * 1024,
      workers: 3,
      attemptTimeout: const Duration(milliseconds: 400),
      fetchBudget: const Duration(seconds: 8),
    );
    expect(proxyUrl, isNotNull);
    final out = File('${dir.path}/out.mp4');
    await _run(ffmpeg, ['-y', '-i', proxyUrl!, '-c', 'copy', out.path]);
    expect(out.lengthSync(), greaterThan(1000));
    expect(cdn.timeouts, 1);
    await _run(ffmpeg, ['-v', 'error', '-i', out.path, '-f', 'null', '-']);
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('proxy retries after a mid-stream CDN reset', () async {
    final cdn = _MockCdn(payload, resetAfter: 4 * 1024);
    await cdn.start();
    addTearDown(cdn.stop);
    final proxyUrl = await VodHttpProxy.instance.openRaw(
      cdn.url,
      chunkSize: 16 * 1024,
      windowBytes: 64 * 1024,
      workers: 3,
    );
    expect(proxyUrl, isNotNull);
    final got = await _fetchAll(proxyUrl!);
    expect(got, payload);
    expect(cdn.resets, greaterThan(0));
  }, timeout: const Timeout(Duration(seconds: 25)));

  test('ffmpeg can copy a real MP4 through the proxy', () async {
    final ffmpeg = _which('ffmpeg');
    if (ffmpeg == null) {
      // ignore: avoid_print
      print('SKIP ffmpeg not installed');
      return;
    }
    final dir = await Directory.systemTemp.createTemp('vodproxy');
    addTearDown(() => dir.delete(recursive: true));
    final src = File('${dir.path}/src.mp4');
    await _run(ffmpeg, [
      '-y',
      '-f',
      'lavfi',
      '-i',
      'testsrc=duration=0.4:size=160x120:rate=10',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440:duration=0.4',
      '-c:v',
      'libx264',
      '-pix_fmt',
      'yuv420p',
      '-c:a',
      'aac',
      src.path,
    ]);
    final cdn = _MockCdn(Uint8List.fromList(await src.readAsBytes()));
    await cdn.start();
    addTearDown(cdn.stop);
    final proxyUrl = await VodHttpProxy.instance.openRaw(
      cdn.url,
      chunkSize: 16 * 1024,
      workers: 3,
    );
    expect(proxyUrl, isNotNull);
    final out = File('${dir.path}/out.mp4');
    await _run(ffmpeg, ['-y', '-i', proxyUrl!, '-c', 'copy', out.path]);
    expect(out.lengthSync(), greaterThan(1000));
    await _run(ffmpeg, ['-v', 'error', '-i', out.path, '-f', 'null', '-']);
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('desktop mpv can open an edl:// of two proxy URLs', () async {
    final mpv = _which('mpv');
    final ffmpeg = _which('ffmpeg');
    if (mpv == null || ffmpeg == null) {
      // ignore: avoid_print
      print('SKIP mpv/ffmpeg not installed');
      return;
    }
    final dir = await Directory.systemTemp.createTemp('vodproxy');
    addTearDown(() => dir.delete(recursive: true));
    final src = File('${dir.path}/src.mp4');
    await _run(ffmpeg, [
      '-y',
      '-f',
      'lavfi',
      '-i',
      'testsrc=duration=0.4:size=160x120:rate=10',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440:duration=0.4',
      '-c:v',
      'libx264',
      '-pix_fmt',
      'yuv420p',
      '-c:a',
      'aac',
      src.path,
    ]);
    final cdn = _MockCdn(Uint8List.fromList(await src.readAsBytes()));
    await cdn.start();
    addTearDown(cdn.stop);
    final video = await VodHttpProxy.instance.openRaw(cdn.url, kind: 'video');
    final audio = await VodHttpProxy.instance.openRaw(cdn.url, kind: 'audio');
    expect(video, isNotNull);
    expect(audio, isNotNull);
    final edl =
        'edl://!no_chapters;%${video!.length}%$video;!new_stream;!no_chapters;%${audio!.length}%$audio';
    final result = await Process.run(mpv, [
      '--ao=null',
      '--vo=null',
      '--length=0.2',
      '--quiet',
      edl,
    ]).timeout(const Duration(seconds: 20));
    final err = '${result.stdout}\n${result.stderr}';
    expect(err, isNot(contains('Could not open source file')));
    expect(err, isNot(contains('Failed to open http://127.0.0.1')));
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('re-reading the same file does not inflate unique served bytes', () async {
    final cdn = _MockCdn(payload);
    await cdn.start();
    addTearDown(cdn.stop);
    final proxyUrl = await VodHttpProxy.instance.openRaw(
      cdn.url,
      chunkSize: 16 * 1024,
      windowBytes: 64 * 1024,
      workers: 3,
    );
    expect(proxyUrl, isNotNull);
    await _fetchAll(proxyUrl!);
    await _fetchAll(proxyUrl);
    final session = VodHttpProxy.instance.debugSessions.first;
    expect(session.uniqueServedBytes, lessThanOrEqualTo(payload.length));
    expect(session.uniqueFetchedBytes, lessThanOrEqualTo(payload.length + 16 * 1024));
  }, timeout: const Timeout(Duration(seconds: 25)));

  test('pause logs session_pause and stops stats until resume', () async {
    final cdn = _MockCdn(payload);
    await cdn.start();
    addTearDown(cdn.stop);
    final proxyUrl = await VodHttpProxy.instance.openRaw(
      cdn.url,
      chunkSize: 16 * 1024,
      workers: 2,
    );
    expect(proxyUrl, isNotNull);
    await _fetchAll(proxyUrl!);
    final session = VodHttpProxy.instance.debugSessions.first;
    VodHttpProxy.instance.flushSessionEnd(reason: 'pause');
    expect(VodHttpProxy.instance.hasActiveSession, isTrue);
    expect(session.statsPaused, isTrue);
    expect(session.statsRunning, isFalse);
    expect(
      VodProxyLog.memoryLines.where((l) => l.contains('session_pause')),
      isNotEmpty,
    );
    expect(
      VodProxyLog.memoryLines.where((l) => l.contains('session_end')),
      isEmpty,
    );
    final statsBefore = VodProxyLog.memoryLines
        .where((l) => l.contains('stats id='))
        .length;
    session.startStats();
    expect(session.statsRunning, isFalse);
    expect(
      VodProxyLog.memoryLines.where((l) => l.contains('stats id=')).length,
      statsBefore,
    );
    VodHttpProxy.instance.flushSessionEnd(reason: 'pause');
    expect(
      VodProxyLog.memoryLines.where((l) => l.contains('session_pause')).length,
      1,
    );
    VodHttpProxy.instance.closeAll(reason: 'dispose');
    expect(
      VodProxyLog.memoryLines.where((l) => l.contains('session_end')).length,
      1,
    );
  }, timeout: const Timeout(Duration(seconds: 25)));

  test('backward seek within the back-buffer does not re-fetch', () async {
    final big = Uint8List.fromList(
      List<int>.generate(160 * 1024, (i) => (i * 17 + 3) & 0xff),
    );
    final cdn = _MockCdn(big);
    await cdn.start();
    addTearDown(cdn.stop);
    final proxyUrl = await VodHttpProxy.instance.openRaw(
      cdn.url,
      chunkSize: 16 * 1024,
      windowBytes: 32 * 1024,
      backBufferBytes: 96 * 1024,
      workers: 3,
    );
    expect(proxyUrl, isNotNull);
    expect(await _fetchAll(proxyUrl!), big);
    final session = VodHttpProxy.instance.debugSessions.first;
    final netAfterForward = session.bytesNet;
    final fetchedAfterForward = session.uniqueFetchedBytes;
    final mid = await _fetchAll(proxyUrl, start: 48 * 1024);
    expect(mid, big.sublist(48 * 1024));
    expect(session.uniqueFetchedBytes, fetchedAfterForward);
    expect(session.bytesNet, netAfterForward);
  }, timeout: const Timeout(Duration(seconds: 25)));

  test('kicking a banned host does not restart every in-flight request', () async {
    final bad = _MockCdn(
      payload,
      timeoutAt: 16 * 1024,
      timeoutFor: const Duration(seconds: 3),
      hangEveryMatching: true,
      advertiseHost: '127.0.0.1',
    );
    final good = _MockCdn(payload, advertiseHost: 'localhost');
    await bad.start();
    await good.start();
    addTearDown(bad.stop);
    addTearDown(good.stop);
    final proxyUrl = await VodHttpProxy.instance.openRaw(
      bad.url,
      extras: [good.url],
      chunkSize: 16 * 1024,
      windowBytes: 64 * 1024,
      workers: 4,
      attemptTimeout: const Duration(seconds: 4),
      fetchBudget: const Duration(seconds: 12),
    );
    expect(proxyUrl, isNotNull);
    final session = VodHttpProxy.instance.debugSessions.first;
    final fetch = _fetchAll(proxyUrl!).timeout(const Duration(seconds: 20));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    for (var i = 0; i < VodHostPool.banAfterErrors; i++) {
      session.pool.recordFailure(bad.url, reason: 'TimeoutException');
    }
    final got = await fetch;
    expect(got, payload);
    expect(
      VodProxyLog.memoryLines.where((l) => l.contains('reason=kicked')),
      isEmpty,
    );
    expect(session.bytesNet, lessThan(session.uniqueFetchedBytes * 2));
  }, timeout: const Timeout(Duration(seconds: 25)));

  test('recently closed sessions stay resolvable for a few seconds', () async {
    final cdn = _MockCdn(payload);
    await cdn.start();
    addTearDown(cdn.stop);
    final proxyUrl = await VodHttpProxy.instance.openRaw(
      cdn.url,
      chunkSize: 16 * 1024,
      workers: 2,
    );
    expect(proxyUrl, isNotNull);
    await _fetchAll(proxyUrl!);
    VodHttpProxy.instance.closeAll(reason: 'new-wrap');
    expect(VodHttpProxy.instance.hasActiveSession, isFalse);
    final got = await _fetchAll(proxyUrl);
    expect(got, payload);
    expect(
      VodProxyLog.memoryLines.any((l) => l.contains('session_end')),
      isFalse,
    );
  }, timeout: const Timeout(Duration(seconds: 25)));

  test('closeAll dispose stops the session and writes session_end', () async {
    final cdn = _MockCdn(payload);
    await cdn.start();
    addTearDown(cdn.stop);
    final proxyUrl = await VodHttpProxy.instance.openRaw(
      cdn.url,
      chunkSize: 16 * 1024,
      workers: 2,
    );
    expect(proxyUrl, isNotNull);
    await _fetchAll(proxyUrl!);
    VodHttpProxy.instance.closeAll(reason: 'dispose');
    expect(VodHttpProxy.instance.hasActiveSession, isFalse);
    expect(
      VodProxyLog.memoryLines.any((l) => l.contains('session_end')),
      isTrue,
    );
    expect(
      VodProxyLog.memoryLines.any((l) => l.contains('close reason=dispose')),
      isTrue,
    );
    await expectLater(_fetchAll(proxyUrl), throwsA(isA<HttpException>()));
  }, timeout: const Timeout(Duration(seconds: 25)));

  test('direct CDN URL still plays (toggle-off path)', () async {
    final cdn = _MockCdn(payload);
    await cdn.start();
    addTearDown(cdn.stop);
    final got = await _fetchAll(cdn.url);
    expect(got, payload);
  }, timeout: const Timeout(Duration(seconds: 15)));
}
