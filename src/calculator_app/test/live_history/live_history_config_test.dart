import 'package:calculator_app/live_history/live_history_config.dart';
import 'package:calculator_app/live_history/live_history_constants.dart';
import 'package:flutter_test/flutter_test.dart';

const String _validRealtimeDomain =
    'example.appsync-realtime-api.us-east-2.amazonaws.com';
const String _validHttpDomain = 'example.appsync-api.us-east-2.amazonaws.com';
const String _validGraphQlUrl =
    'https://example.appsync-api.us-east-2.amazonaws.com/graphql';

void main() {
  group('LiveHistoryConfig', () {
    test('all three empty produces notConfigured', () {
      final config = LiveHistoryConfig.parse();
      expect(config.state, LiveHistoryConfigState.notConfigured);
      expect(config.isConfigured, isFalse);
      expect(config.isValid, isFalse);
      expect(config.problemMessage, isNull);
      expect(config.toString(), 'LiveHistoryConfig(notConfigured)');
      expect(() => config.realtimeUri, throwsStateError);
      expect(() => config.httpDomain, throwsStateError);
      expect(() => config.graphQlUri, throwsStateError);
    });

    test('default fromEnvironment when unset is notConfigured', () {
      final config = LiveHistoryConfig.fromEnvironment();
      expect(config.state, LiveHistoryConfigState.notConfigured);
    });

    test('all three valid AWS domains and URL produce valid config', () {
      final config = LiveHistoryConfig.parse(
        realtimeDomain: _validRealtimeDomain,
        httpDomain: _validHttpDomain,
        graphQlUrl: _validGraphQlUrl,
      );
      expect(config.state, LiveHistoryConfigState.valid);
      expect(config.isConfigured, isTrue);
      expect(config.isValid, isTrue);
      expect(config.problemMessage, isNull);
      expect(
        config.realtimeUri.toString(),
        'wss://$_validRealtimeDomain/event/realtime',
      );
      expect(config.httpDomain, _validHttpDomain);
      expect(config.graphQlUri.toString(), _validGraphQlUrl);
      expect(config.toString(), 'LiveHistoryConfig(valid)');
      expect(config.toString(), isNot(contains('example')));
      expect(config.toString(), isNot(contains('amazonaws')));
    });

    test('localhost and 127.0.0.1 are accepted for local tests', () {
      final localhostConfig = LiveHistoryConfig.parse(
        realtimeDomain: 'localhost:8080',
        httpDomain: 'localhost',
        graphQlUrl: 'http://localhost:8080/graphql',
      );
      expect(localhostConfig.isValid, isTrue);
      expect(
        localhostConfig.realtimeUri.toString(),
        'ws://localhost:8080/event/realtime',
      );
      expect(localhostConfig.httpDomain, 'localhost');

      final loopbackConfig = LiveHistoryConfig.parse(
        realtimeDomain: '127.0.0.1',
        httpDomain: '127.0.0.1:9000',
        graphQlUrl: 'http://127.0.0.1:9000/graphql',
      );
      expect(loopbackConfig.isValid, isTrue);
      expect(
        loopbackConfig.realtimeUri.toString(),
        'ws://127.0.0.1/event/realtime',
      );
    });

    test('partial settings (only 1 or 2 set) produce invalid', () {
      final onlyRealtime = LiveHistoryConfig.parse(
        realtimeDomain: _validRealtimeDomain,
      );
      final missingGraphQl = LiveHistoryConfig.parse(
        realtimeDomain: _validRealtimeDomain,
        httpDomain: _validHttpDomain,
      );
      final missingHttp = LiveHistoryConfig.parse(
        realtimeDomain: _validRealtimeDomain,
        graphQlUrl: _validGraphQlUrl,
      );
      for (final config in [onlyRealtime, missingGraphQl, missingHttp]) {
        expect(config.state, LiveHistoryConfigState.invalid);
        expect(config.isConfigured, isTrue);
        expect(config.isValid, isFalse);
        expect(
          config.problemMessage,
          LiveHistoryConstants.invalidAddressMessage,
        );
        expect(config.toString(), 'LiveHistoryConfig(invalid)');
      }
    });

    test(
        'rejects domains with scheme, path, query, fragment, userinfo or spaces',
        () {
      final invalidDomains = [
        'wss://$_validRealtimeDomain',
        '$_validRealtimeDomain/event/realtime',
        '$_validRealtimeDomain?token=abc',
        '$_validRealtimeDomain#frag',
        'user@$_validRealtimeDomain',
        ' $_validRealtimeDomain',
        '$_validRealtimeDomain:443',
        'evil.example.com',
        '.amazonaws.com',
      ];
      for (final bad in invalidDomains) {
        final badRealtime = LiveHistoryConfig.parse(
          realtimeDomain: bad,
          httpDomain: _validHttpDomain,
          graphQlUrl: _validGraphQlUrl,
        );
        expect(
          badRealtime.state,
          LiveHistoryConfigState.invalid,
          reason: 'realtimeDomain=$bad',
        );

        final badHttp = LiveHistoryConfig.parse(
          realtimeDomain: _validRealtimeDomain,
          httpDomain: bad,
          graphQlUrl: _validGraphQlUrl,
        );
        expect(
          badHttp.state,
          LiveHistoryConfigState.invalid,
          reason: 'httpDomain=$bad',
        );
      }
    });

    test('rejects untrusted or malformed GRAPHQL_URL', () {
      final invalidUrls = [
        'http://$_validHttpDomain/graphql',
        'wss://$_validHttpDomain/graphql',
        'https://evil.example.com/graphql',
        '$_validGraphQlUrl?token=secret',
        '$_validGraphQlUrl#frag',
        'https://user@$_validHttpDomain/graphql',
        ' $_validGraphQlUrl',
        'not a url',
      ];
      for (final badUrl in invalidUrls) {
        final config = LiveHistoryConfig.parse(
          realtimeDomain: _validRealtimeDomain,
          httpDomain: _validHttpDomain,
          graphQlUrl: badUrl,
        );
        expect(
          config.state,
          LiveHistoryConfigState.invalid,
          reason: 'graphQlUrl=$badUrl',
        );
      }
    });
  });
}
