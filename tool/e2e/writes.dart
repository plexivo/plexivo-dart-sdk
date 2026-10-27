import 'package:plexivo_client/plexivo_client.dart';

import 'context.dart';
import 'harness.dart';

/// Upserts, bulk writes past 1,000 rows, transactions, raw SQL, RPC and types.
Future<void> writeChecks(Suite t, Ctx c) async {
  await t.check('upsert: merge on a composite unique key (on_conflict)', () async {
    final first = await c.alice.from('products').upsert({'sku': 'A1', 'region': 'IN', 'name': 'Kettle', 'price': 10}, onConflict: 'owner_id,sku,region');
    final again = await c.alice
        .from('products')
        .upsert({'owner_id': c.aliceId, 'sku': 'A1', 'region': 'IN', 'name': 'Kettle 2', 'price': 12}, onConflict: ['owner_id', 'sku', 'region']);
    expect(first.single['id'] == again.single['id'] && again.single['name'] == 'Kettle 2' && again.single['price'] == 12, 'one row, merged', again);
    await c.alice
        .from('products')
        .upsert({'owner_id': c.aliceId, 'sku': 'A1', 'region': 'GB', 'name': 'Kettle UK', 'price': 11}, onConflict: 'owner_id,sku,region');
    expect(await c.alice.from('products').count() == 2, 'a different region is a new row');
  });

  await t.check('upsert: update only chosen columns; ignore keeps the existing row', () async {
    final r = await c.alice
        .from('products')
        .upsert({'owner_id': c.aliceId, 'sku': 'A1', 'region': 'IN', 'name': 'NOT CHANGED', 'price': 15}, onConflict: 'owner_id,sku,region', update: ['price']);
    expect(r.single['name'] == 'Kettle 2' && r.single['price'] == 15, 'update_columns', r);
    final ignored = await c.alice
        .from('products')
        .upsert({'owner_id': c.aliceId, 'sku': 'A1', 'region': 'IN', 'name': 'x', 'price': 99}, onConflict: 'owner_id,sku,region', ignore: true);
    expect(ignored.isEmpty, 'ignore returns no row', ignored);
    expect((await c.alice.from('products').where({'sku': 'A1', 'region': 'IN'}).first())['price'] == 15, 'kept');
    final saved = await c.alice.from('products').save({
      ...(await c.alice.from('products').where({'sku': 'A1', 'region': 'GB'}).first()),
      'stock': 4
    });
    expect(saved['stock'] == 4, 'save() with a key updates', saved);
    final bulk = await c.alice.from('products').upsert([
      {'owner_id': c.aliceId, 'sku': 'B1', 'region': 'IN', 'name': 'Pan', 'price': 5},
      {'owner_id': c.aliceId, 'sku': 'A1', 'region': 'GB', 'name': 'Kettle UK', 'price': 13},
    ], onConflict: 'owner_id,sku,region');
    expect(bulk.length == 2 && await c.alice.from('products').count() == 3, 'bulk upsert inserts and merges');
  });

  await t.check('bulk: 2,500 rows in batches, update and delete hundreds at once, refusal above 1,000 in one request', () async {
    final rows = [
      for (var i = 0; i < 2500; i++) {'n': i, 'kind': i.isEven ? 'even' : 'odd'}
    ];
    final inserted = await c.alice.from('events').createInBatches(rows, 1000);
    expect(inserted.length == 2500 && await c.alice.from('events').count() == 2500, 'all rows', inserted.length);
    final updated = await c.alice.from('events').where('n', '<', 800).returning('minimal').update({'kind': 'early'});
    expect(updated.count == 800, 'bulk update', updated.count);
    final deleted = await c.alice.from('events').where('kind', 'odd').returning('minimal').delete();
    expect(deleted.count == 850, 'bulk delete', deleted.count);
    var batches = 0, seen = 0;
    await c.alice.from('events').findInBatches(500, (batch, i) {
      batches++;
      seen += batch.length;
      return true;
    });
    expect(seen == 1650 && batches == 4, 'findInBatches reads past 1,000', [seen, batches]);
    await refused(
        c.alice.from('events').insert([
          for (var i = 0; i < 1001; i++) {'n': i}
        ]),
        code: 'invalid_request',
        status: 400);
    expect(await c.alice.from('events').count() == 1650, 'nothing from the refused insert');
    expect(await c.bob.from('events').count() == 0, "bob sees none of alice's events");
  }, timeout: const Duration(minutes: 3));

  await t.check('transactions: references between steps, results in order', () async {
    final results = await c.alice.transaction((tx) {
      final post = tx.from('posts').insert({'title': 'From a transaction', 'status': 'published'});
      tx.from('comments').insert({'post_id': post.ref('id'), 'body': 'first!'});
      tx.from('post_tags').insert({'post_id': post.ref('id'), 'tag_id': c.tags['pg']});
      tx.from('posts').where('id', c.posts['p1']!['id']).lockForUpdate().find();
    });
    final post = (results[0] as List).first as Map;
    expect(((results[1] as List).first as Map)['post_id'] == post['id'], 'the comment references the new post', results);
    expect((results[3] as List).length == 1, 'a locked read in the same transaction');
    await c.alice.from('posts').deleteById(post['id'] as Object);
  });

  await t.check('transactions: one failing step rolls everything back and names the step', () async {
    final before = await c.alice.from('posts').count();
    final e = await refused(c.alice.transaction((tx) {
      tx.from('posts').insert({'title': 'Ghost'});
      tx.from('comments').insert({'post_id': 987654321, 'body': 'orphan'});
    }));
    expect(e.operation == 1 && (e.code == 'foreign_key_violation' || e.code == 'permission_denied'), 'step 1 failed', e);
    expect(await c.alice.from('posts').count() == before && await c.alice.from('posts').eq('title', 'Ghost').count() == 0, 'nothing written');
  });

  await t.check('rpc: scalar, void, and as the caller (as in 0.3)', () async {
    expect(await c.anon.rpc('add_numbers', {'a': 2, 'b': 3}) == 5, 'scalar');
    expect(await c.alice.rpc('my_post_count') == 6, 'runs as the caller (auth.uid())');
    expect(await c.bob.rpc('my_post_count') == 2, 'another caller');
    expect(await c.alice.rpc('touch_bio', {'new_bio': 'Writes about Postgres'}) == null, 'void returns null');
    expect((await c.anon.from('profiles').eq('id', c.aliceId).first())['bio'] == 'Writes about Postgres', 'the void function wrote');
    final rows = await c.alice.rpc('search_posts', {'q': 'postgres'});
    expect(rows is List && rows.length == 2, 'set-returning, unchained', rows);
    await refused(c.alice.rpc('not_exposed'), code: 'function_not_exposed', status: 404);
    await refused(c.alice.rpc('add_numbers', {'a': 1, 'nope': 2}), status: 400);
  });

  await t.check('rpc: set-returning with filters, order, paging, count, single and embeds', () async {
    final hits = await c.alice.rpc('search_posts', {'q': 'postgres'}).select('id, title, likes', 'exact').gte('likes', 30).order('likes', 'desc');
    expect(hits is PlexivoResult && hits.length == 1 && hits.first['title'] == 'Postgres at scale' && hits.count == 1, 'filtered', hits);
    final paged = await c.alice.rpc('search_posts', {'q': 'postgres'}).select('id', 'exact').order('id').range(1, 1) as PlexivoResult;
    expect(paged.length == 1 && paged.count == 2 && paged.first['id'] == c.posts['p5']!['id'], 'range + count', [paged, paged.count]);
    final top = await c.alice.rpc('search_posts', {'q': 'postgres'}).order('likes', 'desc').limit(1).single();
    expect(top.data?['id'] == c.posts['p1']!['id'], 'single', top.data);
    final none = await c.alice.rpc('search_posts', {'q': 'postgres'}).eq('likes', -1).maybeSingle();
    expect(none.data == null, 'maybeSingle');
    final embedded = await c.alice.rpc('search_posts', {'q': 'postgres'}).select('id, author:profiles!posts_author_fk(username)').order('id');
    expect(((embedded as List).first as Map)['author']['username'] == 'alice_${c.n}', 'embeds through the returned table', embedded);
    final stats = await c.alice.rpc('post_stats', {'min_likes': 10}).select('author, likes').eq('author', 'alice_${c.n}').single();
    expect(stats.data?['likes'] == 77, 'RETURNS TABLE with a filter', stats.data);
    final orWhere = await c.alice.rpc('search_posts', {'q': 'postgres'}).where('likes', '>', 30).orWhere('title', 'Rust and Postgres').order('id');
    expect((orWhere as List).length == 2, 'GORM-style filters on rpc', orWhere);
  });

  await t.check('raw SQL with the secret key: parameters, types, rows', () async {
    final rows = await c.server.raw(r'select $1::int + 1 as n, $2::text as t, $3::boolean as b, $4::jsonb as j, $5::int[] as a, $6::text is null as isnull', [
      41,
      "o'brien; drop table posts; --",
      true,
      {
        'k': [1, 2]
      },
      [1, 2, 3],
      null
    ]);
    final r = rows.single;
    expect(r['n'] == 42 && r['t'] == "o'brien; drop table posts; --" && r['b'] == true && r['isnull'] == true, 'scalars', r);
    expectEq(
        r['j'],
        {
          'k': [1, 2]
        },
        'jsonb');
    expectEq(r['a'], [1, 2, 3], 'int[]');
    final count = await c.server.raw('select count(*)::int as n from posts');
    expect((count.single['n'] as int) >= 8, 'the secret key reads every row (no row-level security)', count);
    final ex = await c.server.exec(r'update profiles set bio = $1 where id = $2', ['from the server', c.bobId]);
    expect(ex.rowCount == 1 && ex.command?.toUpperCase() == 'UPDATE', 'exec', ex);
  });

  await t.check('raw SQL: a multi-statement transaction commits together, and rolls back together', () async {
    final results = await c.server.sql.transaction([
      'create temporary table if not exists scratch (n int) on commit drop',
      {
        'sql': r'insert into notes (owner_id, body) values ($1, $2)',
        'params': [c.carolId, 'from a server transaction']
      },
      {
        'sql': r'select count(*)::int as n from notes where owner_id = $1',
        'params': [c.carolId]
      },
    ]);
    expect(((results.last['rows'] as List).single as Map)['n'] == 1, 'the third statement sees the second', results.last);
    await refused(
        c.server.sql.transaction([
          {
            'sql': r'insert into notes (owner_id, body) values ($1, $2)',
            'params': [c.carolId, 'should vanish']
          },
          'select 1/0',
        ]),
        what: 'a failing statement');
    final left = await c.server.raw(r'select count(*)::int as n from notes where body = $1', ['should vanish']);
    expect(left.single['n'] == 0, 'rolled back', left);
    expect((await c.carol.from('notes').select('body')).any((r) => r['body'] == 'from a server transaction'), 'carol reads the server-written note');
  });

  await t.check('raw SQL is refused for the publishable key and for signed-in users', () async {
    await refused(c.anon.raw('select 1'), code: 'secret_key_required', status: 403);
    await refused(c.alice.raw('select 1'), code: 'secret_key_required', status: 403);
    await refused(c.alice.sql.transaction(['drop table posts']), code: 'secret_key_required', status: 403);
    expect(await c.alice.from('posts').count() > 0, 'posts survive');
  });

  await t.check('types round-trip: json, jsonb, arrays, enum, uuid, timestamptz, date, numeric, bigint', () async {
    final row = await c.alice.from('posts').create({
      'title': 'Types',
      'status': 'archived',
      'price': '12345678901234567890.0123456789',
      'views': 9007199254740993,
      'tags_cache': ['a b', 'c"d', r'e\f', 'ü'],
      'scores': [-1, 0, 2147483647],
      'meta': {
        'nested': {
          'list': [
            1,
            'two',
            null,
            true,
            {'x': 1.5}
          ]
        }
      },
      'doc': {'raw': 'json'},
      'published_on': '2026-02-28',
      'published_at': DateTime.utc(2026, 10, 28, 4, 30),
      'external_id': '6f1c2c1e-6a8b-4c39-9a1e-2b3f4d5e6a7b',
    });
    final back = await c.alice
        .from('posts')
        .select('id, status, price::text, views, tags_cache, scores, meta, doc, published_on, published_at, external_id')
        .eq('id', row['id'])
        .single();
    final d = back.data!;
    expect(d['status'] == 'archived', 'enum', d['status']);
    expect(d['price'] == '12345678901234567890.0123456789', 'numeric precision through ::text', d['price']);
    expect(d['views'] == 9007199254740993, 'bigint above 2^53', d['views']);
    expectEq(d['tags_cache'], ['a b', 'c"d', r'e\f', 'ü'], 'text[] with quotes and backslashes');
    expectEq(d['scores'], [-1, 0, 2147483647], 'int[]');
    expectEq(
        d['meta'],
        {
          'nested': {
            'list': [
              1,
              'two',
              null,
              true,
              {'x': 1.5}
            ]
          }
        },
        'jsonb');
    expectEq(d['doc'], {'raw': 'json'}, 'json');
    expect(d['published_on'] == '2026-02-28', 'date', d['published_on']);
    expect(DateTime.parse(d['published_at'] as String).isAtSameMomentAs(DateTime.utc(2026, 10, 28, 4, 30)), 'timestamptz', d['published_at']);
    expect(d['external_id'] == '6f1c2c1e-6a8b-4c39-9a1e-2b3f4d5e6a7b', 'uuid');
    final ist = await c.alice.from('posts').update({'published_at': '2026-10-28T10:00:00+05:30'}).eq('id', row['id']);
    expect(DateTime.parse(ist.single['published_at'] as String).isAtSameMomentAs(DateTime.utc(2026, 10, 28, 4, 30)), 'a +05:30 offset is the same instant',
        ist.single['published_at']);
    expect((await c.alice.from('posts').where('published_at', '>=', DateTime.utc(2026, 10, 28)).where('id', row['id'])).length == 1, 'DateTime filter');
    expect((await c.alice.from('posts').where('external_id', '6f1c2c1e-6a8b-4c39-9a1e-2b3f4d5e6a7b')).length == 1, 'uuid filter');
    await c.alice.from('posts').deleteById(row['id'] as Object);
  });
}
