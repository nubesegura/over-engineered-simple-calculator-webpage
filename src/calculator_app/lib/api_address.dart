import 'constants.dart';

/// Build-time override of the API base URL (`--dart-define=API_BASE_URL=...`).
const String _apiBaseUrlOverride = String.fromEnvironment('API_BASE_URL');

final RegExp _ipv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');

/// Returns the API base URL, or an empty string when there is none.
///
/// A non-empty [override] wins. Otherwise the address is
/// `https://api.<host>/api/v1`, where `<host>` is the host of [page]. A host
/// that is `localhost`, an IP address or has no dots gives no address.
/// [override] and [page] default to the build value and the current page; they
/// are parameters so the function stays pure and testable.
String deriveApiBaseUrl({String? override, Uri? page}) {
  final fixed = (override ?? _apiBaseUrlOverride).trim();
  if (fixed.isNotEmpty) return fixed;

  final host = (page ?? Uri.base).host.toLowerCase();
  if (!_isDomainName(host)) return '';
  return 'https://${ApiConstants.apiSubdomain}.$host${ApiConstants.apiVersionPath}';
}

bool _isDomainName(String host) {
  if (!host.contains('.')) return false;
  if (host.contains(':')) return false;
  return !_ipv4.hasMatch(host);
}
