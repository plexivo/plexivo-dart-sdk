import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plexivo_client/plexivo_client.dart';
import 'package:plexivo_client/src/platform.dart';
import 'package:test/test.dart';

/// A client whose transport records each request and answers from `reply`.
({PlexivoClient db, List<Map<String, dynamic>> sent, List<http.Request> requests}) harness([Object Function(Map<String, dynamic> body, String path)? reply]) {
  final sent = <Map<String, dynamic>>[];
  final requests = <http.Request>[];
  final transport = MockClient((request) async {
    final body = request.body.isEmpty ? <String, dynamic>{} : Map<String, dynamic>.from(jsonDecode(request.body) as Map);
    sent.add(body);
    requests.add(request);
    final out = reply == null ? {'data': []} : reply(body, request.url.path);
    if (out is http.Response) return out;
    return http.Response(jsonEncode(out), 200, headers: {'content-type': 'application/json'});
  });
  return (db: PlexivoClient('https://api.example/client/v1/demo', 'plx_publishable_test', httpClient: transport), sent: sent, requests: requests);
}

/// An unsigned token with [exp] and [iat] claims, as the client reads them.
String jwt(DateTime exp, {DateTime? iat, String sub = 'u1'}) {
  String part(Map<String, dynamic> m) => base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  return '${part({'alg': 'HS256'})}.${part({
        'sub': sub,
        'exp': exp.millisecondsSinceEpoch ~/ 1000,
        if (iat != null) 'iat': iat.millisecondsSinceEpoch ~/ 1000
      })}.sig';
}

