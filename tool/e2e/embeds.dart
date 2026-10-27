import 'package:plexivo_client/plexivo_client.dart';

import 'context.dart';
import 'harness.dart';

/// Joins and embeds of every kind, GORM-style and Supabase-style, and aggregates.
Future<void> embedChecks(Suite t, Ctx c) async {
  final p = c.posts.map((k, v) => MapEntry(k, v['id']));
  late final PlexivoClient orm;

  final ok = await t.check('embeds: comments and tags for the posts', () async {
    await c.bob.from('comments').insert({'post_id': p['p1'], 'body': 'Great read', 'approved': true});
    await c.carol.from('comments').insert({'post_id': p['p1'], 'body': 'Needs benchmarks'});
    await c.alice.from('comments').insert({'post_id': p['p2'], 'body': 'Thanks all', 'approved': true});
    await refused(c.bob.from('comments').insert({'post_id': p['p3'], 'body': 'on a draft I cannot see'}), code: 'permission_denied', status: 403);
    final tags = await c.alice.from('tags').insert([
      {'name': 'db-${c.n}'},
      {'name': 'pg-${c.n}'},
      {'name': 'flutter-${c.n}'},
      {'name': 'rust-${c.n}'},
    ]);
    for (final tag in tags) {
      c.tags[(tag['name'] as String).split('-').first] = tag['id'] as int;
    }
    await c.alice.from('post_tags').insert([
      {'post_id': p['p1'], 'tag_id': c.tags['db']},
      {'post_id': p['p1'], 'tag_id': c.tags['pg']},
      {'post_id': p['p2'], 'tag_id': c.tags['flutter']},
      {'post_id': p['p5'], 'tag_id': c.tags['pg']},
      {'post_id': p['p5'], 'tag_id': c.tags['rust']},
    ]);
    orm = c.client();
    await orm.signInWithPassword(email: c.email('alice'), password: password);
    orm.model('posts', relations: {
      'author': const PlexivoRelation.belongsTo('profiles', foreignKey: 'author_id', constraint: 'posts_author_fk'),
      'editor': const PlexivoRelation.belongsTo('profiles', foreignKey: 'editor_id', constraint: 'posts_editor_fk'),
      'comments': const PlexivoRelation.hasMany('comments', foreignKey: 'post_id'),
      'tags': const PlexivoRelation.manyToMany('tags', through: 'post_tags', foreignKey: 'post_id', otherKey: 'tag_id'),
    });
    orm.model('comments', relations: {
      'author': const PlexivoRelation.belongsTo('profiles', foreignKey: 'author_id'),
      'post': const PlexivoRelation.belongsTo('posts', foreignKey: 'post_id'),
    });
    orm.model('profiles', relations: {
      'posts': const PlexivoRelation.hasMany('posts', foreignKey: 'author_id', constraint: 'posts_author_fk'),
    });
  });
  if (!ok) return;

  await t.check('embeds: many-to-one (Supabase string and GORM preload), with FK hints', () async {
    final s = await c.alice.from('posts').select('id, title, author:profiles!posts_author_fk(username, country)').eq('id', p['p1']).single();
    expectEq(s.data?['author'], {'username': 'alice_${c.n}', 'country': 'IN'}, 'Supabase-style');
    final g = await orm.from('posts').preload('author', (PlexivoEmbed a) => a.select('username')).preload('editor').eq('id', p['p2']).single();
    expect((g.data?['author'] as Map)['username'] == 'alice_${c.n}' && (g.data?['editor'] as Map)['username'] == 'bob_${c.n}', 'GORM-style', g.data);
    final none = await orm.from('posts').preload('editor').eq('id', p['p1']).single();
    expect(none.data?['editor'] == null, 'a missing to-one row is null', none.data);
    await refused(c.alice.from('posts').select('id, profiles(username)'), status: 400, what: 'an ambiguous embed without a hint');
  });

  await t.check('embeds: one-to-many, filtered, ordered and limited', () async {
    final all = await c.alice.from('posts').select('id, comments(id, body)').eq('id', p['p1']).single();
    expect((all.data?['comments'] as List).length == 2, 'both comments', all.data);
    final some =
        await orm.from('posts').preload('comments', (PlexivoEmbed q) => q.where('approved', true).order('id', 'desc').limit(1)).eq('id', p['p1']).single();
    final list = some.data?['comments'] as List;
    expect(list.length == 1 && (list.first as Map)['body'] == 'Great read', 'filtered + limited', list);
    final ordered = await c.alice.from('posts').select('id, comments(id, body)').eq('id', p['p1']).orderReferenced('comments', 'id', 'desc').single();
    final bodies = (ordered.data?['comments'] as List).map((x) => (x as Map)['body']).toList();
    expectEq(bodies, ['Needs benchmarks', 'Great read'], 'orderReferenced');
    final empty = await orm.from('posts').preload('comments').eq('id', p['p4']).single();
    expectEq(empty.data?['comments'], [], 'left join: no comments is an empty list');
  });

  await t.check('embeds: many-to-many through the link table (GORM model and Supabase nested string)', () async {
    final g = await orm.from('posts').preload('tags', (PlexivoEmbed q) => q.order('name')).eq('id', p['p1']).single();
    expectEq((g.data?['tags'] as List).map((x) => (x as Map)['name']).toList(), ['db-${c.n}', 'pg-${c.n}'], 'model manyToMany');
    final s = await c.alice.from('posts').select('id, post_tags(tags(name))').eq('id', p['p5']).single();
    final names = (s.data?['post_tags'] as List).map((x) => ((x as Map)['tags'] as Map)['name']).toSet();
    expect(names.containsAll(['pg-${c.n}', 'rust-${c.n}']) && names.length == 2, 'Supabase nested embed through post_tags', s.data);
    final tagged = await orm.from('posts').whereHas('tags', (PlexivoEmbed q) => q.where('name', 'pg-${c.n}')).order('id').pluck('id');
    expectEq(tagged, [p['p1'], p['p5']], 'whereHas through many-to-many');
  });

  await t.check('embeds: nested three deep (profiles → posts → comments → author)', () async {
    final r =
        await c.alice.from('profiles').select('username, posts!posts_author_fk(title, comments(body, author:profiles(username)))').eq('id', c.aliceId).single();
    final posts = r.data?['posts'] as List;
    final p1 = posts.cast<Map>().firstWhere((x) => x['title'] == 'Postgres at scale');
    final authors = (p1['comments'] as List).map((x) => ((x as Map)['author'] as Map)['username']).toSet();
    expect(authors.length == 2 && authors.contains('bob_${c.n}') && authors.contains('carol_${c.n}'), 'comment authors at depth 3', r.data);
  });

  await t.check('embeds: preload by path (GORM Preload("Comments.Author"))', () async {
    final r = await orm.from('posts').preload('comments.author', (PlexivoEmbed a) => a.select('username')).eq('id', p['p1']).single();
    final authors = (r.data?['comments'] as List).map((x) => ((x as Map)['author'] as Map)['username']).toSet();
    expect(authors.length == 2 && authors.contains('bob_${c.n}') && authors.contains('carol_${c.n}'), 'nested preload', r.data);
    final merged = await orm
        .from('posts')
        .preload('comments', (PlexivoEmbed q) => q.where('approved', true))
        .preload('comments.author')
        .preload('comments.post', (PlexivoEmbed q) => q.select('title'))
        .eq('id', p['p1'])
        .single();
    final list = merged.data?['comments'] as List;
    expect(
        list.length == 1 &&
            ((list.first as Map)['author'] as Map)['username'] == 'bob_${c.n}' &&
            ((list.first as Map)['post'] as Map)['title'] == 'Postgres at scale',
        'paths merge into the filtered embed',
        list);
  });

  await t.check('joins: inner join (joins, !inner) and filters on related rows', () async {
    final withComments = await orm.from('posts').joins('comments').eq('author_id', c.aliceId).order('id').pluck('id');
    expectEq(withComments, [p['p1'], p['p2']], 'joins()');
    final approvedOnly = await orm.from('posts').joins('comments', (PlexivoEmbed q) => q.where('approved', false)).eq('author_id', c.aliceId).pluck('id');
    expectEq(approvedOnly, [p['p1']], 'joins() with a filter');
    final s = await c.alice.from('posts').select('id, comments!inner(id)').eq('author_id', c.aliceId).order('id');
    expectEq(s.map((r) => r['id']).toList(), [p['p1'], p['p2']], '!inner');
    final authored = await orm.from('posts').joins('comments.author', (PlexivoEmbed q) => q.where('country', 'GB')).eq('author_id', c.aliceId).pluck('id');
    expectEq(authored, [p['p1']], 'joins by path: posts with a comment by someone in GB');
  });

  await t.check('whereHas / whereDoesntHave / orWhereHas', () async {
    expectEq(await orm.from('posts').whereHas('comments', (PlexivoEmbed q) => q.where('approved', false)).pluck('id'), [p['p1']], 'whereHas');
    final without = await orm.from('posts').whereDoesntHave('comments').eq('author_id', c.aliceId).order('id').pluck('id');
    expectEq(without, [p['p3'], p['p4'], p['p5'], p['p6']], 'whereDoesntHave');
    final either =
        await orm.from('posts').eq('author_id', c.aliceId).where((PlexivoConditions q) => q.whereHas('tags').orWhere('likes', 7)).order('id').pluck('id');
    expectEq(either, [p['p1'], p['p2'], p['p5'], p['p6']], 'whereHas inside an OR group');
  });

  await t.check('subquery IN / NOT IN (GORM Where("author_id IN (?)", subquery)), under row-level security', () async {
    final gb = c.alice.from('profiles').select('id').eq('country', 'GB');
    final fromGb = await c.alice.from('posts').whereIn('author_id', gb).pluck('id');
    expectEq(fromGb, [c.bobPublic['id']], 'IN: only what alice may see of bob');
    final notGb = await c.alice.from('posts').whereNotIn('author_id', gb).count();
    expect(notGb == 6, 'NOT IN', notGb);
    final commented = await c.alice.from('posts').whereIn('id', c.alice.from('comments').select('post_id').eq('approved', true)).order('id').pluck('id');
    expectEq(commented, [p['p1'], p['p2']], 'IN over another table');
    final hiddenDrafts = await c.bob.from('profiles').whereIn('id', c.bob.from('posts').select('author_id').eq('status', 'draft')).pluck('id');
    expectEq(hiddenDrafts, [c.bobId], "the subquery runs as bob: alice's drafts stay invisible");
    await refused(c.alice.from('posts').whereIn('author_id', c.alice.from('hidden').select('id')), code: 'table_not_exposed');
  });

  await t.check('aggregates: count, sum, avg, min, max; groupBy with having and order; withCount; withAggregate', () async {
    final mine = c.alicePosts;
    expect(await mine().sum('likes') == 87, 'sum');
    expect(((await mine().avg('likes'))! - 14.5).abs() < 1e-9, 'avg');
    expect(await mine().min('likes') == 0 && await mine().max('likes') == 40, 'min/max');
    final groups = await mine().groupBy('status').having('count', '>', 1).order('count(*)', 'desc').aggregate({
      'count': true,
      'sum': ['likes']
    }) as List;
    expect(groups.length == 1 && groups.first['status'] == 'published' && groups.first['count'] == 4, 'grouped', groups);
    final counted = await orm.from('posts').withCount('comments').eq('id', p['p1']).single();
    expect(counted.data?['comments_count'] == 2, 'withCount', counted.data);
    final agg = await orm
        .from('posts')
        .withAggregate('comments', {
          'count': true,
          'max': ['id']
        })
        .eq('id', p['p1'])
        .single();
    expect((agg.data?['comments_aggregate'] as Map)['count'] == 2, 'withAggregate', agg.data);
    final s = await c.alice.from('posts').select('id, comments(count)').eq('id', p['p1']).single();
    expect(((s.data?['comments'] as Map)['count'] as num) == 2, 'Supabase comments(count)', s.data);
  });

  await t.check('views with joins (security_invoker) are the raw-join path for apps', () async {
    final feed = await c.alice.from('post_feed').select('id, title, author, comment_count').order('id');
    final ids = feed.map((r) => r['id']).toSet();
    expect(ids.contains(p['p3']) && ids.contains(c.bobPublic['id']) && !ids.contains(c.bobDraft['id']), "the caller's rows only", ids);
    final row = feed.firstWhere((r) => r['id'] == p['p1']);
    expect(row['author'] == 'alice_${c.n}' && row['comment_count'] == 2, 'joined columns', row);
    final bobFeed = await c.bob.from('post_feed').eq('author', 'alice_${c.n}').pluck('id');
    expect(!bobFeed.contains(p['p3']) && bobFeed.length == 4, "bob sees only alice's published posts", bobFeed);
    final anonFeed = await c.anon.from('post_feed').select('id', 'exact').limit(1);
    expect(anonFeed.count == 5, 'anon sees the published ones', anonFeed.count);
  });
}
