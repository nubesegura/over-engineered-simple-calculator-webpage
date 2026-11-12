import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../auth/auth_api.dart';
import '../auth/token_source.dart';
import '../constants.dart';
import 'realtime_address.dart';
import 'realtime_calculator_client.dart';
import 'realtime_channel.dart';
import 'realtime_constants.dart';
import 'realtime_status.dart';
import 'web_socket_realtime_channel.dart';

/// State of the real-time mode: the connection, its token, reconnection,
/// rotation and keepalive. Reads the session only through [TokenSource] and
/// uses the ID token only in the address of a new connection.
///
/// The page calls [activate] when Real-time is selected, [deactivate] when it
/// is left and on logout, and [setTabVisible] when the tab is shown or hidden.
class RealtimeController extends ChangeNotifier {
  RealtimeController({
    required TokenSource tokens,
    required RealtimeAddress address,
    RealtimeChannelFactory? channels,
    RealtimeCalculatorClient? client,
    Random? random,
    bool tabVisible = true,
  })  : _tokens = tokens,
        _address = address,
        _channels = channels ?? WebSocketRealtimeChannelFactory(),
        _client = client ?? RealtimeCalculatorClient(),
        _random = random ?? Random(),
        _tabVisible = tabVisible;

  final TokenSource _tokens;
  final RealtimeAddress _address;
  final RealtimeChannelFactory _channels;
  final RealtimeCalculatorClient _client;
  final Random _random;

  RealtimeStatus _status = RealtimeStatus.disconnected;
  bool _active = false;
  bool _disposed = false;
  bool _tabVisible;
  bool _waitingForDemand = false;
  bool _rotationDue = false;
  bool _established = false;
  int _cycle = 0;
  int _failures = 0;

  RealtimeChannel? _channel;
  StreamSubscription<String>? _subscription;
  Timer? _reconnectTimer;
  Timer? _rotationTimer;
  Timer? _pingTimer;
  Timer? _stableTimer;

  RealtimeStatus get status => _status;

  /// True while Real-time mode is selected.
  bool get isActive => _active;

  /// True while a calculation waits for its answer.
  bool get isBusy => _client.isBusy;

  /// The wait before reconnection [attempt] (1 to 5): 1 s, 2 s, 4 s ... capped
  /// at 30 s, lengthened by up to 25 percent by [jitter] (0 to 1).
  static Duration reconnectDelay(int attempt, double jitter) {
    final baseMs = RealtimeConstants.backoffBase.inMilliseconds *
        (1 << min(attempt - 1, 20));
    final withJitter = baseMs * (1 + RealtimeConstants.backoffJitter * jitter);
    return Duration(
      milliseconds:
          min(withJitter.round(), RealtimeConstants.backoffCap.inMilliseconds),
    );
  }

  /// Real-time was selected: connect, unless the address cannot be used.
  Future<void> activate() {
    if (_active) return Future.value();
    _active = true;
    _established = false;
    _failures = 0;
    final problem = _address.problemMessage;
    if (problem != null) {
      _setStatus(RealtimeStatus.notConfigured(problem));
      return Future.value();
    }
    return _connect();
  }

  /// Real-time was left, the user logged out or the page is closing: close the
  /// socket (code 1000), cancel timers and drop the pending request.
  void deactivate() {
    _active = false;
    _client.discardPending();
    _stop();
    _setStatus(RealtimeStatus.disconnected);
  }

  /// Manual reconnect after "Disconnected" or "Not authorized".
  Future<void> reconnect() {
    if (!_active || !_address.isUsable) return Future.value();
    _stop();
    _failures = 0;
    return _connect();
  }

  /// The tab was shown or hidden. A hidden tab sends no keepalive; a shown tab
  /// reconnects a connection that the idle limit closed meanwhile.
  void setTabVisible(bool visible) {
    _tabVisible = visible;
    if (visible && _active && _waitingForDemand) {
      unawaited(_reconnectOnDemand());
    }
    _syncPing();
  }

  /// Sends one calculation when connected; otherwise sends nothing.
  Future<CalculationOutcome> calculate({
    required String operation,
    required String a,
    required String b,
  }) async {
    if (!_active || _channel == null) {
      if (_active && _waitingForDemand) unawaited(_reconnectOnDemand());
      return const CalculationFailure(
        RealtimeConstants.notConnectedMessage,
        FailureKind.notConnected,
      );
    }
    final answer = _client.calculate(operation: operation, a: a, b: b);
    _notify();
    final outcome = await answer;
    _notify();
    _afterCalculation(outcome);
    return outcome;
  }

  /// The inputs changed: the answer of the pending request is not wanted.
  void discardPending() {
    _client.discardPending();
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _active = false;
    _client.discardPending();
    _stop();
    super.dispose();
  }

  @override
  String toString() => 'RealtimeController(${_status.label})';

  // Connection ---------------------------------------------------------------

  /// A browser cannot tell a refused upgrade from an unreachable network. A
  /// refusal is only believed on the first connection of a session; after an
  /// established connection or a failed attempt it is treated as a drop
  /// (requirement 2.4), without renewing the session.
  bool get _refusalIsDrop => _failures > 0 || _established;

