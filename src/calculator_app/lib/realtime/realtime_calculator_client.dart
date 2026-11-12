import 'dart:async';
import 'dart:convert';

import 'realtime_channel.dart';
import 'realtime_constants.dart';
import 'realtime_messages.dart';
import 'tx_id.dart';

/// Why a calculation did not produce a result.
enum FailureKind {
  /// The backend answered with an error or a failed calculation.
  calculation,

  /// The numbers cannot be sent (not numeric, too long).
  invalidInput,

  /// A calculation is already waiting for its answer.
  busy,

  /// There is no open connection.
  notConnected,

  /// No answer after the retry.
  noAnswer,

  /// The backend refused the token on an open connection.
  unauthorized,

  /// The session ended while the request was pending.
  sessionExpired,
}

/// The end of one calculation request.
sealed class CalculationOutcome {
  const CalculationOutcome();
}

class CalculationSuccess extends CalculationOutcome {
  const CalculationSuccess(this.result);

  final String result;

  @override
  String toString() => 'CalculationSuccess($result)';
}

/// [message] is a fixed text, never the raw text of the server.
class CalculationFailure extends CalculationOutcome {
  const CalculationFailure(this.message, this.kind);

  final String message;
  final FailureKind kind;

  @override
  String toString() => 'CalculationFailure(${kind.name})';
}

/// The inputs changed or the user left: the answer is not wanted any more.
class CalculationCancelled extends CalculationOutcome {
  const CalculationCancelled();
}

class _Pending {
  _Pending(this.txId, this.payload);

  final String txId;
  final String payload;
  final Completer<CalculationOutcome> completer =
      Completer<CalculationOutcome>();
  Timer? timer;
  int attempts = 1;
  int inProgressResends = 0;
  bool needsResend = false;
}

/// Sends `calculate` requests over a [RealtimeChannel] and matches the replies.
///
/// One request at a time. The connection is owned by the controller, which
/// calls [attach], [detach] and forwards every received text to
/// [handleMessage]. Pure Dart: no Flutter import.
class RealtimeCalculatorClient {
  RealtimeCalculatorClient({
    String Function()? newTxId,
    Duration requestTimeout = RealtimeConstants.requestTimeout,
    Duration inProgressDelay = RealtimeConstants.inProgressDelay,
  })  : _newTxId = newTxId ?? generateTxId,
        _requestTimeout = requestTimeout,
        _inProgressDelay = inProgressDelay;

  final String Function() _newTxId;
  final Duration _requestTimeout;
  final Duration _inProgressDelay;

  RealtimeChannel? _channel;
  _Pending? _pending;
  int _ignored = 0;

  /// Replies dropped because they matched nothing or were malformed.
  int get ignoredCount => _ignored;

  bool get isBusy => _pending != null;

  /// Uses [channel] from now on and resends a request that was waiting for it.
  void attach(RealtimeChannel channel) {
    _channel = channel;
    final pending = _pending;
    if (pending != null && pending.needsResend) {
      pending.needsResend = false;
      _sendAndWait(pending);
    }
  }

  /// The connection is gone; a pending request waits for the next one and its
  /// timer stops, so the outage does not use up the single retry.
  void detach() {
    _channel = null;
    final pending = _pending;
    if (pending == null) return;
    pending.timer?.cancel();
    pending.needsResend = true;
  }

  /// Sends one calculation. Never throws: every end is an outcome.
  Future<CalculationOutcome> calculate({
    required String operation,
    required String a,
    required String b,
  }) {
    if (_pending != null) {
      return Future.value(const CalculationFailure(
        RealtimeConstants.busyMessage,
        FailureKind.busy,
      ));
    }
    final backendOp = backendOperation(operation);
    if (backendOp == null) {
      return Future.value(const CalculationFailure(
        RealtimeConstants.invalidRequestMessage,
        FailureKind.invalidInput,
      ));
    }
    final problem = validateOperands(a, b);
    if (problem != null) {
      return Future.value(
          CalculationFailure(problem, FailureKind.invalidInput));
    }
    final txId = _newTxId();
    final payload = buildCalculateRequest(
      txId: txId,
      a: a,
      b: b,
      operation: backendOp,
    );
    if (utf8.encode(payload).length > RealtimeConstants.maxRequestBytes) {
      return Future.value(const CalculationFailure(
        RealtimeConstants.tooLongMessage,
        FailureKind.invalidInput,
      ));
    }
    if (_channel == null) {
      return Future.value(const CalculationFailure(
        RealtimeConstants.notConnectedMessage,
        FailureKind.notConnected,
      ));
    }
    final pending = _Pending(txId, payload);
    _pending = pending;
    _sendAndWait(pending);
    return pending.completer.future;
  }

