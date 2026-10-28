import 'ai_constants.dart';

/// Base class for all AI Assistant errors.
abstract class AiException implements Exception {
  const AiException(
    this.message, {
    this.code,
    this.statusCode,
    this.requestId,
  });

  final String message;
  final String? code;
  final int? statusCode;
  final String? requestId;

  @override
  String toString() => message;

  /// Creates a typed [AiException] based on HTTP status code and error response body.
  static AiException fromResponse({
    required int statusCode,
    Map<String, dynamic>? body,
    String? fallbackMessage,
  }) {
    final error = body?['error'] is Map ? body!['error'] as Map : null;
    final code = error?['code']?.toString() ?? body?['code']?.toString();
    final message = error?['message']?.toString() ??
        body?['message']?.toString() ??
        fallbackMessage;
    final requestId = error?['request_id']?.toString() ??
        error?['requestId']?.toString() ??
        body?['request_id']?.toString() ??
        body?['requestId']?.toString();

    final effectiveMessage = message ?? 'An unexpected error occurred.';

    switch (statusCode) {
      case 400:
        return InvalidPayloadException(
          effectiveMessage,
          code: code ?? 'INVALID_PAYLOAD',
          requestId: requestId,
        );
      case 401:
        return AiUnauthorizedException(
          effectiveMessage,
          code: code ?? 'UNAUTHORIZED',
          requestId: requestId,
        );
      case 422:
        return switch (code) {
          'DIVISION_BY_ZERO' => DivisionByZeroException(
              effectiveMessage.isNotEmpty
                  ? effectiveMessage
                  : AiConstants.divisionByZeroMessage,
              code: code,
              requestId: requestId,
            ),
          'GUARDRAIL_INTERVENTION' => GuardrailInterventionException(
              effectiveMessage.isNotEmpty
                  ? effectiveMessage
                  : AiConstants.guardrailMessage,
              code: code,
              requestId: requestId,
            ),
          _ => UnparseableSentenceException(
              effectiveMessage.isNotEmpty
                  ? effectiveMessage
                  : AiConstants.unparseableMessage,
              code: code ?? 'UNPARSEABLE_SENTENCE',
              requestId: requestId,
            ),
        };
      case 429:
        return AiRateLimitException(
          effectiveMessage.isNotEmpty
              ? effectiveMessage
              : AiConstants.rateLimitMessage,
          code: code ?? 'RATE_LIMIT_EXCEEDED',
          requestId: requestId,
        );
      case 504:
        return AiUpstreamTimeoutException(
          effectiveMessage.isNotEmpty
              ? effectiveMessage
              : AiConstants.upstreamTimeoutMessage,
          code: code ?? 'UPSTREAM_TIMEOUT',
          requestId: requestId,
        );
      default:
        return AiUnknownException(
          effectiveMessage,
          code: code,
          statusCode: statusCode,
          requestId: requestId,
        );
    }
  }
}

/// Thrown when the sentence or payload does not pass backend structural validation (HTTP 400).
class InvalidPayloadException extends AiException {
  const InvalidPayloadException(
    super.message, {
    super.code = 'INVALID_PAYLOAD',
    super.requestId,
  }) : super(statusCode: 400);
}

/// Thrown when authentication fails or ID token is invalid/expired (HTTP 401).
class AiUnauthorizedException extends AiException {
  const AiUnauthorizedException(
    super.message, {
    super.code = 'UNAUTHORIZED',
    super.requestId,
  }) : super(statusCode: 401);
}

/// Thrown when no valid mathematical expression can be derived from the sentence (HTTP 422).
class UnparseableSentenceException extends AiException {
  const UnparseableSentenceException(
    super.message, {
    super.code = 'UNPARSEABLE_SENTENCE',
    super.requestId,
  }) : super(statusCode: 422);
}

/// Thrown when an expression resolves to a division by zero (HTTP 422).
class DivisionByZeroException extends AiException {
  const DivisionByZeroException(
    super.message, {
    super.code = 'DIVISION_BY_ZERO',
    super.requestId,
  }) : super(statusCode: 422);
}

/// Thrown when safety or privacy guardrails block the query or answer (HTTP 422).
class GuardrailInterventionException extends AiException {
  const GuardrailInterventionException(
    super.message, {
    super.code = 'GUARDRAIL_INTERVENTION',
    super.requestId,
  }) : super(statusCode: 422);
}

/// Thrown when rate limits (1 req/s) or daily quotas are exceeded (HTTP 429).
class AiRateLimitException extends AiException {
  const AiRateLimitException(
    super.message, {
    super.code = 'RATE_LIMIT_EXCEEDED',
    super.requestId,
  }) : super(statusCode: 429);
}

/// Thrown when upstream Bedrock / VPC NAT times out, such as off-hours (HTTP 504).
class AiUpstreamTimeoutException extends AiException {
  const AiUpstreamTimeoutException(
    super.message, {
    super.code = 'UPSTREAM_TIMEOUT',
    super.requestId,
  }) : super(statusCode: 504);
}

/// Thrown on network disconnects, socket errors, or CORS failures.
class AiNetworkException extends AiException {
  const AiNetworkException(
    super.message, {
    super.code = 'NETWORK_ERROR',
    super.requestId,
  });
}

/// Catch-all for unanticipated HTTP status codes.
class AiUnknownException extends AiException {
  const AiUnknownException(
    super.message, {
    super.code,
    super.statusCode,
    super.requestId,
  });
}