void main() {
  group('subquery IN', () {
    test('whereIn / whereNotIn / where(in) with a one-column query', () async {
      final h = harness();
      final indian = h.db.from('profiles').select('id').where('country', 'IN');
      await h.db.from('posts').whereIn('author_id', indian).whereNotIn('editor_id', h.db.from('banned').select('user_id'));
      expect(h.sent.last['where'], {
        'and': [
          {
            'column': 'author_id',
            'op': 'in',
            'query': {
              'from': 'profiles',
              'select': 'id',
              'where': {'column': 'country', 'op': 'eq', 'value': 'IN'}
            }
          },
          {
            'not': {
              'column': 'editor_id',
              'op': 'in',
              'query': {'from': 'banned', 'select': 'user_id'}
            }
          }
        ]
      });
      await h.db.from('posts').where('author_id', 'in', indian).where('id', h.db.from('picks').select('post_id'));
      expect((h.sent.last['where']['and'] as List).map((n) => (n as Map)['op']), ['in', 'in']);
      await h.db.from('posts').where((PlexivoConditions q) => q.whereIn('author_id', indian).orWhere('pinned', true));
      expect(((h.sent.last['where'] as Map)['or'] as List).first['query']['from'], 'profiles');
      await h.db.from('posts').preload('comments', (PlexivoEmbed c) => c.whereNotIn('author_id', h.db.from('banned').select('user_id')));
      final embed = (h.sent.last['select'] as List).last as Map;
      expect(embed['where'], {
        'not': {
          'column': 'author_id',
          'op': 'in',
          'query': {'from': 'banned', 'select': 'user_id'}
        }
      });
    });

    test('a subquery must select exactly one column', () {
      final h = harness();
      expect(() => h.db.from('posts').whereIn('author_id', h.db.from('profiles')), throwsArgumentError);
      expect(() => h.db.from('posts').whereIn('author_id', h.db.from('profiles').select('id, name')), throwsArgumentError);
      expect(() => h.db.from('posts').where('author_id', '>', h.db.from('profiles').select('id')), throwsArgumentError);
    });

    test('a soft-deleting model adds its filter to the subquery', () async {
      final h = harness();
      h.db.model('profiles', softDelete: 'deleted_at');
      await h.db.from('posts').whereIn('author_id', h.db.from('profiles').select('id'));
      expect(h.sent.last['where']['query']['where'], {'column': 'deleted_at', 'op': 'is', 'value': null});
    });
  });

  group('related order', () {
    test('dotted relation.column, hints, model relation names', () async {
      final h = harness();
      await h.db.from('posts').order('profiles.username', 'desc', 'last').order('id');
      expect(h.sent.last['order'], [
        {'column': 'username', 'relation': 'profiles', 'dir': 'desc', 'nulls': 'last'},
        {'column': 'id', 'dir': 'asc'}
      ]);
      await h.db.from('posts').order('profiles!posts_editor_id_fkey.username');
      expect(h.sent.last['order'], [
        {'column': 'username', 'relation': 'profiles', 'hint': 'posts_editor_id_fkey', 'dir': 'asc'}
      ]);
      h.db.model('posts', relations: {
        'author': const PlexivoRelation.belongsTo('profiles', foreignKey: 'author_id', constraint: 'posts_author_id_fkey'),
        'comments': const PlexivoRelation.hasMany('comments', foreignKey: 'post_id'),
      });
      await h.db.from('posts').order('author.username', false);
      expect(h.sent.last['order'], [
        {'column': 'username', 'relation': 'profiles', 'hint': 'posts_author_id_fkey', 'dir': 'desc'}
      ]);
      expect(() => h.db.from('posts').order('comments.body'), throwsArgumentError);
      await h.db.from('posts').order({'column': 'username', 'relation': 'profiles', 'dir': 'asc'});
      expect(h.sent.last['order'], [
        {'column': 'username', 'relation': 'profiles', 'dir': 'asc'}
      ]);
    });

    test('orderReferenced orders an embed, including many-to-many', () async {
      final h = harness((body, path) => {
            'data': [
              {
                'id': 1,
                '__m2m_tags': [
                  {
                    '__target': {'name': 'a'}
                  },
                  {
                    '__target': {'name': 'c'}
                  },
                  {
                    '__target': {'name': 'b'}
                  }
                ]
              }
            ]
          });
      await h.db.from('posts').select('id, comments(id, body)').orderReferenced('comments', 'id', 'desc');
      expect(((h.sent.last['select'] as List).last as Map)['order'], [
        {'column': 'id', 'dir': 'desc'}
      ]);
      expect(() => h.db.from('posts').orderReferenced('nothing', 'id'), throwsArgumentError);
      h.db.model('posts', relations: {
        'tags': const PlexivoRelation.manyToMany('tags', through: 'post_tags', foreignKey: 'post_id', otherKey: 'tag_id'),
      });
      final rows = await h.db.from('posts').preload('tags').orderReferenced('tags', 'name', 'desc');
      expect((rows.first['tags'] as List).map((t) => (t as Map)['name']), ['c', 'b', 'a']);
    });
  });

  group('nested preload paths', () {
    test('preload(a.b) builds nested embeds; a later path merges into an existing embed', () async {
      final h = harness((body, path) => {
            'data': [
              {
                'id': 1,
                'comments': [
                  {
                    'id': 5,
                    'author': [
                      {'id': 'u'}
                    ]
                  }
                ]
              }
            ]
          });
      h.db.model('comments', relations: {'author': const PlexivoRelation.hasOne('profiles', foreignKey: 'id', references: 'author_id')});
      final rows = await h.db.from('posts').preload('comments.author');
      expect(h.sent.last['select'], [
        '*',
        {
          'embed': 'comments',
          'as': 'comments',
          'inner': false,
          'select': [
            '*',
            {'embed': 'profiles', 'as': 'author', 'inner': false}
          ]
        }
      ]);
      expect((rows.first['comments'] as List).first['author'], {'id': 'u'}, reason: 'has-one shaped to one map at depth 2');

      await h.db
          .from('posts')
          .preload('comments', (PlexivoEmbed c) => c.select('id, body').order('id'))
          .preload('comments.author', (PlexivoEmbed a) => a.select('username'));
      final comments = (h.sent.last['select'] as List).whereType<Map>().toList();
      expect(comments, hasLength(1));
      expect(comments.single['order'], [
        {'column': 'id', 'dir': 'asc'}
      ]);
      expect(comments.single['select'], [
        'id',
        'body',
        {
          'embed': 'profiles',
          'as': 'author',
          'inner': false,
          'select': ['username']
        }
      ]);

      await h.db.from('posts').joins('comments.author');
      final inner = (h.sent.last['select'] as List).last as Map;
      expect(inner['inner'], true);
      expect(((inner['select'] as List).last as Map)['inner'], true);
    });

    test('a path through many-to-many nests inside the target table', () async {
      final h = harness();
      h.db.model('posts', relations: {
        'tags': const PlexivoRelation.manyToMany('tags', through: 'post_tags', foreignKey: 'post_id', otherKey: 'tag_id'),
      });
      await h.db.from('posts').preload('tags.category');
      final link = (h.sent.last['select'] as List).last as Map;
      expect(link['embed'], 'post_tags');
      final target = (link['select'] as List).single as Map;
      expect(target['embed'], 'tags');
      expect(target['select'], [
        '*',
        {'embed': 'category', 'as': 'category', 'inner': false}
      ]);
    });
  });

  test('pluck, exists and aggregates keep inner joins as filters; DateTime values are encoded', () async {
    final h = harness((body, path) => body['op'] == 'aggregate'
        ? {
            'data': {'count': 1}
          }
        : {
            'data': [
              {'id': 1}
            ]
          });
    await h.db.from('posts').joins('comments', (PlexivoEmbed c) => c.where('approved', true)).pluck('id');
    expect(((h.sent.last['select'] as List).last as Map)['inner'], true);
    await h.db.from('posts').joins('comments.author').where('likes', '>', 1).count();
    expect(h.sent.last['where'], {
      'and': [
        {'column': 'likes', 'op': 'gt', 'value': 1},
        {
          'has': 'comments',
          'where': {'has': 'author'}
        }
      ]
    });
    await h.db.from('posts').insert({'published_at': DateTime.utc(2026, 10, 28, 4, 30)});
    expect((h.sent.last['values'] as List).first, {'published_at': '2026-10-28T04:30:00.000Z'});
  });

  group('rpc builder', () {
    test('awaited as it is: the same call and result as 0.3', () async {
      final h = harness((body, path) => {'data': 42});
      expect(await h.db.rpc('cart_total', {'cart_id': 7}), 42);
      expect(h.requests.last.url.path, '/client/v1/demo/rest/v1/rpc/cart_total');
      expect(h.sent.last, {'cart_id': 7});
      expect(await h.db.rpc('cart_total', {'cart_id': 7}).then((v) => (v as int) + 1), 43);
    });

    test('chained: one structured rpc operation with select, filters, order, paging and count', () async {
      final h = harness((body, path) => {
            'data': [
              {'id': 1, 'title': 'a'}
            ],
            'count': 9
          });
      final rows = await h.db
          .rpc('search_posts', {'q': 'pg'})
          .select('id, title, author:profiles(username)', 'exact')
          .gte('likes', 10)
          .or('id.eq.1,id.eq.2')
          .order('likes', 'desc')
          .range(10, 19);
      expect(h.requests.last.url.path, '/client/v1/demo/query/v1');
      expect(h.sent.last, {
        'op': 'rpc',
        'function': 'search_posts',
        'args': {'q': 'pg'},
        'select': [
          'id',
          'title',
          {
            'embed': 'profiles',
            'as': 'author',
            'select': ['username']
          }
        ],
        'where': {
          'and': [
            {'column': 'likes', 'op': 'gte', 'value': 10},
            {
              'or': [
                {'column': 'id', 'op': 'eq', 'value': '1'},
                {'column': 'id', 'op': 'eq', 'value': '2'}
              ]
            }
          ]
        },
        'order': [
          {'column': 'likes', 'dir': 'desc'}
        ],
        'limit': 10,
        'offset': 10,
        'count': true,
      });
      expect(rows, isA<PlexivoResult>());
      expect((rows as PlexivoResult).count, 9);
    });

    test('single and maybeSingle', () async {
      var answer = <String, dynamic>{
        'data': [
          {'id': 1}
        ]
      };
      final h = harness((body, path) => answer);
      expect((await h.db.rpc('top_post').limit(1).single()).data, {'id': 1});
      answer = {'data': []};
      expect((await h.db.rpc('top_post').limit(1).maybeSingle()).data, isNull);
      await expectLater(h.db.rpc('top_post').limit(1).single(), throwsA(isA<RecordNotFoundException>()));
      answer = {
        'data': [
          {'id': 1},
          {'id': 2}
        ]
      };
      await expectLater(h.db.rpc('top_post').single(), throwsA(isA<PlexivoException>().having((e) => e.code, 'code', 'multiple_rows')));
      answer = {
        'data': {'id': 3}
      };
      expect((await h.db.rpc('one_post').single()).data, {'id': 3});
    });
  });

  group('auth metadata', () {
    test('signUp sends data; updateUser merges and updates the session', () async {
      final h = harness((body, path) {
        if (path.endsWith('/auth/signup')) {
          return {
            'access_token': 'a',
            'refresh_token': 'r',
            'user': {'id': 'u1', 'user_metadata': body['data']}
          };
        }
        return {
          'user': {
            'id': 'u1',
            'user_metadata': {'name': 'Asha', 'theme': 'dark'}
          }
        };
      });
      final events = <String>[];
      h.db.authStateChanges.listen((s) => events.add(s.event));
      await h.db.signUp(email: 'a@example.test', password: 'a long password', data: {'name': 'Asha'});
      expect(h.sent.last['data'], {'name': 'Asha'});
      expect(h.db.currentUser?['user_metadata'], {'name': 'Asha'});
      final user = await h.db.updateUser(data: {'theme': 'dark', 'nickname': null});
      expect(h.requests.last.method, 'PATCH');
      expect(h.requests.last.url.path, '/client/v1/demo/auth/user');
      expect(h.sent.last, {
        'data': {'theme': 'dark', 'nickname': null}
      });
      expect(user['user_metadata'], {'name': 'Asha', 'theme': 'dark'});
      expect(h.db.currentUser?['user_metadata'], {'name': 'Asha', 'theme': 'dark'});
      expect(h.db.session?['access_token'], 'a');
      await Future<void>.delayed(Duration.zero);
      expect(events, ['SIGNED_UP', 'USER_UPDATED']);
      await h.db.signOut();
      expect(() => h.db.updateUser(data: {}), throwsStateError);
    });
  });

  test('the secret key is refused on the web, and only there', () {
    expect(() => checkKeyForPlatform('plx_secret_abc', web: true), throwsA(isA<PlexivoException>().having((e) => e.code, 'code', 'secret_key_in_browser')));
    checkKeyForPlatform('plx_publishable_abc', web: true);
    checkKeyForPlatform('plx_secret_abc', web: false);
    expect(runningOnWeb, isFalse);
    PlexivoClient('https://api.example/client/v1/demo', 'plx_secret_abc');
  });

  group('realtime lifecycle', () {
    late HttpServer server;
    late List<Map<String, String>> connects;
    late List<WebSocket> sockets;
    late List<String> joins;
    var refreshes = 0;
    var refuse = false;

    setUp(() async {
      connects = [];
      sockets = [];
      joins = [];
      refreshes = 0;
      refuse = false;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (request.uri.path.endsWith('/auth/refresh')) {
          refreshes++;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({
            'access_token': jwt(DateTime.now().add(const Duration(hours: 1)), sub: 'fresh$refreshes'),
            'refresh_token': 'r$refreshes',
            'user': {'id': 'u1'}
          }));
          await request.response.close();
          return;
        }
        connects.add(request.uri.queryParameters);
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((frame) {
          final f = jsonDecode(frame as String) as List;
          if (f[3] == 'phx_join') {
            joins.add(f[2] as String);
            socket.add(jsonEncode([
              f[0],
              f[1],
              f[2],
              'phx_reply',
              refuse
                  ? {
                      'status': 'error',
                      'response': {'reason': 'sign_in_required'}
                    }
                  : {'status': 'ok', 'response': {}}
            ]));
          }
        });
      });
    });
    tearDown(() => server.close(force: true));

    PlexivoClient client(String token) =>
        PlexivoClient('http://127.0.0.1:${server.port}/client/v1/demo', 'plx_publishable_test', initialSession: {'access_token': token, 'refresh_token': 'r0'});

    Future<void> until(bool Function() cond) async {
      for (var i = 0; i < 100 && !cond(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(cond(), isTrue);
    }

    void push(WebSocket s, String event, Map<String, dynamic> payload) => s.add(jsonEncode([null, null, 'realtime:changes:posts', event, payload]));

    test('token_expired from the server: refresh, reconnect with the new token, rejoin, changes flow', () async {
      final db = client(jwt(DateTime.now().add(const Duration(hours: 1))));
      final ch = db.channel('changes:posts')..subscribe();
      final statuses = <PlexivoChannelStatus>[];
      final errors = <String>[];
      final changes = <PlexivoChange>[];
      ch.statusChanges.listen(statuses.add);
      ch.errors.listen(errors.add);
      ch.changes.listen(changes.add);
      await ch.ready();
      push(sockets.single, 'system', {'status': 'token_expired'});
      push(sockets.single, 'phx_close', {});
      await until(() => joins.length == 2 && ch.isJoined);
      expect(refreshes, 1);
      expect(connects.last['access_token'], db.accessToken);
      expect(connects.last['access_token'], isNot(connects.first['access_token']));
      expect(errors, ['token_expired']);
      push(sockets.last, 'postgres_changes', {
        'type': 'insert',
        'table': 'posts',
        'record': {'id': 1}
      });
      await until(() => changes.isNotEmpty);
      expect(statuses, [PlexivoChannelStatus.joined, PlexivoChannelStatus.reconnecting, PlexivoChannelStatus.joined]);
      await ch.unsubscribe();
      expect(ch.status, PlexivoChannelStatus.closed);
    });

    test('a dropped socket reconnects with backoff and rejoins; an expired token is refreshed first', () async {
      final db = client(jwt(DateTime.now().subtract(const Duration(seconds: 5))));
      final ch = db.channel('changes:posts')..subscribe();
      await ch.ready();
      expect(refreshes, 1, reason: 'an already expired token is refreshed before connecting');
      await sockets.single.close();
      await until(() => joins.length == 2 && ch.isJoined);
      expect(connects, hasLength(2));
      ch.reconnect();
      await until(() => joins.length == 3 && ch.isJoined);
      expect(refreshes, 1);
      await ch.unsubscribe();
    });

    test('phx_error rejoins; a refused join is reported once and not retried', () async {
      final db = client(jwt(DateTime.now().add(const Duration(hours: 1))));
      final ch = db.channel('changes:posts')..subscribe();
      await ch.ready();
      push(sockets.single, 'phx_error', {});
      await until(() => joins.length == 2 && ch.isJoined);

      refuse = true;
      final errors = <String>[];
      ch.errors.listen(errors.add);
      await sockets.last.close();
      await until(() => ch.status == PlexivoChannelStatus.refused);
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      expect(joins, hasLength(3));
      expect(errors, ['sign_in_required']);
      await expectLater(ch.ready(), throwsA(isA<PlexivoException>().having((e) => e.code, 'code', 'sign_in_required')));
      await ch.unsubscribe();
    });

    test('before the token expires, the channel renews it and reconnects', () async {
      final now = DateTime.now();
      final db = client(jwt(now.add(const Duration(seconds: 4)), iat: now.subtract(const Duration(seconds: 1))));
      final ch = db.channel('changes:posts')..subscribe();
      await ch.ready();
      await until(() => joins.length == 2 && ch.isJoined);
      expect(refreshes, 1);
      expect(connects.last['access_token'], db.accessToken);
      await ch.unsubscribe();
    });
  });
}
