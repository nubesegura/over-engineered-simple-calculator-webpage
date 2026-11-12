import 'live_history_constants.dart';

final RegExp _errorCodePattern = RegExp(r'^[A-Z0-9_]{1,40}$');
final RegExp _trailingPointZeroPattern = RegExp(r'^([+-]?\d+)\.0$');

/// One calculation entry from AppSync GraphQL (`Query.history`) or AppSync
/// Events (`/history/<sub>`).
class LiveCalculation {
  const LiveCalculation({
    required this.txId,
    required this.a,
    required this.b,
    required this.op,
    required this.symbol,
    required this.result,
    required this.errorCode,
    required this.status,
    required this.transport,
    required this.createdAt,
    required this.occurredAt,
  });

  /// Parses a calculation map from either GraphQL (`source: "ws"|"single"`) or
  /// AppSync Events (`transport: "websocket"|"graphql"`). Returns `null` when
  /// required fields are missing or malformed.
  static LiveCalculation? fromJson(Map<String, Object?> json) {
    final rawType = json['type'];
    if (rawType != null && rawType != 'calculation') return null;

    final txId = json['txId']?.toString().trim() ?? '';
    final createdAt = json['createdAt']?.toString().trim() ?? '';
    if (txId.isEmpty || createdAt.isEmpty) return null;

    final rawA = json['a'];
    final rawB = json['b'];
    if (rawA == null || rawB == null) return null;
    final a = formatNumber(rawA);
    final b = formatNumber(rawB);
    if (a.isEmpty || b.isEmpty) return null;

    final op = json['op']?.toString().trim().toUpperCase() ?? '';
    final symbol = LiveHistoryConstants.operationSymbols[op];
    if (symbol == null) return null;

    final status = json['status']?.toString().trim().toUpperCase() ?? '';
    if (status != 'OK' && status != 'ERROR') return null;

    final rawResult = json['result'];
    final formattedResult = rawResult == null ? null : formatNumber(rawResult);
    if (status == 'OK' &&
        (formattedResult == null || formattedResult.isEmpty)) {
      return null;
    }

    final rawErrorCode = json['errorCode']?.toString().trim();
    final errorCode =
        (rawErrorCode == null || rawErrorCode.isEmpty) ? null : rawErrorCode;

    final transport = normalizeTransport(json['transport'], json['source']);
    if (transport == null) return null;

    return LiveCalculation(
      txId: txId,
      a: a,
      b: b,
      op: op,
      symbol: symbol,
      result: status == 'OK' ? formattedResult : null,
      errorCode: errorCode,
      status: status,
      transport: transport,
      createdAt: createdAt,
      occurredAt: DateTime.tryParse(createdAt)?.toUtc(),
    );
  }

  final String txId;
  final String a;
  final String b;
  final String op;
  final String symbol;
  final String? result;
  final String? errorCode;
  final String status;
  final String transport;
  final String createdAt;
  final DateTime? occurredAt;

  /// Right-hand side of `<a_formatted> <symbol> <b_formatted> = <displayOutcome>`.
  String get displayOutcome {
    if (status == 'OK') return result ?? '';
    if (errorCode == 'DIVIDE_BY_ZERO' || errorCode == 'DIVISION_BY_ZERO') {
      return LiveHistoryConstants.divideByZeroMessage;
    }
    if (errorCode != null && _errorCodePattern.hasMatch(errorCode!)) {
      return LiveHistoryConstants.calculationFailedMessage(errorCode!);
    }
    return LiveHistoryConstants.unexpectedErrorMessage;
  }

  /// Local timestamp formatted as `YYYY-MM-DD HH:MM:SS`, or [createdAt] when it
  /// cannot be parsed as a [DateTime].
  String get formattedTimestamp {
    final local = occurredAt?.toLocal();
    if (local == null) return createdAt;
    return '${local.year}-${_two(local.month)}-${_two(local.day)} '
        '${_two(local.hour)}:${_two(local.minute)}:${_two(local.second)}';
  }

  /// Strips a trailing `.0` from integer-valued numbers (`12.0` -> `12`).
  static String formatNumber(Object? raw) {
    final text = raw?.toString().trim() ?? '';
    final match = _trailingPointZeroPattern.firstMatch(text);
    if (match != null) {
      final integerPart = match.group(1)!;
      return integerPart == '-0' ? '0' : integerPart;
    }
    return text;
  }

  /// Normalizes `transport` (`websocket`|`graphql`) and `source` (`ws`|`single`).
  static String? normalizeTransport(Object? rawTransport, Object? rawSource) {
    final value = (rawTransport ?? rawSource)?.toString().trim().toLowerCase();
    return switch (value) {
      'websocket' || 'ws' => 'websocket',
      'graphql' || 'single' => 'graphql',
      _ => null,
    };
  }

  /// Comparator for sorting calculations newest first (`createdAt` descending,
  /// then ISO-8601 string comparison, then `txId` tie-breaker).
  static int compareNewestFirst(LiveCalculation left, LiveCalculation right) {
    final leftTime = left.occurredAt;
    final rightTime = right.occurredAt;
    if (leftTime != null && rightTime != null) {
      final byTime = rightTime.compareTo(leftTime);
      if (byTime != 0) return byTime;
    }
    final byCreatedAt = right.createdAt.compareTo(left.createdAt);
    if (byCreatedAt != 0) return byCreatedAt;
    return right.txId.compareTo(left.txId);
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  @override
  bool operator ==(Object other) =>
      other is LiveCalculation &&
      other.txId == txId &&
      other.a == a &&
      other.b == b &&
      other.op == op &&
      other.symbol == symbol &&
      other.result == result &&
      other.errorCode == errorCode &&
      other.status == status &&
      other.transport == transport &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(
        txId,
        a,
        b,
        op,
        symbol,
        result,
        errorCode,
        status,
        transport,
        createdAt,
      );

  @override
  String toString() => 'LiveCalculation($txId, $status, $transport)';
}
