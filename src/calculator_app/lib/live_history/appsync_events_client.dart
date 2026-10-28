import 'dart:async';
import 'dart:convert';

import '../realtime/realtime_channel.dart';
import '../realtime/tx_id.dart';
import '../realtime/web_socket_realtime_channel.dart';
import 'live_calculation.dart';
import 'live_history_constants.dart';

/// Category of an AppSync Events handshake failure. Holds no URL, token or sub.
enum AppSyncHandshakeFailure { authRejected, transient }

/// Thrown when opening or subscribing to the AppSync Events channel fails.
class AppSyncHandshakeException implements Exception {
  const AppSyncHandshakeException(this.failure);

  const AppSyncHandshakeException.authRejected()
      : failure = AppSyncHandshakeFailure.authRejected;

  const AppSyncHandshakeException.transient()
      : failure = AppSyncHandshakeFailure.transient;

  final AppSyncHandshakeFailure failure;

  bool get isAuthRejected => failure == AppSyncHandshakeFailure.authRejected;

  @override
  String toString() => 'AppSyncHandshakeException(${failure.name})';
}

/// An active `/history/<sub>` subscription over AppSync Events.
abstract interface class AppSyncEventsSession {
  /// Parsed calculation events arriving on the subscribed channel.
  Stream<LiveCalculation> get calculations;

  /// Completes when the session closes (whether by server, watchdog or client).
  Future<void> get done;

  /// Count of frames ignored because they were oversized, malformed or not a
  /// calculation event.
  int get ignoredCount;

  /// Clamped keep-alive timeout negotiated in `connection_ack`.
  Duration get keepAliveTimeout;

  /// UUID v4 subscription identifier used for `subscribe` and `unsubscribe`.
  String get subscriptionId;

  /// Sends `unsubscribe` if subscribed and closes the WebSocket with code 1000.
  Future<void> close();
}

/// Port for opening an [AppSyncEventsSession].
abstract interface class AppSyncEventsConnector {
  Future<AppSyncEventsSession> subscribe({
    required Uri realtimeUri,
    required String httpDomain,
    required String idToken,
    required String sub,
  });
}

/// Connects and subscribes to `/history/<sub>` on AWS AppSync Events.
class AppSyncEventsClient implements AppSyncEventsConnector {
  AppSyncEventsClient({
    RealtimeChannelFactory? channels,
    String Function()? newSubscriptionId,
    Duration handshakeTimeout = LiveHistoryConstants.handshakeTimeout,
  })  : _channels = channels ?? WebSocketRealtimeChannelFactory(),
        _newSubscriptionId = newSubscriptionId ?? generateTxId,
        _handshakeTimeout = handshakeTimeout;

  final RealtimeChannelFactory _channels;
  final String Function() _newSubscriptionId;
  final Duration _handshakeTimeout;

  /// Builds the unpadded `header-<base64url>` subprotocol required by AppSync
  /// Events on the WebSocket upgrade request.
  static String buildAuthSubprotocol({
    required String httpDomain,
    required String idToken,
  }) {
    final headerJson = jsonEncode({
      'host': httpDomain,
      'Authorization': idToken,
    });
    final encoded =
        base64Url.encode(utf8.encode(headerJson)).replaceAll('=', '');
    return '${LiveHistoryConstants.authSubprotocolPrefix}$encoded';
  }

  /// Clamps `connectionTimeoutMs` from `connection_ack` to 10 s .. 600 s.
  static Duration clampKeepAliveTimeout(Object? rawTimeoutMs) {
    final ms = rawTimeoutMs is int
        ? rawTimeoutMs
        : LiveHistoryConstants.defaultKeepAliveTimeoutMs;
    final clamped = ms.clamp(
      LiveHistoryConstants.minKeepAliveTimeoutMs,
      LiveHistoryConstants.maxKeepAliveTimeoutMs,
    );
    return Duration(milliseconds: clamped);
  }

