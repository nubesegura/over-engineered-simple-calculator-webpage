import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'api_address.dart';
import 'api_client.dart';
import 'auth/auth_api.dart';
import 'auth/login_page.dart';
import 'auth/session_controller.dart';
import 'constants.dart';

void main() {
  runApp(const CalculatorApp());
}

class CalculatorApp extends StatefulWidget {
  /// [httpClient], [session] and [loginSupported] are only injected by tests.
  const CalculatorApp({
    super.key,
    this.httpClient,
    this.session,
    this.loginSupported = kIsWeb,
    this.apiBaseUrl,
    this.stopwatchFactory,
  });

  /// Stopwatch factory for the response time; only injected by tests.
  final Stopwatch Function()? stopwatchFactory;

  /// Client for the calculator backends.
  final http.Client? httpClient;

  /// API address; derived from the page host when null.
  final String? apiBaseUrl;
  final SessionController? session;

  /// False outside the web build: there is no same-origin BFF or cookie jar.
  final bool loginSupported;

  @override
  State<CalculatorApp> createState() => _CalculatorAppState();
}

class _CalculatorAppState extends State<CalculatorApp> {
  late final SessionController _session =
      widget.session ?? SessionController(HttpAuthApi());

  @override
  void initState() {
    super.initState();
    if (widget.loginSupported) unawaited(_session.restore());
  }

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Over-Engineered Calculator',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: widget.loginSupported
          ? ListenableBuilder(
              listenable: _session,
              builder: (context, _) => _gate(),
            )
          : const WebOnlyPage(),
    );
  }

  Widget _gate() {
    switch (_session.state) {
      case SessionState.restoring:
        return const Scaffold(
          body: Center(
            child: CircularProgressIndicator(key: Key('session-loading')),
          ),
        );
      case SessionState.unauthenticated:
      case SessionState.expired:
        return LoginPage(session: _session);
      case SessionState.authenticated:
        return CalculatorHomePage(
          session: _session,
          httpClient: widget.httpClient,
          stopwatchFactory: widget.stopwatchFactory ?? Stopwatch.new,
          apiBaseUrl: widget.apiBaseUrl ?? deriveApiBaseUrl(),
        );
    }
  }
}

class CalculatorHomePage extends StatefulWidget {
  const CalculatorHomePage({
    super.key,
    required this.session,
    required this.apiBaseUrl,
    this.httpClient,
    this.stopwatchFactory = Stopwatch.new,
  });

  /// Creates the monotonic stopwatch of one calculation; tests inject a fake.
  final Stopwatch Function() stopwatchFactory;
  final SessionController session;
  final http.Client? httpClient;

  /// Read-only API address; empty when the page host has none.
  final String apiBaseUrl;

  @override
  State<CalculatorHomePage> createState() => _CalculatorHomePageState();
}

class _CalculatorHomePageState extends State<CalculatorHomePage> {
  final TextEditingController _controllerA = TextEditingController();
  final TextEditingController _controllerB = TextEditingController();
  String _result = '0';
  String? _backend;
  int? _responseMs;

  /// Bumped whenever the shown outcome is reset, to drop late time updates.
  int _generation = 0;
  bool _isLoading = false;
  String _selectedOperation = ApiConstants.defaultOperation;

  final List<HistoryItem> _history = [];
  String? _historyCursor;
  bool _historyLoading = false;
  bool _historyLoaded = false;
  String? _historyError;
  Timer? _historyRefreshTimer;

  @override
  void dispose() {
    _historyRefreshTimer?.cancel();
    _controllerA.dispose();
    _controllerB.dispose();
    super.dispose();
  }

  CalculatorApiClient _client() => CalculatorApiClient(
        baseUrl: widget.apiBaseUrl,
        tokens: widget.session,
        httpClient: widget.httpClient,
      );

  /// Why requests cannot be sent, or null when the address is usable.
  String? _addressProblem(CalculatorApiClient client) {
    if (widget.apiBaseUrl.isEmpty) return ApiConstants.noApiAddressMessage;
    if (!client.hasValidBaseUrl) return ApiConstants.invalidApiAddressMessage;
    if (!client.hasTrustedBaseUrl) return untrustedUrlMessage;
    return null;
  }