  /// Drops the pending request because its answer is not wanted any more.
  void discardPending() => _finish(const CalculationCancelled());

  /// Ends the pending request, if any, with [failure].
  void failPending(CalculationFailure failure) => _finish(failure);

  /// Handles one text received from the backend.
  void handleMessage(String text) {
    final reply = parseReply(text);
    final pending = _pending;
    switch (reply) {
      case null:
        _ignored++;
      case UnknownActionReply():
        break;
      case ResultReply():
        if (pending == null || reply.txId != pending.txId) {
          _ignored++;
        } else {
          _finish(_outcomeOf(reply));
        }
      case ErrorReply():
        if (pending == null) {
          _ignored++;
        } else {
          _onErrorReply(pending, reply.code);
        }
    }
  }

  CalculationOutcome _outcomeOf(ResultReply reply) {
    if (reply.status == 'OK' && reply.result != null) {
      return CalculationSuccess(reply.result!);
    }
    if (reply.status == 'ERROR') {
      return CalculationFailure(
        calculationErrorMessage(reply.errorCode),
        FailureKind.calculation,
      );
    }
    return const CalculationFailure(
      RealtimeConstants.unexpectedResponseMessage,
      FailureKind.calculation,
    );
  }

  void _onErrorReply(_Pending pending, String? code) {
    if (code == ReplyCodes.inProgress) {
      _retryLater(pending);
      return;
    }
    _finish(CalculationFailure(
      errorReplyMessage(code),
      code == ReplyCodes.unauthorized
          ? FailureKind.unauthorized
          : FailureKind.calculation,
    ));
  }

  void _retryLater(_Pending pending) {
    pending.timer?.cancel();
    if (pending.inProgressResends >= RealtimeConstants.maxInProgressResends) {
      _finish(_noAnswer());
      return;
    }
    pending.inProgressResends++;
    pending.timer = Timer(_inProgressDelay, () {
      if (!identical(_pending, pending)) return;
      _sendAndWait(pending);
    });
  }

  void _armTimer(_Pending pending) {
    pending.timer?.cancel();
    pending.timer = Timer(_requestTimeout, () => _onTimeout(pending));
  }

  void _onTimeout(_Pending pending) {
    if (!identical(_pending, pending)) return;
    if (pending.attempts >= 2) {
      _finish(_noAnswer());
      return;
    }
    pending.attempts++;
    _sendAndWait(pending);
  }

  /// Sends the request and starts the answer timer only if it went out; a
  /// request that could not be sent waits for the next connection instead.
  void _sendAndWait(_Pending pending) {
    if (_transmit(pending)) _armTimer(pending);
  }

  /// Sends the request again with the same txId; a closed channel means the
  /// request waits for the next connection. Returns whether it was sent.
  bool _transmit(_Pending pending) {
    final channel = _channel;
    if (channel == null) {
      pending.needsResend = true;
      return false;
    }
    try {
      channel.send(pending.payload);
      return true;
    } catch (_) {
      _channel = null;
      pending.needsResend = true;
      return false;
    }
  }

  CalculationFailure _noAnswer() => const CalculationFailure(
        RealtimeConstants.noAnswerMessage,
        FailureKind.noAnswer,
      );

  void _finish(CalculationOutcome outcome) {
    final pending = _pending;
    if (pending == null) return;
    _pending = null;
    pending.timer?.cancel();
    pending.completer.complete(outcome);
  }
}
