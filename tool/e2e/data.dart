import 'package:plexivo_client/plexivo_client.dart';

import 'context.dart';
import 'harness.dart';

List<Object?> _ids(Iterable<Map<String, dynamic>> rows) => rows.map((r) => r['id']).toList();

/// CRUD, every filter operator, ordering and paging.
Future<void> dataChecks(Suite t, Ctx c) async {
  final ok = await t.check('data: insert many rows, returned with defaults and generated keys', () async {
    final rows = await c.alice.from('posts').insert([
      {
        'title': 'Postgres at scale',
        'body': 'Indexes and vacuum tuning',
        'status': 'published',
        'likes': 40,
        'rating': 4.5,
        'tags_cache': ['db', 'pg'],
        'scores': [1, 2, 3],
        'meta': {
          'lang': 'en',
          'level': 3,
          'address': {'city': 'Chennai'}
        },
        'published_on': '2026-10-01',
        'published_at': '2026-10-01T10:00:00+05:30',
      },
      {
        'title': 'Flutter tips',
        'body': 'Widgets and state',
        'status': 'published',
        'likes': 12,
        'tags_cache': ['flutter', 'dart'],
        'scores': [5],
        'meta': {'lang': 'hi', 'level': 1}
      },
      {
        'title': 'Draft about Dart',
        'body': 'Isolates and ports',
        'likes': 0,
        'tags_cache': ['dart'],
        'meta': {'lang': 'en', 'level': 2}
      },
      {'title': 'Archived news', 'body': 'Old things', 'status': 'archived', 'likes': 3},
      {
        'title': 'Rust and Postgres',
        'body': 'Drivers compared',
        'status': 'published',
        'likes': 25,
        'rating': 3.25,
        'tags_cache': ['pg', 'rust']
      },
      {'title': 'Café crème ✓', 'body': 'Unicode 漢字 and emoji 🚀', 'status': 'published', 'likes': 7},
    ]);
    expect(rows.length == 6 && rows.count == 6, 'six rows back', rows.count);
    for (var i = 0; i < 6; i++) {
      c.posts['p${i + 1}'] = rows[i];
    }
    final p3 = c.posts['p3']!;
    expect(p3['status'] == 'draft' && p3['author_id'] == c.aliceId && p3['id'] is int && p3['external_id'] is String, 'defaults filled', p3);
    expect(c.posts['p6']!['title'] == 'Café crème ✓' && c.posts['p6']!['body'] == 'Unicode 漢字 and emoji 🚀', 'unicode round trip');
    c.bobPublic = await c.bob.from('posts').create({'title': 'Bob in public', 'status': 'published', 'likes': 50});
    c.bobDraft = await c.bob.from('posts').create({'title': 'Bob private draft', 'likes': 99});
  });
  if (!ok) {
    t.note('the posts could not be created: the data checks need them');
    t.finish();
  }
  final p = c.posts.map((k, v) => MapEntry(k, v['id']));
  final mine = c.alicePosts;

  await t.check('filters: eq, neq, gt, gte, lt, lte', () async {
    expect((await mine().eq('status', 'published')).length == 4, 'eq');
    expect((await mine().neq('status', 'draft')).length == 5, 'neq');
    expectEq(_ids(await mine().gt('likes', 12).order('id')), [p['p1'], p['p5']], 'gt');
    expect((await mine().gte('likes', 12)).length == 3, 'gte');
    expectEq(_ids(await mine().lt('likes', 7).order('id')), [p['p3'], p['p4']], 'lt');
    expect((await mine().lte('likes', 7)).length == 3, 'lte');
    expect((await mine().where('likes', '>', 12).where('likes', '<=', 40)).length == 2, 'GORM operators');
  });

  await t.check('filters: like, ilike, match, imatch', () async {
    expectEq(_ids(await mine().like('title', 'Post%')), [p['p1']], 'like');
    expectEq(_ids(await mine().ilike('title', '%postgres%').order('id')), [p['p1'], p['p5']], 'ilike');
    expectEq(_ids(await mine().where('title', 'match', r'^[A-Z][a-z]+ at')), [p['p1']], 'match');
    expectEq(_ids(await mine().where('title', 'imatch', 'FLUTTER')), [p['p2']], 'imatch');
    expect((await mine().where('title', 'not like', 'P%')).length == 5, 'not like');
  });

  await t.check('filters: in, is, not, null', () async {
    expect((await mine().inFilter('status', ['draft', 'archived'])).length == 2, 'in');
    expect((await mine().whereNotIn('status', ['draft', 'archived'])).length == 4, 'not in');
    expect((await mine().isFilter('rating', null)).length == 4, 'is null');
    expect((await mine().whereNotNull('rating')).length == 2, 'is not null');
    expect((await mine().not('status', 'eq', 'published')).length == 2, 'not');
    expect((await mine().whereNot('likes', '>', 10)).length == 3, 'whereNot');
    expect((await mine().where('rating', null)).length == 4, 'where(col, null)');
    expect((await mine().filter('status', 'in', ['draft', 'archived'])).length == 2, 'filter(in)');
    expect((await mine().filter('likes', 'not.gt', 10)).length == 3, 'filter(not.gt)');
  });

  await t.check('filters: arrays and json (cs, cd, ov)', () async {
    expectEq(_ids(await mine().contains('tags_cache', ['pg']).order('id')), [p['p1'], p['p5']], 'cs array');
    expectEq(_ids(await mine().contains('meta', {'lang': 'en'}).order('id')), [p['p1'], p['p3']], 'cs json');
    expect((await mine().containedBy('tags_cache', ['dart', 'flutter', 'db', 'pg'])).length == 5, 'cd array (empty arrays too)');
    expectEq(_ids(await mine().overlaps('tags_cache', ['rust', 'flutter']).order('id')), [p['p2'], p['p5']], 'ov');
    expectEq(_ids(await mine().contains('scores', [2, 3])), [p['p1']], 'int[] contains');
  });

  await t.check('filters: full-text search on a tsvector column (fts, plfts, phfts, wfts)', () async {
    expectEq(_ids(await mine().textSearch('search', 'vacuum')), [p['p1']], 'fts');
    expectEq(_ids(await mine().textSearch('search', 'widgets state', type: 'plain')), [p['p2']], 'plfts');
    expectEq(_ids(await mine().textSearch('search', 'vacuum tuning', type: 'phrase', config: 'english')), [p['p1']], 'phfts');
    expectEq(_ids(await mine().textSearch('search', '"postgres" -rust', type: 'websearch')), [p['p1']], 'wfts');
    expectEq(_ids(await mine().whereSearch('search', 'drivers', 'english')), [p['p5']], 'whereSearch');
  });

  await t.check('filters: or/and groups, PostgREST strings and GORM closures', () async {
    expect((await mine().or('likes.gte.25,status.eq.draft')).length == 3, 'or()');
    expectEq(_ids(await mine().or('status.eq.archived,and(likes.gte.10,likes.lte.20)').order('id')), [p['p2'], p['p4']], 'or with nested and');
    expect((await mine().where((PlexivoConditions q) => q.where('likes', '>', 20).orWhere('status', 'draft'))).length == 3, 'GORM group');
    expect((await mine().where('status', 'published').orWhere('likes', 0)).length >= 5, 'AND binds tighter than OR');
    expect((await mine().whereBetween('likes', 5, 15)).length == 2, 'between');
    expect((await mine().whereNotBetween('likes', 5, 15)).length == 4, 'not between');
    expect((await mine().match({'status': 'published', 'likes': 12})).length == 1, 'match()');
  });

  await t.check('filters: json paths', () async {
    expectEq(_ids(await mine().whereJson('meta', 'address.city', 'Chennai')), [p['p1']], 'nested path');
    expectEq(_ids(await mine().whereJson('meta', 'level', '>=', 2).order('id')), [p['p1'], p['p3']], 'numeric compare');
    expectEq(_ids(await mine().whereJson('meta', ['lang'], 'in', ['hi'])), [p['p2']], 'list path, in');
  });

  await t.check('order: asc/desc, several keys, nulls first and last', () async {
    expect((await mine().order('likes', 'desc').first())['id'] == p['p1'], 'desc');
    expect((await mine().order('rating', 'asc', 'first').first())['rating'] == null, 'nulls first');
    final last = await mine().order('rating', 'asc', 'last').limit(2);
    expect(last[0]['id'] == p['p5'] && last[1]['id'] == p['p1'], 'nulls last', last);
    expectEq(_ids(await mine().order('status').order('likes', 'desc').limit(3)), [p['p3'], p['p1'], p['p5']], 'two keys (enum order, then likes)');
    expect((await mine().order('title desc').first())['id'] == p['p5'], "'title desc' form");
    expect((await mine().latest('id').first())['id'] == p['p6'] && (await mine().oldest('id').first())['id'] == p['p1'], 'latest/oldest');
  });

  await t.check('order: by a to-one related column (dotted, with a hint, through a model relation)', () async {
    final visible = c.alice.from('posts').inFilter('id', [p['p1'], p['p2'], c.bobPublic['id']]);
    final byAuthor = await visible.order('profiles!posts_author_fk.username', 'desc').order('id');
    expect(byAuthor.first['id'] == c.bobPublic['id'], "bob's post first (bob_ > alice_)", _ids(byAuthor));
    final asc = await visible.order('profiles!posts_author_fk.username', 'asc', 'last').order('id');
    expectEq(_ids(asc), [p['p1'], p['p2'], c.bobPublic['id']], 'ascending');
    final m = c.client();
    m.model('posts', relations: {'author': const PlexivoRelation.belongsTo('profiles', foreignKey: 'author_id', constraint: 'posts_author_fk')});
    final viaModel = await m.from('posts').inFilter('id', [p['p1'], c.bobPublic['id']]).order('author.username', 'desc');
    expect(viaModel.first['id'] == c.bobPublic['id'], 'model relation name', _ids(viaModel));
    await c.alice.from('posts').where('id', p['p2']).update({'editor_id': c.bobId});
    final byEditor = await c.alice.from('posts').inFilter('id', [p['p1'], p['p2']]).order('profiles!posts_editor_fk.username', 'asc', 'first');
    expectEq(_ids(byEditor), [p['p1'], p['p2']], 'a missing related row sorts as null (nulls first)');
    await refused(c.alice.from('posts').order('comments.body'), code: 'invalid_request', status: 400, what: 'to-many order');
  });

  await t.check('paging: limit, offset, range, page, paginate, count, head', () async {
    final base = mine().order('id');
    expectEq(_ids(await base.limit(2).offset(1)), [p['p2'], p['p3']], 'limit+offset');
    expectEq(_ids(await base.range(0, 2)), [p['p1'], p['p2'], p['p3']], 'range');
    expectEq(_ids(await base.page(2, 2)), [p['p3'], p['p4']], 'page');
    final pg = await base.paginate(page: 2, perPage: 4);
    expect(pg.total == 6 && pg.totalPages == 2 && pg.data.length == 2 && pg.page == 2, 'paginate', [pg.total, pg.totalPages, pg.data.length]);
    final counted = await mine().select('id', 'exact').limit(1);
    expect(counted.length == 1 && counted.count == 6, 'select with exact count', counted.count);
    final head = await mine().select('*', 'exact', true);
    expect(head.isEmpty && head.count == 6, 'head: count only', head.count);
    expect(await mine().count() == 6, 'count()');
    expect(await mine().where('likes', '>', 1000).exists() == false && await mine().exists(), 'exists()');
    expectEq(await base.pluck('likes'), [40, 12, 0, 3, 25, 7], 'pluck');
  });

  await t.check('reads: first, last, take, sole, firstOrNull, single, maybeSingle, find(ids)', () async {
    expect((await mine().first())['id'] == p['p1'] && (await mine().last())['id'] == p['p6'], 'first/last by key');
    expect((await mine().first(p['p3']))['title'] == 'Draft about Dart', 'first(id)');
    expect((await mine().where('likes', 40).take())['id'] == p['p1'], 'take');
    expect((await mine().where('likes', 40).sole())['id'] == p['p1'], 'sole');
    await refused(mine().sole(), code: 'multiple_rows', status: 406);
    await refused(mine().first(-1), code: 'record_not_found', status: 404);
    expect(await mine().firstOrNull(-1) == null, 'firstOrNull');
    expect((await mine().eq('likes', 12).single()).data?['id'] == p['p2'], 'single');
    expect((await mine().eq('likes', -5).maybeSingle()).data == null, 'maybeSingle');
    expect((await mine().find([p['p1'], p['p2']])).length == 2, 'find(ids)');
    final cols = await mine().select('id, title as heading, likes::text').eq('id', p['p1']).single();
    expect(cols.data?['heading'] == 'Postgres at scale' && cols.data?['likes'] == '40', 'aliases and ::text', cols.data);
    final counted = <int>[];
    await for (final row in mine().each()) {
      counted.add(row['id'] as int);
    }
    expect(counted.length == 6, 'each() streams every row');
  });

  await t.check('writes: create, update by filter, updateById, increment, delete, returning minimal', () async {
    final row = await c.alice.from('posts').create({'title': 'Temporary'});
    final updated = await c.alice.from('posts').update({'body': 'changed'}).eq('id', row['id']);
    expect(updated.length == 1 && updated.first['body'] == 'changed', 'update returns rows', updated);
    expect((await c.alice.from('posts').updateById(row['id'] as Object, {'likes': 2}))['likes'] == 2, 'updateById');
    expect((await c.alice.from('posts').where('id', row['id']).increment('likes', by: 3)).first['likes'] == 5, 'increment');
    expect((await c.alice.from('posts').where('id', row['id']).decrement('likes')).first['likes'] == 4, 'decrement');
    final minimal = await c.alice.from('posts').where('id', row['id']).returning('minimal').update({'body': 'quiet'});
    expect(minimal.isEmpty && minimal.count == 1, 'returning minimal keeps the count', minimal.count);
    final inserted = await c.alice.from('posts').insert({'title': 'One row'}).select().single();
    expect(inserted.data?['title'] == 'One row', 'insert().select().single()');
    expect((await c.alice.from('posts').delete().eq('id', inserted.data!['id'])).length == 1, 'delete returns rows');
    expect((await c.alice.from('posts').deleteById(row['id'] as Object))['id'] == row['id'], 'deleteById');
    await refused(c.alice.from('posts').update({'title': 'all'}), code: 'missing_where');
    await refused(c.alice.from('posts').delete(), code: 'missing_where');
    expect(await mine().count() == 6, 'back to six');
  });
}
