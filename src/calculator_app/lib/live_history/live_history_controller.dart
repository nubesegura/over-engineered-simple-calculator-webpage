import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../auth/auth_api.dart';
import '../auth/token_source.dart';
import '../realtime/realtime_channel.dart';
import 'appsync_events_client.dart';
import 'graphql_history_client.dart';
import 'jwt_sub.dart';
import 'live_calculation.dart';
import 'live_history_config.dart';
import 'live_history_constants.dart';
import 'live_history_status.dart';

/// Coordinates the 5-step live calculation history lifecycle:
/// 1. Subscribe to `/history/<sub>` over AppSync Events first.
/// 2. Fetch stored history via `Query.history(limit: 20)`.
/// 3. Deduplicate calculations in memory by `txId`.
/// 4. Sort newest first by `createdAt` descending.
/// 5. Re-query `Query.history(limit: 20)` upon every successful reconnect.
class LiveHistoryController extends ChangeNotifier {
  LiveHistoryController({
    required LiveHistoryConfig config,
    required TokenSource tokens,
    HistoryStoreClient? historyClient,
    AppSyncEventsConnector? eventsClient,
    RealtimeChannelFactory? channels,
    http.Client? httpClient,
    JwtSubExtractor subExtractor = extractJwtSub,
    Random? random,
  })  : _config = config,
        _tokens = tokens,
        _historyClient = historyClient ??
            (config.isValid
                ? GraphQlHistoryClient(
                    graphQlUri: config.graphQlUri,
                    tokens: tokens,
                    httpClient: httpClient,
                  )
                : null),
        _eventsClient = eventsClient ?? AppSyncEventsClient(channels: channels),
        _subExtractor = subExtractor,
        _random = random ?? Random();

  final LiveHistoryConfig _config;
  final TokenSource _tokens;
  final HistoryStoreClient? _historyClient;
  final AppSyncEventsConnector _eventsClient;
  final JwtSubExtractor _subExtractor;
  final Random _random;

  final Map<String, LiveCalculation> _byTxId = <String, LiveCalculation>{};
  List<LiveCalculation> _sortedItems = const <LiveCalculation>[];

  LiveHistoryStatus _status = LiveHistoryStatus.notConfigured;
  String? _nextCursor;
  String? _errorMessage;
  bool _isLoading = false;
  bool _hasLoadedInitial = false;
  bool _started = false;
  bool _disposed = false;
  bool _established = false;
  int _cycle = 0;
  int _failures = 0;

  AppSyncEventsSession? _session;
  StreamSubscription<LiveCalculation>? _calculationSub;
  Timer? _reconnectTimer;
  Timer? _stableTimer;

  LiveHistoryConfig get config => _config;
  LiveHistoryStatus get status => _status;
  List<LiveCalculation> get items => _sortedItems;
  String? get nextCursor => _nextCursor;
  bool get hasMore => _nextCursor != null;
  String? get errorMessage => _errorMessage;
  bool get isLoading => _isLoading;
  bool get hasLoadedInitial => _hasLoadedInitial;
  int get ignoredCount => _session?.ignoredCount ?? 0;

  /// Exponential backoff before reconnection [attempt] (`1..5`):
  /// 1 s, 2 s, 4 s, 8 s, 16 s capped at 30 s, plus up to 25% [jitter] (`0..1`).
  static Duration reconnectDelay(int attempt, double jitter) {
    final baseMs = LiveHistoryConstants.backoffBase.inMilliseconds *
        (1 << min(attempt - 1, 20));
    final withJitter =
        baseMs * (1 + LiveHistoryConstants.backoffJitter * jitter);
    return Duration(
      milliseconds: min(
        withJitter.round(),
        LiveHistoryConstants.backoffCap.inMilliseconds,
      ),
    );
  }

  /// Starts the 5-step sequence when AppSync Live History is configured.
  Future<void> start() async {
    if (_disposed || _started) return;
    if (_config.state == LiveHistoryConfigState.notConfigured) {
      _setStatus(LiveHistoryStatus.notConfigured);
      return;
    }
    if (_config.state == LiveHistoryConfigState.invalid) {
      _started = true;
      _errorMessage = LiveHistoryConstants.invalidAddressMessage;
      _setStatus(LiveHistoryStatus.invalidAddress);
      return;
    }

    _started = true;
    _failures = 0;
    _established = false;

    // Step 1: Subscribe to /history/<sub> first.
    await _connectAndSubscribe(isInitial: true);

    // Step 2: Fetch stored history even if Step 1 had a transient failure.
    if (!_disposed && _started) {
      await _fetchPage(
        limit: LiveHistoryConstants.defaultPageLimit,
        replaceCursor: true,
      );
    }
  }