  @override
  Future<AppSyncEventsSession> subscribe({
    required Uri realtimeUri,
    required String httpDomain,
    required String idToken,
    required String sub,
  }) async {
    final authProtocol = buildAuthSubprotocol(
      httpDomain: httpDomain,
      idToken: idToken,
    );
    final RealtimeChannel channel;
    try {
      channel = await _channels.connect(
        realtimeUri,
        protocols: [
          LiveHistoryConstants.eventWsSubprotocol,
          authProtocol,
        ],
      );
    } on RealtimeChannelException catch (e) {
      if (e.failure == RealtimeFailure.refused) {
        throw const AppSyncHandshakeException.authRejected();
      }
      throw const AppSyncHandshakeException.transient();
    } catch (_) {
      throw const AppSyncHandshakeException.transient();
    }

    final session = _ActiveAppSyncSession(
      channel: channel,
      subscriptionId: _newSubscriptionId(),
      handshakeTimeout: _handshakeTimeout,
    );
    try {
      await session.performHandshake(
        httpDomain: httpDomain,
        idToken: idToken,
        sub: sub,
      );
      return session;
    } catch (_) {
      await session.close();
      rethrow;
    }
  }

  @override
  String toString() => 'AppSyncEventsClient()';
}

enum _HandshakePhase { waitingConnectionAck, waitingSubscribeSuccess, live }

class _ActiveAppSyncSession implements AppSyncEventsSession {
  _ActiveAppSyncSession({
    required RealtimeChannel channel,
    required this.subscriptionId,
    required Duration handshakeTimeout,
  })  : _channel = channel,
        _handshakeTimeout = handshakeTimeout {
    _subscription = _channel.messages.listen(
      _onMessage,
      onDone: _onChannelClosed,
      onError: (_) => _onChannelClosed(),
    );
  }

  final RealtimeChannel _channel;
  final Duration _handshakeTimeout;

  @override
  final String subscriptionId;

  final StreamController<LiveCalculation> _calculations =
      StreamController<LiveCalculation>.broadcast(sync: true);
  final Completer<void> _done = Completer<void>();

  Completer<void>? _connectionAckCompleter;
  Completer<void>? _subscribeAckCompleter;
  StreamSubscription<String>? _subscription;
  Timer? _watchdogTimer;

  _HandshakePhase _phase = _HandshakePhase.waitingConnectionAck;
  Duration _keepAliveTimeout = const Duration(
    milliseconds: LiveHistoryConstants.defaultKeepAliveTimeoutMs,
  );
  int _ignoredCount = 0;
  bool _subscribed = false;
  bool _closed = false;

  @override
  Stream<LiveCalculation> get calculations => _calculations.stream;

  @override
  Future<void> get done => _done.future;

  @override
  int get ignoredCount => _ignoredCount;

  @override
  Duration get keepAliveTimeout => _keepAliveTimeout;

  Future<void> performHandshake({
    required String httpDomain,
    required String idToken,
    required String sub,
  }) async {
    final connectionAck = Completer<void>();
    _connectionAckCompleter = connectionAck;
    try {
      _channel.send(jsonEncode({'type': 'connection_init'}));
    } catch (_) {
      throw const AppSyncHandshakeException.transient();
    }
    try {
      await connectionAck.future.timeout(_handshakeTimeout);
    } on TimeoutException {
      throw const AppSyncHandshakeException.transient();
    }

    _phase = _HandshakePhase.waitingSubscribeSuccess;
    final subscribeAck = Completer<void>();
    _subscribeAckCompleter = subscribeAck;
    try {
      _channel.send(
        jsonEncode({
          'type': 'subscribe',
          'id': subscriptionId,
          'channel': '${LiveHistoryConstants.historyChannelPrefix}$sub',
          'authorization': {
            'host': httpDomain,
            'Authorization': idToken,
          },
        }),
      );
    } catch (_) {
      throw const AppSyncHandshakeException.transient();
    }
    try {
      await subscribeAck.future.timeout(_handshakeTimeout);
    } on TimeoutException {
      throw const AppSyncHandshakeException.transient();
    }

    _phase = _HandshakePhase.live;
    _subscribed = true;
    _resetWatchdog();
  }

  void _onMessage(String text) {
    if (_closed) return;
    if (utf8.encode(text).length > LiveHistoryConstants.maxFrameBytes) {
      _ignoredCount++;
      return;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      _ignoredCount++;
      return;
    }
    if (decoded is! Map) {
      _ignoredCount++;
      return;
    }
    final map = Map<String, Object?>.from(decoded);
    final type = map['type']?.toString();

    switch (_phase) {
      case _HandshakePhase.waitingConnectionAck:
        _handleConnectionAckPhase(type, map);
      case _HandshakePhase.waitingSubscribeSuccess:
        _handleSubscribePhase(type, map);
      case _HandshakePhase.live:
        _handleLivePhase(type, map);
    }
  }

