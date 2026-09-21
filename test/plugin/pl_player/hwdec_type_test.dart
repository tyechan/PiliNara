import 'package:PiliPlus/plugin/pl_player/models/hwdec_type.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android default prefers copy-back MediaCodec', () {
    expect(HwDecType.androidDefault, 'mediacodec-copy,auto-safe');
  });

  test('isDirectMediacodec only matches zero-copy', () {
    expect(HwDecType.isDirectMediacodec('mediacodec'), isTrue);
    expect(HwDecType.isDirectMediacodec(' mediacodec '), isTrue);
    expect(HwDecType.isDirectMediacodec('mediacodec-copy'), isFalse);
    expect(HwDecType.isDirectMediacodec('auto-safe'), isFalse);
    expect(HwDecType.isDirectMediacodec(null), isFalse);
  });
}
