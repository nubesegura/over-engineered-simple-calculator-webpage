import 'ai_models.dart';

/// Configuration constants and error strings for the AI Natural Language tab.
abstract final class AiConstants {
  /// Default custom domain URL for the AI Assistant API in dev environment.
  static const String defaultBaseUrl =
      'https://ai.over-engineered-simple-calculator.dev.nube-segura.com';

  /// Path for the calculation endpoint on the AI API Gateway.
  static const String calculatePath = '/calculate';

  /// Maximum allowed characters for the natural language prompt.
  static const int maxSentenceLength = 200;

  /// Default calculation mode (deterministic tool execution).
  static const AiMode defaultMode = AiMode.tool;

  /// Timeout duration for HTTP requests to the AI API.
  static const Duration requestTimeout = Duration(seconds: 30);

  /// Minimum accessible touch target size in logical pixels.
  static const double minTouchTargetSize = 48.0;

  /// Resolves the effective base URL, preferring the compile-time `--dart-define=AI_API_BASE_URL`.
  static String effectiveBaseUrl() {
    const fromEnv = String.fromEnvironment('AI_API_BASE_URL');
    if (fromEnv.isNotEmpty) {
      return fromEnv;
    }
    return defaultBaseUrl;
  }

  // User-facing messages
  static const String promptPlaceholder =
      'e.g., What is 12.5 times 4? or Cuanto es 100 entre 4?';
  static const String emptySentenceMessage =
      'Please enter a sentence to calculate.';
  static const String sentenceTooLongMessage =
      'Sentence exceeds the maximum limit of 200 characters.';
  static const String calculationHistoryNotice =
      'Note: Calculation history is currently supported on the REST and WebSocket tabs.';
  static const String upstreamTimeoutMessage =
      'The AI service timed out. Please verify that the request is within the scheduled active window (08:00 - 22:00 UTC-5 in dev) or try again shortly.';
  static const String rateLimitMessage =
      'Rate limit or daily quota exceeded. Please wait a moment before trying again.';
  static const String unparseableMessage =
      'No valid arithmetic expression could be recognized in your sentence.';
  static const String divisionByZeroMessage =
      'Division by zero is not mathematically allowed.';
  static const String guardrailMessage =
      'Your query was blocked by safety or privacy guardrails.';
  static const String networkErrorMessage =
      'Connection to the AI calculation service failed. Please check your internet connection.';
  static const String sessionExpiredMessage =
      'Your session has expired. Please log in again to continue.';
}
