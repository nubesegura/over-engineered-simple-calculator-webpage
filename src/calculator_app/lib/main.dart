import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'api_client.dart';
import 'constants.dart';

void main() {
  runApp(const CalculatorApp());
}

class CalculatorApp extends StatelessWidget {
  /// [httpClient] is only injected by tests.
  const CalculatorApp({super.key, this.httpClient});

  final http.Client? httpClient;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Over-Engineered Calculator',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: CalculatorHomePage(httpClient: httpClient),
    );
  }
}

class CalculatorHomePage extends StatefulWidget {
  const CalculatorHomePage({super.key, this.httpClient});

  final http.Client? httpClient;

  @override
  State<CalculatorHomePage> createState() => _CalculatorHomePageState();
}

class _CalculatorHomePageState extends State<CalculatorHomePage> {
  final TextEditingController _controllerA = TextEditingController();
  final TextEditingController _controllerB = TextEditingController();
  final TextEditingController _controllerUrl =
      TextEditingController(text: ApiConstants.defaultApiBaseUrl);
  final TextEditingController _controllerApiKey = TextEditingController();
  String _result = '0';
  bool _isLoading = false;
  bool _obscureApiKey = true;
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
    _controllerUrl.dispose();
    _controllerApiKey.dispose();
    super.dispose();
  }

  CalculatorApiClient _client() => CalculatorApiClient(
        baseUrl: _controllerUrl.text,
        apiKey: _controllerApiKey.text,
        httpClient: widget.httpClient,
      );

  Future<void> _calculate() async {
    if (_controllerA.text.isEmpty || _controllerB.text.isEmpty) return;

    final client = _client();
    if (!client.hasValidBaseUrl) {
      setState(() => _result = 'Enter a valid Service URL (http:// or https://).');
      return;
    }
    final a = double.tryParse(_controllerA.text);
    final b = double.tryParse(_controllerB.text);
    if (a == null || b == null) {
      setState(() => _result = 'Enter valid numbers.');
      return;
    }

    setState(() {
      _isLoading = true;
      _result = 'Calculating...';
    });

    try {
      final result = await client.calculate(_selectedOperation, a, b);
      if (!mounted) return;
      setState(() => _result = result);
      _scheduleHistoryRefresh();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _result = 'Error: ${e.message}');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
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
    if (!client.hasValidBaseUrl) {
      setState(() => _historyError = 'Enter a valid Service URL (http:// or https://).');
      return;
    }
    setState(() {
      _historyLoading = true;
      _historyError = null;
    });
    try {
      final page = await client.fetchHistory(cursor: more ? _historyCursor : null);
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
          _result = '0';
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
        _historyLoading ? 'Loading...' : 'Press refresh to load your calculations.',
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
              onPressed: _historyLoading ? null : () => _loadHistory(more: true),
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
        title: const Text('Over-Engineered Calculator', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w500)),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextField(
                  key: const Key('service-url-field'),
                  controller: _controllerUrl,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Service URL',
                    hintText: 'https://api.example.com/api/sls/v1',
                  ),
                  onChanged: (_) => setState(() => _result = '0'),
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('api-key-field'),
                  controller: _controllerApiKey,
                  obscureText: _obscureApiKey,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'API Key',
                    hintText: 'Optional (required by the sls backend)',
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureApiKey ? Icons.visibility : Icons.visibility_off,
                      ),
                      onPressed: () {
                        setState(() {
                          _obscureApiKey = !_obscureApiKey;
                        });
                      },
                    ),
                  ),
                  onChanged: (_) => setState(() => _result = '0'),
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
                  onChanged: (_) => setState(() => _result = '0'),
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
                  onChanged: (_) => setState(() => _result = '0'),
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
                  child: const Text('Calculate', style: TextStyle(fontSize: 22)),
                ),
                const SizedBox(height: 32),
                Text(
                  'Result: $_result',
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
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