  /// Refreshes `Query.history(limit: 20)` and reconnects the live channel if it
  /// is currently `offline` or `notAuthorized`.
  Future<void> refresh() async {
    if (_disposed) return;
    if (_config.state == LiveHistoryConfigState.notConfigured) return;
    if (_config.state == LiveHistoryConfigState.invalid) {
      _errorMessage = LiveHistoryConstants.invalidAddressMessage;
      _setStatus(LiveHistoryStatus.invalidAddress);
      return;
    }

    _started = true;
    if (_status.canReconnect) {
      _stopChannelAndTimers();
      _failures = 0;
      _established = false;
      await _connectAndSubscribe(isInitial: true);
    }
    if (!_disposed && _started) {
      await _fetchPage(
        limit: LiveHistoryConstants.defaultPageLimit,
        replaceCursor: _nextCursor == null,
      );
    }
  }

  /// Fetches the next page of older calculations using [nextCursor].
  Future<void> loadMore() async {
    if (_disposed || !_config.isValid || _isLoading || _nextCursor == null) {
      return;
    }
    await _fetchPage(
      limit: LiveHistoryConstants.defaultPageLimit,
      nextToken: _nextCursor,
      replaceCursor: true,
    );
  }

  /// Unsubscribes, closes the WebSocket, cancels timers and clears the
  /// in-memory calculation map so another user never sees previous items.
  void resetForLogout() {
    _started = false;
    _established = false;
    _failures = 0;
    _stopChannelAndTimers();
    _byTxId.clear();
    _sortedItems = const <LiveCalculation>[];
    _nextCursor = null;
    _errorMessage = null;
    _isLoading = false;
    _hasLoadedInitial = false;
    _status = _config.isConfigured
        ? LiveHistoryStatus.offline
        : LiveHistoryStatus.notConfigured;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _started = false;
    _stopChannelAndTimers();
    final historyClient = _historyClient;
    if (historyClient is GraphQlHistoryClient) {
      historyClient.close();
    }
    _byTxId.clear();
    _sortedItems = const <LiveCalculation>[];
    _nextCursor = null;
    super.dispose();
  }

  @override
  String toString() =>
      'LiveHistoryController(${_status.label}, items: ${_sortedItems.length})';

  // Connection and 5-step sync internals ------------------------------------

  bool get _refusalIsDrop => _failures > 0 || _established;

  Future<void> _connectAndSubscribe({required bool isInitial}) async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final cycle = ++_cycle;
    _setStatus(
      _failures == 0
          ? LiveHistoryStatus.connecting
          : LiveHistoryStatus.reconnecting(_failures),
    );

