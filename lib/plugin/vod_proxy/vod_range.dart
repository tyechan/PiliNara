/// Pure byte-range helpers for the VOD multi-connection proxy.
/// Kept side-effect free so splitting / validation can be unit-tested.

class ByteRange {
  const ByteRange(this.start, this.endExclusive);

  final int start;
  final int endExclusive;

  int get length => endExclusive - start;
  int get endInclusive => endExclusive - 1;

  @override
  bool operator ==(Object other) =>
      other is ByteRange &&
      other.start == start &&
      other.endExclusive == endExclusive;

  @override
  int get hashCode => Object.hash(start, endExclusive);

  @override
  String toString() => 'bytes $start-$endInclusive';
}

class HttpRangeRequest {
  const HttpRangeRequest({required this.start, this.endInclusive});

  final int start;
  final int? endInclusive;

  static HttpRangeRequest? parse(String? header) {
    if (header == null || header.isEmpty) return null;
    final raw = header.trim();
    if (!raw.toLowerCase().startsWith('bytes=')) return null;
    final spec = raw.substring(6).split(',').first.trim();
    if (spec.startsWith('-')) {
      final suffix = int.tryParse(spec.substring(1));
      if (suffix == null || suffix <= 0) return null;
      return HttpRangeRequest(start: -suffix);
    }
    final parts = spec.split('-');
    if (parts.isEmpty) return null;
    final start = int.tryParse(parts[0]);
    if (start == null || start < 0) return null;
    final end = parts.length > 1 && parts[1].isNotEmpty
        ? int.tryParse(parts[1])
        : null;
    if (parts.length > 1 && parts[1].isNotEmpty && end == null) return null;
    if (end != null && end < start) return null;
    return HttpRangeRequest(start: start, endInclusive: end);
  }

  /// Resolve a suffix request (`start < 0`) against a known file size.
  ByteRange resolve(int fileSize) {
    if (fileSize <= 0) {
      return const ByteRange(0, 0);
    }
    if (start < 0) {
      final from = (fileSize + start).clamp(0, fileSize);
      return ByteRange(from, fileSize);
    }
    final from = start.clamp(0, fileSize);
    final toExclusive = endInclusive == null
        ? fileSize
        : (endInclusive! + 1).clamp(from, fileSize);
    return ByteRange(from, toExclusive);
  }
}

class ContentRangeReply {
  const ContentRangeReply({
    required this.start,
    required this.endInclusive,
    required this.total,
  });

  final int start;
  final int endInclusive;
  final int total;

  int get length => endInclusive - start + 1;

  static final _re = RegExp(r'bytes\s+(\d+)-(\d+)/(\d+|\*)');

  static ContentRangeReply? parse(String? header) {
    if (header == null || header.isEmpty) return null;
    final m = _re.firstMatch(header.trim());
    if (m == null) return null;
    final start = int.tryParse(m.group(1)!);
    final end = int.tryParse(m.group(2)!);
    final totalRaw = m.group(3)!;
    final total = totalRaw == '*' ? null : int.tryParse(totalRaw);
    if (start == null || end == null || end < start) return null;
    if (total != null && total <= end) return null;
    return ContentRangeReply(
      start: start,
      endInclusive: end,
      total: total ?? (end + 1),
    );
  }

  bool matches({required int start, required int endInclusive}) {
    return this.start == start && this.endInclusive == endInclusive;
  }

  /// True when the reply contains every byte we asked for (CDNs often
  /// return a wider aligned window than the request).
  bool covers({required int start, required int endInclusive}) {
    return this.start <= start && this.endInclusive >= endInclusive;
  }
}

List<ByteRange> splitRanges(int start, int endExclusive, int chunkSize) {
  if (endExclusive <= start || chunkSize <= 0) return const [];
  final out = <ByteRange>[];
  var cursor = start;
  while (cursor < endExclusive) {
    final next = cursor + chunkSize;
    final end = next < endExclusive ? next : endExclusive;
    out.add(ByteRange(cursor, end));
    cursor = end;
  }
  return out;
}

int? parsePlayurlDeadline(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  return int.tryParse(uri.queryParameters['deadline'] ?? '');
}
