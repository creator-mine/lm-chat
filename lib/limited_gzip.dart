import 'dart:io';
import 'dart:typed_data';

/// The gzip stream expands past the caller's limit.
class GzipLimitException implements Exception {
  const GzipLimitException();
}

/// Decompresses gzip data in chunks and aborts once [limit] bytes are produced.
///
/// A small compressed payload can expand thousands of times, so callers that
/// accept untrusted data must not use `gzip.decode` and check the length later.
List<int> decodeGzipLimited(List<int> bytes, int limit) {
  final builder = BytesBuilder(copy: false);
  var total = 0;
  final sink = _LimitedSink((data) {
    total += data.length;
    if (total > limit) throw const GzipLimitException();
    builder.add(data);
  });
  final input = gzip.decoder.startChunkedConversion(sink);
  input.add(bytes);
  input.close();
  return builder.takeBytes();
}

class _LimitedSink implements Sink<List<int>> {
  _LimitedSink(this._add);

  final void Function(List<int> data) _add;

  @override
  void add(List<int> data) => _add(data);

  @override
  void close() {}
}
