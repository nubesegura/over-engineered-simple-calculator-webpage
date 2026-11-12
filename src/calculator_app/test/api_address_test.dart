import 'package:calculator_app/api_address.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('deriveApiBaseUrl', () {
    test('a dev host gets the api subdomain and the version path', () {
      expect(
        deriveApiBaseUrl(
            override: '', page: Uri.parse('https://calc.dev.example.test/')),
        'https://api.calc.dev.example.test/api/v1',
      );
    });

    test('a prod host gets the api subdomain and the version path', () {
      expect(
        deriveApiBaseUrl(
            override: '', page: Uri.parse('https://calc.example.test/x?y=1')),
        'https://api.calc.example.test/api/v1',
      );
    });

    test('a build value wins over the page host', () {
      expect(
        deriveApiBaseUrl(
            override: 'https://other.example.test/api/v1',
            page: Uri.parse('https://calc.example.test/')),
        'https://other.example.test/api/v1',
      );
    });

    test('hosts without a usable domain name give no address', () {
      for (final page in [
        'http://localhost:8080/',
        'http://127.0.0.1:8080/',
        'http://[::1]:8080/',
        'file:///app/index.html',
      ]) {
        expect(deriveApiBaseUrl(override: '', page: Uri.parse(page)), isEmpty,
            reason: page);
      }
    });
  });
}
