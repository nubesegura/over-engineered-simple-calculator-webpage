import 'dart:convert';

final RegExp _base64UrlSegmentPattern = RegExp(r'^[A-Za-z0-9_-]+$');
final RegExp _subClaimPattern = RegExp(r'^[A-Za-z0-9-]{1,50}$');

/// Function signature for extracting the Cognito `sub` claim from an ID token.
typedef JwtSubExtractor = String? Function(String idToken);

/// Extracts the validated `sub` claim from the payload segment of [idToken].
///
/// Returns `null` when [idToken] does not have three non-empty base64url
/// segments, cannot be decoded as a JSON object, or has no `sub` matching
/// `^[A-Za-z0-9-]{1,50}$`. Never throws and never includes [idToken] in an
/// exception or log.
String? extractJwtSub(String idToken) {
  final parts = idToken.split('.');
  if (parts.length != 3) return null;
  for (final part in parts) {
    if (part.isEmpty || !_base64UrlSegmentPattern.hasMatch(part)) return null;
  }
  try {
    final normalized = base64Url.normalize(parts[1]);
    final payloadBytes = base64Url.decode(normalized);
    final decoded = jsonDecode(utf8.decode(payloadBytes));
    if (decoded is! Map) return null;
    final sub = decoded['sub'];
    if (sub is! String || !_subClaimPattern.hasMatch(sub)) return null;
    return sub;
  } catch (_) {
    return null;
  }
}
