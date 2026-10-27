import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plexivo_client/plexivo_client.dart';
import 'package:test/test.dart';

void main() {
  test('uses only the publishable key and application-user token', () async {
    final requests = <http.Request>[];
    final transport = MockClient((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/auth/login')) {
        return http.Response(
          jsonEncode({'access_token': 'access', 'refresh_token': 'refresh'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode({
          'data': [
            {'id': 'one'},
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final client = PlexivoClient(
      'https://api.example/client/v1/demo',
      'plx_publishable_test',
      httpClient: transport,
    );
    await client.signInWithPassword(
      email: 'app@example.com',
      password: 'long-password',
    );
    expect(await client.from('items').select(), [
      {'id': 'one'},
    ]);
    expect(requests.first.headers['apikey'], 'plx_publishable_test');
    expect(requests.last.headers['authorization'], 'Bearer access');
    expect(requests.last.headers.containsKey('x-database-url'), isFalse);
  });

  test('surfaces the trace id on failed API calls', () async {
    final transport = MockClient((request) async => http.Response(
          jsonEncode({
            'error': {'code': 'invalid_credentials'},
            'trace_id': 'trace-failure',
          }),
          401,
          headers: {
            'content-type': 'application/json',
            'x-trace-id': 'trace-failure',
          },
        ));
    final client = PlexivoClient(
      'https://api.example/client/v1/demo',
      'plx_publishable_test',
      httpClient: transport,
    );

    await expectLater(
      client.signInWithPassword(
        email: 'app@example.com',
        password: 'long-password',
      ),
      throwsA(
          isA<PlexivoException>().having((error) => error.code, 'code', 'invalid_credentials').having((error) => error.traceId, 'traceId', 'trace-failure')),
    );
    expect(client.lastTraceId, 'trace-failure');
  });

  test('storage upload sends project credentials only to the capability mint endpoint', () async {
    final requests = <http.Request>[];
    final transport = MockClient((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/auth/login')) {
        return http.Response(
          jsonEncode({'access_token': 'access', 'refresh_token': 'refresh'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path.endsWith('/storage/v1/objects/sign-upload')) {
        expect(jsonDecode(request.body), {
          'path': 'documents/readme.txt',
          'content_type': 'text/plain',
          'size': 3,
        });
        return http.Response(
          jsonEncode({
            'data': {
              'object': {'id': 'object-one', 'status': 'pending'},
              'signed_url': 'https://api.example/client-storage/v1/demo/objects/object-one?token=signed'
            }
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path.contains('/client-storage/v1/')) {
        expect(request.headers['apikey'], isNull);
        expect(request.headers['authorization'], isNull);
        expect(request.headers['content-type'], 'text/plain');
        expect(request.bodyBytes, [1, 2, 3]);
        return http.Response(
          jsonEncode({
            'data': {'id': 'object-one', 'status': 'ready'}
          }),
          200,
          headers: {'content-type': 'application/json', 'x-trace-id': 'trace-upload'},
        );
      }
      throw StateError('unexpected request ${request.url}');
    });

    final client = PlexivoClient(
      'https://api.example/client/v1/demo',
      'plx_publishable_test',
      httpClient: transport,
    );
    await client.signInWithPassword(email: 'app@example.com', password: 'long-password');
    final object = await client.storage.upload('documents/readme.txt', [1, 2, 3], contentType: 'text/plain');

    expect(object['id'], 'object-one');
    expect(requests[1].headers['apikey'], 'plx_publishable_test');
    expect(requests[1].headers['authorization'], 'Bearer access');
    expect(client.lastTraceId, 'trace-upload');
  });

  test('a non-JSON error page still fails as a PlexivoException with its status', () async {
    final client = PlexivoClient('https://api.example/client/v1/demo', 'plx_publishable_test',
        httpClient: MockClient((request) async => http.Response('<html>Bad gateway</html>', 502,
            headers: {'content-type': 'text/html', 'x-trace-id': 'trace-502'})));
    await expectLater(
        client.from('notes').select(),
        throwsA(isA<PlexivoException>()
            .having((e) => e.statusCode, 'statusCode', 502)
            .having((e) => e.traceId, 'traceId', 'trace-502')));
  });

  test('functions.invoke encodes a sub-path and query on the project origin', () async {
    final seen = <http.Request>[];
    final client = PlexivoClient('https://api.example/client/v1/project', 'plx_publishable_test',
        httpClient: MockClient((request) async {
      seen.add(request);
      return http.Response('{"ok":true}', 200, headers: {'content-type': 'application/json'});
    }));
    final result = await client.functions.invoke('echo',
        path: '/some folder/part?x=1', query: {'q': 'a & b', 'n': 2, 'flag': false, 'absent': null}, body: {'hello': 'world'});
    expect(result.data, {'ok': true});
    final url = seen.single.url;
    expect(url.origin, 'https://api.example');
    expect(url.path, '/client/v1/project/functions/v1/echo/some%20folder/part%3Fx%3D1');
    expect(url.queryParameters, {'q': 'a & b', 'n': '2', 'flag': 'false'});
    expect(seen.single.body, '{"hello":"world"}');
    expect(() => client.functions.invoke('echo', path: '../other'), throwsArgumentError);
    expect(() => client.functions.invoke('..'), throwsArgumentError);
    expect(seen, hasLength(1));
  });
}
