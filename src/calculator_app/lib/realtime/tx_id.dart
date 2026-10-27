import 'dart:math';

/// A random UUID v4 in lowercase, from a cryptographically secure source.
///
/// [random] is injectable for tests; the default is `Random.secure()`.
String generateTxId([Random? random]) {
  final source = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => source.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')];
  String part(int from, int to) => hex.sublist(from, to).join();
  return '${part(0, 4)}-${part(4, 6)}-${part(6, 8)}-${part(8, 10)}-${part(10, 16)}';
}
