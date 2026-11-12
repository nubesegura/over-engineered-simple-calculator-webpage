import 'dart:convert';

import 'realtime_constants.dart';

/// Error codes of `{"type":"error"}` replies that the client reacts to.
class ReplyCodes {
  const ReplyCodes._();

  static const String inProgress = 'IN_PROGRESS';
  static const String unauthorized = 'UNAUTHORIZED';
  static const String unknownAction = 'UNKNOWN_ACTION';
  static const String divideByZero = 'DIVIDE_BY_ZERO';
}

final RegExp _numberPattern =
    RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$');

/// Only plain codes are echoed in a message; anything else is unexpected.
final RegExp _codePattern = RegExp(r'^[A-Z0-9_]{1,40}$');

/// The text to show when an operand cannot be sent, or null when both can.
///
/// Operands must be numeric by the REST rule (`double.tryParse`) and in plain
/// decimal form (no hexadecimal, `NaN` or `Infinity`), with at most 38 digits.
String? validateOperands(String a, String b) {
  for (final operand in [a.trim(), b.trim()]) {
    if (double.tryParse(operand) == null || !_numberPattern.hasMatch(operand)) {
      return RealtimeConstants.invalidNumbersMessage;
    }
  }
  for (final operand in [a, b]) {
    if (RegExp(r'\d').allMatches(operand).length >
        RealtimeConstants.maxOperandDigits) {
      return RealtimeConstants.tooLongMessage;
    }
  }
  return null;
}

/// The backend operation name for a REST operation key, or null.
String? backendOperation(String operation) =>
    RealtimeConstants.operationNames[operation];

/// The JSON text of a `calculate` request; operands are sent as strings.
String buildCalculateRequest({
  required String txId,
  required String a,
  required String b,
  required String operation,
}) =>
    jsonEncode({
      'action': 'calculate',
      'txId': txId,
      'a': a.trim(),
      'b': b.trim(),
      'op': operation,
    });

/// A message received from the backend.
sealed class ServerReply {
  const ServerReply();
}

/// `{"type":"result","calculation":{...}}`.
class ResultReply extends ServerReply {
  const ResultReply({
    required this.txId,
    this.status,
    this.result,
    this.errorCode,
  });

  final String txId;
  final String? status;
  final String? result;
  final String? errorCode;
}

/// `{"type":"error","code":...}`; [code] is null when it is missing.
class ErrorReply extends ServerReply {
  const ErrorReply(this.code);

  final String? code;
}

/// The answer to a keepalive ping, which the backend does not know.
class UnknownActionReply extends ServerReply {
  const UnknownActionReply();
}

/// Parses a received text. Returns null for what must be ignored and counted:
/// text over 64 KiB, invalid JSON, or a shape that is not a known reply.
ServerReply? parseReply(String text) {
  if (utf8.encode(text).length > RealtimeConstants.maxReplyBytes) return null;
  final Object? data;
  try {
    data = jsonDecode(text);
  } on FormatException {
    return null;
  }
  if (data is! Map) return null;
  switch (data['type']) {
    case 'result':
      final calculation = data['calculation'];
      if (calculation is! Map || calculation['txId'] is! String) return null;
      return ResultReply(
        txId: calculation['txId'] as String,
        status: _text(calculation['status']),
        result: _text(calculation['result']),
        errorCode: _text(calculation['errorCode']),
      );
    case 'error':
      final code = _text(data['code']);
      if (code == ReplyCodes.unknownAction) return const UnknownActionReply();
      return ErrorReply(code);
  }
  return null;
}

String? _text(Object? value) => value?.toString();

/// The fixed text for a failed calculation (`status` ERROR).
String calculationErrorMessage(String? errorCode) {
  if (errorCode == ReplyCodes.divideByZero) {
    return RealtimeConstants.divideByZeroMessage;
  }
  if (errorCode == null || !_codePattern.hasMatch(errorCode)) {
    return RealtimeConstants.unexpectedResponseMessage;
  }
  return RealtimeConstants.calculationFailedMessage(errorCode);
}

/// The fixed text for an `error` reply. The server `message` is never used.
String errorReplyMessage(String? code) => switch (code) {
      'INVALID_REQUEST' => RealtimeConstants.invalidRequestMessage,
      'IDEMPOTENCY_CONFLICT' => RealtimeConstants.idempotencyConflictMessage,
      'INTERNAL_ERROR' => RealtimeConstants.internalErrorMessage,
      ReplyCodes.unauthorized => RealtimeConstants.notAuthorizedMessage,
      _ => RealtimeConstants.unexpectedResponseMessage,
    };
