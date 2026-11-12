import 'package:flutter/foundation.dart';

import 'ai_calculator_client.dart';
import 'ai_constants.dart';
import 'ai_errors.dart';
import 'ai_models.dart';

/// Controller managing user input, calculation state, and metrics for the AI Assistant tab.
class AiAssistantController extends ChangeNotifier {
  AiAssistantController({
    required AiCalculatorClient client,
    Stopwatch Function() stopwatchFactory = Stopwatch.new,
  })  : _client = client,
        _stopwatchFactory = stopwatchFactory;

  final AiCalculatorClient _client;
  final Stopwatch Function() _stopwatchFactory;

  String _sentence = '';
  AiMode _mode = AiMode.tool;
  bool _isLoading = false;
  AiCalculateResponse? _response;
  String? _errorMessage;
  int? _responseMs;
  String? _requestId;

  String get sentence => _sentence;
  AiMode get mode => _mode;
  bool get isLoading => _isLoading;
  AiCalculateResponse? get response => _response;
  String? get errorMessage => _errorMessage;
  int? get responseMs => _responseMs;
  String? get requestId => _requestId;

  /// True when the current sentence meets validation requirements and no request is in-flight.
  bool get canSubmit =>
      _sentence.trim().isNotEmpty &&
      _sentence.length <= AiConstants.maxSentenceLength &&
      !_isLoading;

  /// Updates the natural language query prompt.
  void setSentence(String value) {
    if (_sentence == value) return;
    _sentence = value;
    _clearOutcome();
    notifyListeners();
  }

  /// Updates the calculation mode (`tool` or `model`).
  void setMode(AiMode value) {
    if (_mode == value) return;
    _mode = value;
    _clearOutcome();
    notifyListeners();
  }

  /// Clears previous output, errors, and timing metrics when input is modified.
  void _clearOutcome() {
    _response = null;
    _errorMessage = null;
    _responseMs = null;
    _requestId = null;
  }

  /// Submits the prompt to the AI calculator client.
  Future<void> submit() async {
    if (!canSubmit) return;

    _isLoading = true;
    _clearOutcome();
    notifyListeners();

    final stopwatch = _stopwatchFactory()..start();

    try {
      final req = AiCalculateRequest(
        sentence: _sentence.trim(),
        mode: _mode,
      );
      final res = await _client.calculate(req);
      _response = res;
      _requestId = res.requestId;
    } on AiException catch (e) {
      _errorMessage = e.message;
      _requestId = e.requestId;
    } catch (e) {
      _errorMessage = e.toString();
    } finally {
      stopwatch.stop();
      _responseMs = stopwatch.elapsedMilliseconds;
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Resets controller state to blank initial defaults.
  void reset() {
    _sentence = '';
    _mode = AiConstants.defaultMode;
    _isLoading = false;
    _clearOutcome();
    notifyListeners();
  }
}