  Future<void> _calculate() async {
    if (_controllerA.text.isEmpty || _controllerB.text.isEmpty) return;

    final client = _client();
    final problem = _addressProblem(client);
    if (problem != null) {
      setState(() => _result = problem);
      return;
    }
    final a = double.tryParse(_controllerA.text);
    final b = double.tryParse(_controllerB.text);
    if (a == null || b == null) {
      setState(() => _result = 'Enter valid numbers.');
      return;
    }

    setState(() {
      _resetOutcome();
      _isLoading = true;
      _result = 'Calculating...';
    });

    final stopwatch = widget.stopwatchFactory()..start();
    try {
      final answer = await client.calculate(_selectedOperation, a, b);
      if (!mounted) return;
      setState(() {
        _result = answer.result;
        _backend = answer.backend;
      });
      _stopAfterFrame(stopwatch);
      _scheduleHistoryRefresh();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _result = 'Error: ${e.message}');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Stops [stopwatch] once the frame that shows the result has been drawn and
  /// shows the elapsed milliseconds (unless a newer action reset the page).
  void _stopAfterFrame(Stopwatch stopwatch) {
    final generation = _generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      stopwatch.stop();
      if (!mounted || generation != _generation) return;
      setState(() => _responseMs = stopwatch.elapsedMilliseconds);
    });
  }

  /// Back to the initial result; the backend and the time are hidden.
  void _resetOutcome() {
    _generation++;
    _result = '0';
    _backend = null;
    _responseMs = null;
  }

  /// The history is eventually consistent: wait a moment before reloading it. Only
  /// done when the user already opened the history, to avoid extra API calls.
  void _scheduleHistoryRefresh() {
    if (!_historyLoaded) return;
    _historyRefreshTimer?.cancel();
    _historyRefreshTimer = Timer(ApiConstants.historyRefreshDelay, () {
      if (mounted) _loadHistory();
    });
  }

  /// Loads the first page (replacing the list) or, with [more], the next one.
  Future<void> _loadHistory({bool more = false}) async {
    final client = _client();
    final problem = _addressProblem(client);
    if (problem != null) {
      setState(() => _historyError = problem);
      return;
    }
    setState(() {
      _historyLoading = true;
      _historyError = null;
    });
    try {
      final page =
          await client.fetchHistory(cursor: more ? _historyCursor : null);
      if (!mounted) return;
      setState(() {
        if (!more) _history.clear();
        _history.addAll(page.items);
        _historyCursor = page.nextCursor;
        _historyLoaded = true;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _historyError = e.statusCode == 404
            ? 'This service does not provide a history.'
            : e.message;
      });
    } finally {
      if (mounted) setState(() => _historyLoading = false);
    }
  }

  Widget _buildOpButton(String op, String symbol) {
    final isSelected = _selectedOperation == op;
    final label = Text(
      symbol,
      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
    );
    void select() => setState(() {
          _selectedOperation = op;
          _resetOutcome();
        });
    return isSelected
        ? FilledButton(onPressed: select, child: label)
        : OutlinedButton(onPressed: select, child: label);
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _formatTime(DateTime? time) {
    if (time == null) return '';
    final t = time.toLocal();
    return '${t.year}-${_two(t.month)}-${_two(t.day)} '
        '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
  }

  Widget _buildHistory(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final Widget body;
    if (_historyError != null) {
      body = Text(_historyError!,
          style: TextStyle(color: Theme.of(context).colorScheme.error));
    } else if (!_historyLoaded) {
      body = Text(
        _historyLoading
            ? 'Loading...'
            : 'Press refresh to load your calculations.',
      );
    } else if (_history.isEmpty) {
      body = const Text('No calculations yet.');
    } else {
      body = Column(
        children: [
          for (final item in _history)
            ListTile(
              key: Key('history-${item.id}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(
                '${item.a} ${ApiConstants.operations[item.operation] ?? item.operation} '
                '${item.b} = ${item.result}',
                style: const TextStyle(fontSize: 18),
              ),
              subtitle: Text(_formatTime(item.occurredAt)),
            ),
          if (_historyCursor != null)
            TextButton(
              onPressed:
                  _historyLoading ? null : () => _loadHistory(more: true),
              child: const Text('Load more'),
            ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text('History', style: textTheme.titleLarge)),
            if (_historyLoading)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            IconButton(
              key: const Key('history-refresh'),
              tooltip: 'Refresh history',
              icon: const Icon(Icons.refresh),
              onPressed: _historyLoading ? null : () => _loadHistory(),
            ),
          ],
        ),
        body,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Over-Engineered Calculator',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w500)),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
        actions: [
          IconButton(
            key: const Key('logout-button'),
            tooltip: 'Log out',
            icon: const Icon(Icons.logout),
            onPressed: widget.session.logout,
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                InputDecorator(
                  decoration: const InputDecoration(labelText: 'Service URL'),
                  child: SelectableText(
                    widget.apiBaseUrl.isEmpty
                        ? ApiConstants.noApiAddressMessage
                        : widget.apiBaseUrl,
                    key: const Key('service-url-label'),
                  ),
                ),
                const SizedBox(height: 32),
                TextField(
                  key: const Key('first-number-field'),
                  controller: _controllerA,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(fontSize: 22),
                  decoration: const InputDecoration(
                    labelText: 'First Number',
                    labelStyle: TextStyle(fontSize: 22),
                  ),
                  onChanged: (_) => setState(_resetOutcome),
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('second-number-field'),
                  controller: _controllerB,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(fontSize: 22),
                  decoration: const InputDecoration(
                    labelText: 'Second Number',
                    labelStyle: TextStyle(fontSize: 22),
                  ),
                  onChanged: (_) => setState(_resetOutcome),
                ),
                const SizedBox(height: 32),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (final entry in ApiConstants.operations.entries)
                      _buildOpButton(entry.key, entry.value),
                  ],
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _isLoading ? null : _calculate,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(50),
                  ),
                  child:
                      const Text('Calculate', style: TextStyle(fontSize: 22)),
                ),
                const SizedBox(height: 32),
                Text(
                  'Result: $_result',
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.bold),
                ),
                if (_backend != null) Text('Backend: $_backend'),
                if (_responseMs != null) Text('Response time: $_responseMs ms'),
                const SizedBox(height: 24),
                const Divider(),
                _buildHistory(context),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
