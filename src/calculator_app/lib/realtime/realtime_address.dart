import 'realtime_constants.dart';

/// What the configured WebSocket address allows.
enum RealtimeAddressState { notConfigured, invalid, valid }

/// The WebSocket address of the real-time backend, without any token.
///
/// Only an absolute `wss://` address is accepted, or `ws://` to `localhost` /
/// `127.0.0.1` for local runs (mirrors `hasTrustedBaseUrl`). The token is added
/// only when a connection URI is built and is never kept.
class RealtimeAddress {
  const RealtimeAddress._(this.state, this._base);

  /// Reads the address from the `WS_BASE_URL` build-time setting.
  factory RealtimeAddress.fromEnvironment() =>
      RealtimeAddress.parse(const String.fromEnvironment('WS_BASE_URL'));

  factory RealtimeAddress.parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) {
      return const RealtimeAddress._(RealtimeAddressState.notConfigured, null);
    }
    final uri = Uri.tryParse(text);
    if (uri == null || !_isTrusted(uri)) {
      return const RealtimeAddress._(RealtimeAddressState.invalid, null);
    }
    return RealtimeAddress._(RealtimeAddressState.valid, uri);
  }

  final RealtimeAddressState state;
  final Uri? _base;

  bool get isUsable => state == RealtimeAddressState.valid;

  /// The text to show when the address cannot be used, or null when it can.
  String? get problemMessage => switch (state) {
        RealtimeAddressState.valid => null,
        RealtimeAddressState.notConfigured =>
          RealtimeConstants.notConfiguredMessage,
        RealtimeAddressState.invalid => RealtimeConstants.invalidAddressMessage,
      };

  /// The address with the single query parameter `token`, percent-encoded.
  Uri connectionUri(String token) {
    final base = _base;
    if (base == null) throw StateError('The real-time address is not usable.');
    return base.replace(
      queryParameters: {RealtimeConstants.tokenParameter: token},
    );
  }

  static bool _isTrusted(Uri uri) {
    if (!uri.hasAuthority || uri.host.isEmpty) return false;
    if (uri.hasQuery || uri.hasFragment || uri.userInfo.isNotEmpty) {
      return false;
    }
    if (uri.scheme == 'wss') return true;
    return uri.scheme == 'ws' &&
        (uri.host == 'localhost' || uri.host == '127.0.0.1');
  }

  /// Never includes the address: only its state.
  @override
  String toString() => 'RealtimeAddress(${state.name})';
}
