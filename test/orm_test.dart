import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plexivo_client/plexivo_client.dart';
import 'package:test/test.dart';

/// A client whose transport records each request body and answers from `reply`.
({PlexivoClient db, List<Map<String, dynamic>> sent, List<String> paths}) harness(
    [Object Function(Map<String, dynamic> body, String path)? reply, String key = 'plx_publishable_test']) {
  final sent = <Map<String, dynamic>>[];
  final paths = <String>[];
  final transport = MockClient((request) async {
    final body = request.body.isEmpty ? <String, dynamic>{} : Map<String, dynamic>.from(jsonDecode(request.body) as Map);
    sent.add(body);
    paths.add(request.url.path);
    final out = reply == null ? {'data': []} : reply(body, request.url.path);
    if (out is http.Response) return out;
    return http.Response(jsonEncode(out), 200, headers: {'content-type': 'application/json'});
  });
  return (db: PlexivoClient('https://api.example/client/v1/demo', key, httpClient: transport), sent: sent, paths: paths);
}

void main() {
  test('where: values, operators, maps, nulls, lists, groups, SQL precedence', () async {
    final h = harness();
    await h.db
        .from('posts')
        .where('likes', '>', 10)
        .where({'published': true, 'deleted_at': null})
        .orWhere('title', 'ilike', '%gb')
        .where((PlexivoConditions q) => q.where('a', 1).orWhere('b', 'in', [2, 3]))
        .whereNot('author_id', [1, 2])
        .whereBetween('score', 1, 5);
    expect(h.sent.last['where'], {
      'or': [
        {
          'and': [
            {'column': 'likes', 'op': 'gt', 'value': 10},
            {
              'and': [
                {'column': 'published', 'op': 'eq', 'value': true},
                {'column': 'deleted_at', 'op': 'is', 'value': null}
              ]
            }
          ]
        },
        {
          'and': [
            {'column': 'title', 'op': 'ilike', 'value': '%gb'},
            {
              'or': [
                {'column': 'a', 'op': 'eq', 'value': 1},
                {
                  'column': 'b',
                  'op': 'in',
                  'value': [2, 3]
                }
              ]
            },
            {
              'not': {
                'column': 'author_id',
                'op': 'in',
                'value': [1, 2]
              }
            },
            {
              'and': [
                {'column': 'score', 'op': 'gte', 'value': 1},
                {'column': 'score', 'op': 'lte', 'value': 5}
              ]
            }
          ]
        }
      ]
    });
  });

  test('Supabase-style: select string with embeds, eq, or(), order, range, single', () async {
    final h = harness((_, __) => {
          'data': [
            {'id': 1}
          ]
        });
    final one =
        await h.db.from('notes').select('id, body, author:authors(name)').eq('pinned', true).or('a.eq.1,b.gt.2').order('id', false).range(0, 9).single();
    expect(one.data, {'id': 1});
    final q = h.sent.last;
    expect(q['select'], [
      'id',
      'body',
      {
        'embed': 'authors',
        'as': 'author',
        'select': ['name']
      }
    ]);
    expect(q['order'], [
      {'column': 'id', 'dir': 'desc'}
    ]);
    expect(q['offset'], 0);
    expect(q['limit'], 2); // single() asks for two to detect duplicates
    expect((q['where'] as Map)['and'][1], {
      'or': [
        {'column': 'a', 'op': 'eq', 'value': '1'},
        {'column': 'b', 'op': 'gt', 'value': '2'}
      ]
    });
  });

  test('first/last/take, RecordNotFoundException, count, pluck, grouped aggregate', () async {
    var rows = <Map<String, dynamic>>[
      {'id': 7, 'title': 'A'}
    ];
    final h = harness((body, _) {
      if (body['op'] == 'aggregate' && body['group_by'] != null) {
        return {
          'data': [
            {'author_id': 1, 'count': 2}
          ]
        };
      }
      if (body['op'] == 'aggregate') {
        return {
          'data': {
            'count': 4,
            'sum': {'likes': '70'}
          }
        };
      }
      return {'data': rows};
    });
    expect(await h.db.from('posts').first(), {'id': 7, 'title': 'A'});
    expect(h.sent.last['order'], [
      {'column': 'id', 'dir': 'asc'}
    ]);
    expect(await h.db.from('posts').count(), 4);
    expect(await h.db.from('posts').sum('likes'), 70);
    expect(await h.db.from('posts').pluck('title'), ['A']);
    await h.db.from('posts').groupBy('author_id').having('sum(likes) > ?', 10).order('count(*) desc').aggregate({'count': true, 'sum': 'likes'});
    expect(h.sent.last['having'], {'fn': 'sum', 'column': 'likes', 'op': 'gt', 'value': 10});
    expect(h.sent.last['order'], [
      {'fn': 'count', 'dir': 'desc'}
    ]);
    rows = [];
    expect(() => h.db.from('posts').first(), throwsA(isA<RecordNotFoundException>()));
    expect(await h.db.from('posts').firstOrNull(), isNull);
  });

  test('writes: create, upsert with chosen columns, update with a filter, counters, refused unfiltered writes', () async {
    final h = harness((body, _) => {
          'data': [
            for (final v in (body['values'] as List?) ??
                [
                  {'id': 1}
                ])
              {'id': 1, ...(v as Map)}
          ],
          'count': 1
        });
    expect(await h.db.from('tags').create({'name': 'go'}), {'id': 1, 'name': 'go'});
    await h.db.from('products').upsert({'sku': 'A1', 'price': 11}, onConflict: 'sku', update: ['price']);
    expect(h.sent.last, {
      'op': 'insert',
      'into': 'products',
      'values': [
        {'sku': 'A1', 'price': 11}
      ],
      'on_conflict': ['sku'],
      'upsert': 'merge',
      'update_columns': ['price']
    });
    await h.db.from('posts').update({'title': 'T'}).eq('id', 3);
    expect(h.sent.last, {
      'op': 'update',
      'table': 'posts',
      'set': {'title': 'T'},
      'where': {'column': 'id', 'op': 'eq', 'value': 3}
    });
    await h.db.from('products').where('sku', 'A1').decrement('stock', by: 2);
    expect(h.sent.last['inc'], {'stock': -2});
    expect(() => h.db.from('posts').update({'title': 'all'}).then((r) => r), throwsA(predicate((e) => e is PlexivoException && e.code == 'missing_where')));
  });

  test('models: relations become embeds and joins, shaped back; soft deletes; hooks', () async {
    final h = harness((body, _) {
      if (body['op'] != 'select') return {'data': (body['values'] as List?) ?? []};
      return {
        'data': [
          {
            'id': 1,
            'author': {'name': 'Asha'},
            '__m2m_tags': [
              {
                '__target': {'name': 'b'}
              },
              {
                '__target': {'name': 'a'}
              },
              {'__target': null}
            ],
            'comments_count': {'count': 3}
          }
        ]
      };
    });
    final calls = <String>[];
    h.db.model('posts',
        softDelete: 'deleted_at',
        relations: {
          'author': const PlexivoRelation.belongsTo('authors', foreignKey: 'author_id'),
          'comments': const PlexivoRelation.hasMany('comments', foreignKey: 'post_id'),
          'tags': const PlexivoRelation.manyToMany('tags', through: 'post_tags', foreignKey: 'post_id', otherKey: 'tag_id'),
        },
        hooks: PlexivoHooks(beforeCreate: (r) {
          calls.add('beforeCreate');
          return {...r, 'slug': (r['title'] as String).toLowerCase()};
        }, afterCreate: (r) {
          calls.add('afterCreate');
          return null;
        }));
    final rows = await h.db
        .from('posts')
        .preload('author', (PlexivoEmbed a) => a.select('name'))
        .preload('tags', (PlexivoEmbed t) => t.order('name'))
        .withCount('comments')
        .whereHas('tags', (PlexivoEmbed t) => t.where('name', 'elixir'));
    expect(rows.first, {
      'id': 1,
      'author': {'name': 'Asha'},
      'tags': [
        {'name': 'a'},
        {'name': 'b'}
      ],
      'comments_count': 3
    });
    final q = h.sent.last;
    expect((q['where'] as Map)['and'][0], {
      'has': 'post_tags',
      'where': {
        'has': 'tags',
        'where': {'column': 'name', 'op': 'eq', 'value': 'elixir'}
      }
    });
    expect((q['where'] as Map)['and'][1], {'column': 'deleted_at', 'op': 'is', 'value': null});
    await h.db.from('posts').where('id', 1).delete();
    expect(h.sent.last['op'], 'update');
    await h.db.from('posts').create({'title': 'Hello'});
    expect(calls, ['beforeCreate', 'afterCreate']);
    expect((h.sent.last['values'] as List).first, {'title': 'Hello', 'slug': 'hello'});
  });

  test('transactions: one request, references between steps, a failure names the step', () async {
    final h = harness((body, path) {
      if (path.endsWith('/transaction')) {
        return {
          'results': [
            for (var i = 0; i < (body['operations'] as List).length; i++)
              {
                'data': [
                  {'id': 10 + i}
                ],
                'count': 1
              }
          ]
        };
      }
      return {'data': []};
    });
    final results = await h.db.transaction((tx) {
      final author = tx.from('authors').insert({'name': 'Asha'});
      tx.from('posts').insert({'title': 'Hi', 'author_id': author.ref('id')});
      tx.from('products').where('sku', 'A1').lockForUpdate().find();
    });
    expect(h.paths.last, endsWith('/query/v1/transaction'));
    final ops = h.sent.last['operations'] as List;
    expect((ops[1]['values'] as List).first['author_id'], {r'$ref': '0.data.0.id'});
    expect(ops[2]['lock'], {'strength': 'update'});
    expect(results.length, 3);

    final failing = harness((_, __) => http.Response(
        jsonEncode({
          'error': {'code': 'foreign_key_violation', 'message': 'no author'}
        }),
        409,
        headers: {'content-type': 'application/json', 'x-plexivo-failed-operation': '1'}));
    await expectLater(failing.db.transaction((tx) {
      tx.from('a').insert({'x': 1});
      tx.from('b').insert({'y': 2});
    }), throwsA(predicate((e) => e is PlexivoException && e.code == 'foreign_key_violation' && e.operation == 1)));
  });

  test('raw SQL and migrations generate safe DDL', () async {
    final h = harness((body, _) {
      final sql = ((body['statements'] as List?)?.first as Map?)?['sql']?.toString() ?? '';
      if (sql.contains('to_regclass')) {
        return {
          'results': [
            {
              'rows': [
                {'ok': false}
              ]
            }
          ]
        };
      }
      return {
        'results': [
          for (final _ in body['statements'] as List) {'rows': [], 'command': 'select', 'row_count': 0}
        ]
      };
    }, 'plx_secret_test');
    final post = h.db.model('posts', columns: {
      'id': 'bigserial primary key',
      'title': {'type': 'text', 'notNull': true},
      'author_id': {'type': 'bigint', 'references': 'authors(id)', 'onDelete': 'cascade', 'index': true},
    }, policies: [
      {
        'name': 'read',
        'for': 'select',
        'to': ['anon'],
        'using': 'true'
      }
    ]);
    final ddl = await h.db.migrator.autoMigrate([post]);
    expect(ddl, [
      'CREATE TABLE IF NOT EXISTS "posts" ("id" bigserial primary key, "title" text NOT NULL, "author_id" bigint REFERENCES "authors" ("id") ON DELETE CASCADE)',
      'CREATE INDEX IF NOT EXISTS "posts_author_id_idx" ON "posts" ("author_id")',
      'ALTER TABLE "posts" ENABLE ROW LEVEL SECURITY',
      'CREATE POLICY "read" ON "posts" AS PERMISSIVE FOR SELECT TO anon USING (true)',
    ]);
    await h.db.raw(r'select * from t where id = $1', [5]);
    expect(h.sent.last['statements'], [
      {
        'sql': r'select * from t where id = $1',
        'params': [5]
      }
    ]);
  });

  test('OAuth PKCE: the S256 challenge out, the verifier back', () async {
    final h = harness((_, __) => {'access_token': 'a', 'refresh_token': 'r'});
    final url = h.db.getOAuthSignInUrl(provider: 'github', redirectTo: 'app://cb');
    expect(url.path, '/client/v1/demo/auth/oauth/github/authorize');
    expect(url.queryParameters['code_challenge_method'], 'S256');
    expect(url.queryParameters['code_challenge'], matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
    final verifier = h.db.oauthCodeVerifier;
    await h.db.exchangeCodeForSession('the-code');
    expect(h.sent.last, {'code': 'the-code', 'code_verifier': verifier});
    expect(h.db.session?['access_token'], 'a');
  });
}
