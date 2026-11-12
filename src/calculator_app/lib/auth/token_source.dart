/// What the API client needs from the session to authorize its requests.
abstract interface class TokenSource {
  /// The current ID token, renewed first when it is about to expire. Throws an
  /// `AuthApiException` when there is no session or it cannot be renewed.
  Future<String> validIdToken();

  /// Renews the session after a backend rejected [rejectedToken] with a 401 and
  /// returns the new ID token.
  Future<String> renewAfterRejection(String rejectedToken);

  /// Ends the session because the backend keeps rejecting [rejectedToken], the
  /// renewed token. Ignored when the session already holds a newer token or is
  /// gone.
  void markExpired(String rejectedToken);
}