    try {
      var token = await _tokens.validIdToken();
      if (cycle != _cycle || _disposed || !_started) return;
      var sub = _subExtractor(token);
      if (sub == null) {
        _setStatus(LiveHistoryStatus.notAuthorized);
        return;
      }

      AppSyncEventsSession session;
      try {
        session = await _eventsClient.subscribe(
          realtimeUri: _config.realtimeUri,
          httpDomain: _config.httpDomain,
          idToken: token,
          sub: sub,
        );
      } on AppSyncHandshakeException catch (e) {
        if (!e.isAuthRejected ||
            _refusalIsDrop ||
            cycle != _cycle ||
            _disposed ||
            !_started) {
          rethrow;
        }
        token = await _tokens.renewAfterRejection(token);
        if (cycle != _cycle || _disposed || !_started) return;
        sub = _subExtractor(token);
        if (sub == null) {
          _setStatus(LiveHistoryStatus.notAuthorized);
          return;
        }
        session = await _eventsClient.subscribe(
          realtimeUri: _config.realtimeUri,
          httpDomain: _config.httpDomain,
          idToken: token,
          sub: sub,
        );
      }

      if (cycle != _cycle || _disposed || !_started) {
        unawaited(session.close());
        return;
      }

      _attachSession(session, isReconnect: !isInitial);
    } on AppSyncHandshakeException catch (e) {
      if (cycle != _cycle || _disposed || !_started) return;
      if (e.isAuthRejected && !_refusalIsDrop) {
        _setStatus(LiveHistoryStatus.notAuthorized);
      } else {
        _scheduleReconnect();
      }
    } on AuthApiException catch (e) {
      if (cycle != _cycle || _disposed || !_started) return;
      if (e.statusCode == 401) {
        _onSessionExpired();
      } else {
        _scheduleReconnect();
      }
    } catch (_) {
      if (cycle != _cycle || _disposed || !_started) return;
      _scheduleReconnect();
    }
  }

  void _attachSession(
    AppSyncEventsSession session, {
    required bool isReconnect,
  }) {
    _releaseSession();
    _established = true;
    _session = session;
    _calculationSub = session.calculations.listen(_onLiveCalculation);
    unawaited(session.done.then((_) => _onSessionDone(session)));
    _stableTimer = Timer(LiveHistoryConstants.stableConnection, () {
      _failures = 0;
    });
    _setStatus(LiveHistoryStatus.live);

    // Step 5: Automatic gap recovery on every successful reconnection.
    if (isReconnect) {
      unawaited(
        _fetchPage(
          limit: LiveHistoryConstants.defaultPageLimit,
          replaceCursor: _nextCursor == null,
        ),
      );
    }
  }

  void _onLiveCalculation(LiveCalculation item) {
    if (_disposed || !_started) return;
    if (_byTxId.containsKey(item.txId)) return;
    _byTxId[item.txId] = item;
    _rebuildSortedItems();
    _notify();
  }

  void _onSessionDone(AppSyncEventsSession session) {
    if (!identical(session, _session)) return;
    _releaseSession();
    if (_disposed || !_started) return;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _failures++;
    if (_failures > LiveHistoryConstants.maxReconnectAttempts) {
      _setStatus(LiveHistoryStatus.offline);
      return;
    }
    _setStatus(LiveHistoryStatus.reconnecting(_failures));
    _reconnectTimer = Timer(
      reconnectDelay(_failures, _random.nextDouble()),
      () => unawaited(_connectAndSubscribe(isInitial: false)),
    );
  }

  Future<void> _fetchPage({
    required int limit,
    String? nextToken,
    required bool replaceCursor,
  }) async {
    final client = _historyClient;
    if (client == null || _disposed || !_started) return;

    _isLoading = true;
    _errorMessage = null;
    _notify();

    try {
      final page = await client.fetchHistory(
        limit: limit,
        nextToken: nextToken,
      );
      if (_disposed || !_started) return;
      for (final item in page.items) {
        _byTxId.putIfAbsent(item.txId, () => item);
      }
      if (replaceCursor || nextToken != null || _nextCursor == null) {
        _nextCursor = page.nextToken;
      }
      _hasLoadedInitial = true;
      _rebuildSortedItems();
    } on LiveHistoryAuthException catch (e) {
      if (_disposed) return;
      _errorMessage = e.message;
      _onSessionExpired();
    } on LiveHistoryException catch (e) {
      if (_disposed) return;
      _errorMessage = e.message;
    } catch (_) {
      if (_disposed) return;
      _errorMessage = LiveHistoryConstants.loadErrorMessage;
    } finally {
      if (!_disposed) {
        _isLoading = false;
        _notify();
      }
    }
  }

  void _rebuildSortedItems() {
    final sorted = _byTxId.values.toList()
      ..sort(LiveCalculation.compareNewestFirst);
    _sortedItems = List<LiveCalculation>.unmodifiable(sorted);
  }

  void _onSessionExpired() {
    _started = false;
    _stopChannelAndTimers();
    _setStatus(LiveHistoryStatus.notAuthorized);
  }

  void _stopChannelAndTimers() {
    _cycle++;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _releaseSession();
  }

  void _releaseSession() {
    _stableTimer?.cancel();
    _stableTimer = null;
    unawaited(_calculationSub?.cancel());
    _calculationSub = null;
    final session = _session;
    _session = null;
    if (session != null) {
      unawaited(session.close());
    }
  }

  void _setStatus(LiveHistoryStatus next) {
    if (_status == next) {
      _notify();
      return;
    }
    _status = next;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}
