import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:PiliPlus/plugin/vod_proxy/vod_http_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

class _MockCdn {
  _MockCdn(this.bytes, {this.resetAfter, this.widerWindow = false});

  final Uint8List bytes;
  final int? resetAfter;
  final bool widerWindow;
  HttpServer? _server;
  int resets = 0;

  String get url => 'http://127.0.0.1:${_server!.port}/file.bin';

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

Future<Uint8List> _fetchAll(String url) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    final resp = await req.close().timeout(const Duration(seconds: 15));
    final builder = BytesBuilder(copy: false);
    await for (final chunk in resp.timeout(const Duration(seconds: 15))) {
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

  test('direct CDN URL still plays (toggle-off path)', () async {
    final cdn = _MockCdn(payload);
    await cdn.start();
    addTearDown(cdn.stop);
    final got = await _fetchAll(cdn.url);
    expect(got, payload);
  }, timeout: const Timeout(Duration(seconds: 15)));
}