  /// Opens a connection. When [rotating], the old connection stays open and in
  /// use until the new one is ready, and the status does not change.
  Future<void> _connect({bool rotating = false}) async {
    _reconnectTimer?.cancel();
    final cycle = ++_cycle;
    if (!rotating) {
      _setStatus(
        _failures == 0
            ? RealtimeStatus.connecting
            : RealtimeStatus.reconnecting(_failures),
      );
    }
    try {
      var token = await _tokens.validIdToken();
      if (cycle != _cycle) return;
      try {
        await _open(token, cycle);
      } on RealtimeChannelException catch (e) {
        if (e.failure != RealtimeFailure.refused ||
            _refusalIsDrop ||
            cycle != _cycle) {
          rethrow;
        }
        token = await _tokens.renewAfterRejection(token);
        if (cycle != _cycle) return;
        await _open(token, cycle);
      }
    } on RealtimeChannelException catch (e) {
      if (cycle != _cycle) return;
      if (e.failure == RealtimeFailure.refused && !_refusalIsDrop) {
        _onNotAuthorized();
      } else {
        _failConnect(rotating);
      }
    } on AuthApiException catch (e) {
      if (cycle != _cycle) return;
      if (e.statusCode == 401) {
        _onSessionEnded();
      } else {
        _failConnect(rotating);
      }
    } catch (_) {
      if (cycle != _cycle) return;
      _failConnect(rotating);
    }
  }

  /// The attempt failed for a reason that backoff can cure. A failed rotation
  /// gives up the old connection and goes through the normal backoff.
  void _failConnect(bool rotating) {
    if (rotating) {
      _stop();
      _failures = 0;
    }
    _scheduleReconnect();
  }

  Future<void> _open(String token, int cycle) async {
    final channel = await _channels.connect(_address.connectionUri(token));
    if (cycle != _cycle) {
      unawaited(channel.close());
      return;
    }
    if (_channel != null) _releaseChannel();
    _established = true;
    _channel = channel;
    _subscription = channel.messages.listen(
      _client.handleMessage,
      onDone: () => _onClosed(channel),
      onError: (Object _) => _onClosed(channel),
    );
    _client.attach(channel);
    _waitingForDemand = false;
    _rotationTimer = Timer(RealtimeConstants.rotationInterval, _onRotationDue);
    _stableTimer = Timer(RealtimeConstants.stableConnection, () {
      _failures = 0;
    });
    _setStatus(RealtimeStatus.connected);
    _syncPing();
  }

  void _onClosed(RealtimeChannel channel) {
    if (!identical(channel, _channel)) return;
    _releaseChannel();
    if (!_active) return;
    if (!_tabVisible && !_client.isBusy) {
      _waitingForDemand = true;
      _setStatus(RealtimeStatus.disconnected);
      return;
    }
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _failures++;
    if (_failures > RealtimeConstants.maxReconnectAttempts) {
      _client.failPending(_notConnected());
      _setStatus(RealtimeStatus.disconnected);
      return;
    }
    _setStatus(RealtimeStatus.reconnecting(_failures));
    _reconnectTimer = Timer(
      reconnectDelay(_failures, _random.nextDouble()),
      () => unawaited(_connect()),
    );
  }

  Future<void> _reconnectOnDemand() {
    _waitingForDemand = false;
    _failures = 0;
    return _connect();
  }

  void _onNotAuthorized() {
    _setStatus(RealtimeStatus.notAuthorized);
  }

  void _onSessionEnded() {
    _active = false;
    _client.failPending(const CalculationFailure(
      AuthConstants.sessionExpiredMessage,
      FailureKind.sessionExpired,
    ));
    _stop();
    _setStatus(RealtimeStatus.disconnected);
  }

  void _afterCalculation(CalculationOutcome outcome) {
    if (!_active || _channel == null) return;
    if (outcome is CalculationFailure &&
        outcome.kind == FailureKind.unauthorized) {
      _releaseChannel();
      _scheduleReconnect();
    } else if (_rotationDue && !_client.isBusy) {
      _rotate();
    }
  }

  // Rotation and keepalive ---------------------------------------------------

  void _onRotationDue() {
    _rotationTimer = null;
    if (_client.isBusy) {
      _rotationDue = true;
    } else {
      _rotate();
    }
  }

  void _rotate() {
    _rotationDue = false;
    _failures = 0;
    unawaited(_connect(rotating: true));
  }

  void _syncPing() {
    _pingTimer?.cancel();
    _pingTimer = null;
    if (_active && _tabVisible && _channel != null) {
      _pingTimer =
          Timer.periodic(RealtimeConstants.pingInterval, (_) => _ping());
    }
  }

  void _ping() {
    final channel = _channel;
    if (channel == null || _client.isBusy) return;
    try {
      channel.send(RealtimeConstants.pingMessage);
    } catch (_) {
      // The close notification of the connection takes it from here.
    }
  }

  // Cleanup ------------------------------------------------------------------

  /// Closes the connection and cancels every timer; keeps a pending request.
  void _stop() {
    _cycle++;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _waitingForDemand = false;
    _releaseChannel();
  }

  /// Forgets the connection: timers of an open connection, the subscription,
  /// and the socket itself (closed with code 1000).
  void _releaseChannel() {
    _rotationTimer?.cancel();
    _rotationTimer = null;
    _rotationDue = false;
    _stableTimer?.cancel();
    _stableTimer = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    final channel = _channel;
    _channel = null;
    if (channel != null) unawaited(channel.close());
    _client.detach();
  }

  CalculationFailure _notConnected() => const CalculationFailure(
        RealtimeConstants.notConnectedMessage,
        FailureKind.notConnected,
      );

  void _setStatus(RealtimeStatus status) {
    if (status == _status) return;
    _status = status;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}
