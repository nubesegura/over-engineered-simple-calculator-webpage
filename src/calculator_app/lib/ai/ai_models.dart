import 'package:flutter/foundation.dart';

/// The calculation mode for the natural language assistant.
enum AiMode {
  /// Deterministic tool invocation (Bedrock AgentCore + MCP Lambda math tool).
  tool('tool', 'Tool-Assisted'),

  /// Direct LLM probabilistic reasoning using Amazon Nova 2 Lite weights.
  model('model', 'Direct Model');

  const AiMode(this.value, this.label);

  /// String value sent to and received from the backend ('tool' or 'model').
  final String value;

  /// User-friendly label displayed in the UI.
  final String label;

  /// Parses a string into an [AiMode], defaulting to [AiMode.tool] if unrecognized.
  static AiMode fromString(String value) {
    for (final mode in AiMode.values) {
      if (mode.value == value || mode.name == value) {
        return mode;
      }
    }
    return AiMode.tool;
  }
}

/// Request payload for `POST /calculate`.
@immutable
class AiCalculateRequest {
  const AiCalculateRequest({
    required this.sentence,
    this.mode = AiMode.tool,
  });

  final String sentence;
  final AiMode mode;

  Map<String, dynamic> toJson() => {
        'sentence': sentence,
        'mode': mode.value,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AiCalculateRequest &&
          runtimeType == other.runtimeType &&
          sentence == other.sentence &&
          mode == other.mode;

  @override
  int get hashCode => Object.hash(sentence, mode);

  @override
  String toString() => 'AiCalculateRequest(sentence: $sentence, mode: $mode)';
}

/// Structured arithmetic breakdown returned when an expression is resolved.
@immutable
class AiCalculationBreakdown {
  const AiCalculationBreakdown({
    required this.a,
    required this.b,
    required this.operation,
    required this.result,
  });

  final num a;
  final num b;
  final String operation;
  final num result;

  factory AiCalculationBreakdown.fromJson(Map<String, dynamic> json) {
    return AiCalculationBreakdown(
      a: (json['a'] as num?) ?? 0,
      b: (json['b'] as num?) ?? 0,
      operation: (json['operation'] as String?) ?? '',
      result: (json['result'] as num?) ?? 0,
    );
  }

  /// Formatted mathematical expression e.g. `12.5 × 4 = 50`.
  String get formattedFormula {
    final symbol = switch (operation.toLowerCase()) {
      'add' || '+' => '+',
      'sub' || '-' => '-',
      'mul' || '*' || '×' => '×',
      'div' || '/' || '÷' => '÷',
      _ => operation,
    };
    return '$a $symbol $b = $result';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AiCalculationBreakdown &&
          runtimeType == other.runtimeType &&
          a == other.a &&
          b == other.b &&
          operation == other.operation &&
          result == other.result;

  @override
  int get hashCode => Object.hash(a, b, operation, result);

  @override
  String toString() =>
      'AiCalculationBreakdown(a: $a, b: $b, operation: $operation, result: $result)';
}

/// Response payload from `POST /calculate`.
@immutable
class AiCalculateResponse {
  const AiCalculateResponse({
    required this.answer,
    required this.language,
    required this.mode,
    required this.requestId,
    this.calculation,
  });

  final String answer;
  final String language;
  final AiMode mode;
  final String requestId;
  final AiCalculationBreakdown? calculation;

  factory AiCalculateResponse.fromJson(Map<String, dynamic> json) {
    final rawCalculation = json['calculation'];
    final calculationBreakdown = rawCalculation is Map<String, dynamic>
        ? AiCalculationBreakdown.fromJson(rawCalculation)
        : (rawCalculation is Map
            ? AiCalculationBreakdown.fromJson(
                Map<String, dynamic>.from(rawCalculation),
              )
            : null);

    return AiCalculateResponse(
      answer: (json['answer'] as String?) ?? '',
      language: (json['language'] as String?) ?? 'en',
      mode: AiMode.fromString((json['mode'] as String?) ?? 'tool'),
      requestId: (json['request_id'] as String?) ??
          (json['requestId'] as String?) ??
          '',
      calculation: calculationBreakdown,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AiCalculateResponse &&
          runtimeType == other.runtimeType &&
          answer == other.answer &&
          language == other.language &&
          mode == other.mode &&
          requestId == other.requestId &&
          calculation == other.calculation;

  @override
  int get hashCode =>
      Object.hash(answer, language, mode, requestId, calculation);

  @override
  String toString() =>
      'AiCalculateResponse(answer: $answer, language: $language, mode: $mode, requestId: $requestId, calculation: $calculation)';
}