  void _handleConnectionAckPhase(String? type, Map<String, Object?> map) {
    if (type == 'connection_ack') {
      _keepAliveTimeout = AppSyncEventsClient.clampKeepAliveTimeout(
        map['connectionTimeoutMs'],
      );
      final completer = _connectionAckCompleter;
      if (completer != null && !completer.isCompleted) {
        completer.complete();
      }
      return;
    }
    if (type == 'connection_error' || type == 'error') {
      _failHandshake(_classifyError(map));
      return;
    }
    if (type == 'ka') return;
    _ignoredCount++;
  }

  void _handleSubscribePhase(String? type, Map<String, Object?> map) {
    if (type == 'subscribe_success') {
      final id = map['id']?.toString();
      if (id == null || id == subscriptionId) {
        final completer = _subscribeAckCompleter;
        if (completer != null && !completer.isCompleted) {
          completer.complete();
        }
        return;
      }
      _ignoredCount++;
      return;
    }
    if (type == 'subscribe_error' ||
        type == 'connection_error' ||
        type == 'error') {
      _failHandshake(_classifyError(map));
      return;
    }
    if (type == 'ka') return;
    _ignoredCount++;
  }

  void _handleLivePhase(String? type, Map<String, Object?> map) {
    if (type == 'ka') {
      _resetWatchdog();
      return;
    }
    if (type == 'data') {
      _resetWatchdog();
      _handleDataFrame(map);
      return;
    }
    _ignoredCount++;
  }

  void _handleDataFrame(Map<String, Object?> map) {
    final rawEvent = map['event'];
    Map<String, Object?>? eventMap;
    if (rawEvent is String) {
      try {
        final parsed = jsonDecode(rawEvent);
        if (parsed is Map) {
          eventMap = Map<String, Object?>.from(parsed);
        }
      } on FormatException {
        _ignoredCount++;
        return;
      }
    } else if (rawEvent is Map) {
      eventMap = Map<String, Object?>.from(rawEvent);
    }
    if (eventMap == null) {
      _ignoredCount++;
      return;
    }
    final calculation = LiveCalculation.fromJson(eventMap);
    if (calculation == null) {
      _ignoredCount++;
      return;
    }
    if (!_calculations.isClosed) {
      _calculations.add(calculation);
    }
  }

  void _resetWatchdog() {
    _watchdogTimer?.cancel();
    if (_closed || !_subscribed) return;
    _watchdogTimer = Timer(_keepAliveTimeout, _onWatchdogExpired);
  }

  void _onWatchdogExpired() {
    if (_closed) return;
    _subscribed = false;
    unawaited(close());
  }

  void _onChannelClosed() {
    if (_closed) return;
    _closed = true;
    _subscribed = false;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _failHandshake(const AppSyncHandshakeException.transient());
    unawaited(_calculations.close());
    if (!_done.isCompleted) _done.complete();
  }

  void _failHandshake(AppSyncHandshakeException exception) {
    final conn = _connectionAckCompleter;
    if (conn != null && !conn.isCompleted) {
      conn.completeError(exception);
    }
    final sub = _subscribeAckCompleter;
    if (sub != null && !sub.isCompleted) {
      sub.completeError(exception);
    }
  }

  static AppSyncHandshakeException _classifyError(Map<String, Object?> map) {
    final text = jsonEncode(map).toLowerCase();
    if (text.contains('unauthorized') ||
        text.contains('401') ||
        text.contains('403') ||
        text.contains('forbidden')) {
      return const AppSyncHandshakeException.authRejected();
    }
    return const AppSyncHandshakeException.transient();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    if (_subscribed) {
      _subscribed = false;
      try {
        _channel.send(
          jsonEncode({
            'type': 'unsubscribe',
            'id': subscriptionId,
          }),
        );
      } catch (_) {
        // Socket is already closed; nothing else to send.
      }
    }
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(_channel.close());
    unawaited(_calculations.close());
    if (!_done.isCompleted) _done.complete();
  }

  @override
  String toString() => 'AppSyncEventsSession(subscribed: $_subscribed)';
}
