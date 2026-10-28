import 'dart:convert';

import 'package:calculator_app/live_history/jwt_sub.dart';
import 'package:flutter_test/flutter_test.dart';

String _unpaddedBase64Url(String text) =>
    base64Url.encode(utf8.encode(text)).replaceAll('=', '');

String _buildJwt(Object payload) {
  final header = _unpaddedBase64Url(jsonEncode({'alg': 'RS256', 'typ': 'JWT'}));
  final body = _unpaddedBase64Url(jsonEncode(payload));
  return '$header.$body.signature-part';
}

void main() {
  group('extractJwtSub', () {
    test('extracts valid UUID sub claim from unpadded JWT payload', () {
      const sub = '11111111-2222-4333-8444-555555555555';
      final token = _buildJwt({'sub': sub, 'iss': 'https://cognito.example'});
      expect(extractJwtSub(token), sub);
    });

    test('returns null when token does not have 3 segments', () {
      expect(extractJwtSub(''), isNull);
      expect(extractJwtSub('only-one'), isNull);
      expect(extractJwtSub('one.two'), isNull);
      expect(extractJwtSub('one.two.three.four'), isNull);
      expect(extractJwtSub('.two.three'), isNull);
      expect(extractJwtSub('one..three'), isNull);
      expect(extractJwtSub('one.two.'), isNull);
    });

    test('returns null when payload segment is not valid base64url or JSON',
        () {
      expect(extractJwtSub('hdr.not*base64!.sig'), isNull);
      final nonJsonBody = _unpaddedBase64Url('not-json');
      expect(extractJwtSub('hdr.$nonJsonBody.sig'), isNull);
      final listBody = _unpaddedBase64Url('[1,2,3]');
      expect(extractJwtSub('hdr.$listBody.sig'), isNull);
    });

    test('returns null when sub claim is missing or not a String', () {
      expect(extractJwtSub(_buildJwt({'iss': 'x'})), isNull);
      expect(extractJwtSub(_buildJwt({'sub': 12345})), isNull);
      expect(extractJwtSub(_buildJwt({'sub': ''})), isNull);
    });

    test('returns null when sub contains disallowed characters or is too long',
        () {
      expect(extractJwtSub(_buildJwt({'sub': '../other-channel'})), isNull);
      expect(extractJwtSub(_buildJwt({'sub': 'user/sub'})), isNull);
      expect(extractJwtSub(_buildJwt({'sub': 'user sub'})), isNull);
      expect(extractJwtSub(_buildJwt({'sub': 'user_sub'})), isNull);
      expect(extractJwtSub(_buildJwt({'sub': 'a' * 51})), isNull);
    });
  });
}
