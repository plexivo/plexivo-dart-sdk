// What a Flutter / Dart app does with plexivo_client, run against a live
// Brain over real HTTP and WebSockets with real PostgreSQL. Exits non-zero
// on the first broken expectation. Run by the Brain's SDK end-to-end test:
//   API_URL=… PUBLISHABLE_KEY=… SECRET_KEY=… dart run tool/e2e_frontend.dart
import 'dart:async';
import 'dart:io';

import 'package:plexivo_client/plexivo_client.dart';

void fail(String msg, [Object? extra]) {
  stderr.writeln('FAIL $msg ${extra ?? ''}');
  exit(1);
}

void expect(bool cond, String msg, [Object? extra]) {
  if (!cond) fail(msg, extra);
  stdout.writeln('ok $msg');
}

Future<void> rejects(Future<Object?> f, bool Function(Object e) test, String msg) async {
  try {
    await f;
  } catch (e) {
    expect(test(e), msg, e);
    return;
  }
  fail('$msg (no error)');
}

Future<void> waitFor(bool Function() cond, {int tries = 40}) async {
  for (var i = 0; i < tries && !cond(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

Future<void> main() async {
  final url = Platform.environment['API_URL']!;
  final key = Platform.environment['PUBLISHABLE_KEY']!;
  final secret = Platform.environment['SECRET_KEY'];
  final n = DateTime.now().microsecondsSinceEpoch;

  final visitor = PlexivoClient(url, key);
  final alice = PlexivoClient(url, key);
  final bob = PlexivoClient(url, key);

  // ── the Data API, Supabase-style, row-level security deciding ──────────
  final announcements = await visitor.from('announcements').select('title').order('id');
  expect(announcements.length == 2 && announcements.first['title'] == 'Launch day', 'a visitor reads public rows', announcements);
  expect((await visitor.from('notes').select()).isEmpty, 'a visitor sees no private rows');

  final aliceUser = (await alice.signUp(email: 'dart-alice-$n@example.test', password: 'a long password 123'))['user'] as Map;
  await bob.signUp(email: 'dart-bob-$n@example.test', password: 'a long password 123');

  final created = await alice.from('notes').insert([
    {'body': 'Groceries'},
    {'body': 'Taxes', 'pinned': true},
    {'body': 'Call mum'}
  ]);
  expect(created.count == 3 && created.every((r) => r['owner_id'] == aliceUser['id']), 'a user inserts rows owned by them', created);
  final mine = await alice.from('notes').select('id,body', 'exact').order('id');
  expect(mine.count == 3 && mine.map((r) => r['body']).join(',') == 'Groceries,Taxes,Call mum', 'they read only their own rows, with a count', mine);
  expect((await bob.from('notes').select()).isEmpty, 'another user sees none of them');

  final pinned = await alice.from('notes').select().eq('pinned', true).single();
  expect(pinned.data?['body'] == 'Taxes', 'single() returns the one matching row');
  final either = await alice.from('notes').select('body').or('pinned.is.true,body.eq.Groceries').order('id');
  expect(either.length == 2, 'or() conditions', either);
  final updated = await alice.from('notes').update({'pinned': true}).inFilter('body', ['Groceries', 'Call mum']);
  expect(updated.count == 2, 'update by filter', updated);
  expect((await bob.from('notes').update({'body': 'hacked'}).eq('id', pinned.data!['id'])).count == 0, "another user's update touches nothing");
  await rejects(alice.from('notes').update({'pinned': false}).then((r) => r), (e) => e is PlexivoException && e.code == 'missing_where',
      'an unfiltered update is refused');
  await rejects(visitor.from('notes').insert({'body': 'anon'}).then((r) => r), (e) => e is PlexivoException && e.statusCode == 403,
      'row-level security refuses a visitor write');
  await rejects(alice.from('audit').select().then((r) => r), (e) => e is PlexivoException && e.code == 'table_not_exposed',
      'a table without row-level security is not reachable');
  expect(await alice.rpc('note_count') == 3, 'rpc runs as the caller');
  expect((await alice.from('notes').delete().eq('body', 'Groceries')).count == 1, 'delete by filter');
  final api = await visitor.getApi();
  expect((api['tables'] as List).any((t) => (t as Map)['name'] == 'notes') && !api.containsKey('hidden'), 'the live API description');

  // ── guests, organisations, devices ─────────────────────────────────────
  final guest = PlexivoClient(url, key);
  final g = await guest.signInAnonymously();
  expect((g['user'] as Map)['is_anonymous'] == true, 'a guest signs in');
  await guest.from('notes').insert({'body': 'guest note'});
  final up = await guest.linkEmail(email: 'dart-guest-$n@example.test', password: 'a long password 123');
  expect((up['user'] as Map)['id'] == (g['user'] as Map)['id'], 'the guest becomes an account, same id');
  expect((await guest.from('notes').select().eq('body', 'guest note')).length == 1, 'its rows stay');
  final team = await alice.orgs.create(name: 'Dart team');
  expect(team['role'] == 'owner', 'a user creates an organisation');
  final invite = await alice.orgs.invite(team['id'] as String, email: 'dart-bob-$n@example.test');
  expect((await bob.orgs.acceptInvitation(invite['token'] as String))['role'] == 'member', 'an invited user joins');
  expect((await bob.orgs.members(team['id'] as String)).length == 2, 'members see the team');
  expect((await alice.listSessions()).any((d) => d['current'] == true), 'the user lists their devices');

  // ── realtime over WebSockets ───────────────────────────────────────────
  final changes = <PlexivoChange>[];
  final bobChanges = <PlexivoChange>[];
  final live = alice.channel('changes:notes')..subscribe();
  final peek = bob.channel('changes:notes')..subscribe();
  live.changes.listen(changes.add);
  peek.changes.listen(bobChanges.add);
  await live.ready();
  await peek.ready();
  await alice.from('notes').insert({'body': 'live from dart'});
  await waitFor(() => changes.any((c) => c.record?['body'] == 'live from dart'));
  expect(changes.any((c) => c.type == 'insert' && c.record?['body'] == 'live from dart'), 'a live subscriber receives their new row over the socket');
  await Future<void>.delayed(const Duration(milliseconds: 400));
  expect(!bobChanges.any((c) => c.record?['body'] == 'live from dart'), "another user's subscription does not receive it");

  final heard = <Map<String, dynamic>>[];
  final roomA = alice.channel('room:dart-e2e')..subscribe();
  final roomB = bob.channel('room:dart-e2e')..subscribe();
  roomB.on('wave').listen(heard.add);
  await roomA.ready();
  await roomB.ready();
  roomA.sendBroadcast('wave', {'from': 'alice'});
  await waitFor(() => heard.isNotEmpty);
  expect(heard.any((p) => p['from'] == 'alice'), 'a room broadcast reaches another user');
  for (final ch in [live, peek, roomA, roomB]) {
    await ch.unsubscribe();
  }

  // ── GraphQL, with persisted and live queries ───────────────────────────
  final gq = await alice.graphql(r'query($b: String!) { notes(where: {body: {eq: $b}}) { body } }', variables: {'b': 'live from dart'});
  expect(gq['errors'] == null && (gq['data']['notes'] as List).length == 1, "GraphQL reads the user's rows", gq);
  final pq = await visitor.graphql('{ announcementsAggregate { count } }', persisted: true);
  final pq2 = await visitor.graphql('{ announcementsAggregate { count } }', persisted: true);
  expect(pq['data'] != null && pq2['data'] != null, 'automatic persisted queries', [pq, pq2]);
  final answers = <Map<String, dynamic>>[];
  final stop = await alice.graphqlSubscribe('subscription { notes(where: {body: {like: "dart gql%"}}) { body } }', answers.add);
  await waitFor(() => answers.isNotEmpty);
  expect((answers.first['data']?['notes'] as List?)?.isEmpty == true, 'a live query answers at once', answers);
  await alice.from('notes').insert({'body': 'dart gql 1'});
  await waitFor(() => answers.any((a) => ((a['data']?['notes'] as List?) ?? const []).any((x) => (x as Map)['body'] == 'dart gql 1')));
  expect(answers.any((a) => ((a['data']?['notes'] as List?) ?? const []).any((x) => (x as Map)['body'] == 'dart gql 1')),
      'a live query updates when a row it reads changes');
  await stop();

  // ── the ORM: migrations with the secret key, then models as a user ─────
  if (secret != null) {
    final server = PlexivoClient(url, secret);
    const own = [
      {
        'name': 'read',
        'for': 'select',
        'to': ['anon', 'authenticated'],
        'using': 'true'
      },
      {'name': 'write', 'for': 'all', 'to': 'authenticated', 'using': 'true', 'check': 'true'}
    ];
    PlexivoModel authors(PlexivoClient c) => c.model('dart_authors',
        columns: {
          'id': 'bigserial primary key',
          'name': {'type': 'text', 'notNull': true}
        },
        relations: {'posts': const PlexivoRelation.hasMany('dart_posts', foreignKey: 'author_id')},
        policies: own);
    PlexivoModel posts(PlexivoClient c) => c.model('dart_posts',
        columns: {
          'id': 'bigserial primary key',
          'author_id': {'type': 'bigint', 'references': 'dart_authors(id)', 'onDelete': 'cascade'},
          'title': {'type': 'text', 'notNull': true},
          'likes': {'type': 'int', 'notNull': true, 'default': '0'},
          'meta': {'type': 'jsonb', 'notNull': true, 'default': "'{}'::jsonb"},
          'deleted_at': 'timestamptz',
        },
        softDelete: 'deleted_at',
        relations: {
          'author': const PlexivoRelation.belongsTo('dart_authors', foreignKey: 'author_id'),
          'tags': const PlexivoRelation.manyToMany('dart_tags', through: 'dart_post_tags', foreignKey: 'post_id', otherKey: 'tag_id'),
        },
        policies: own);
    PlexivoModel tags(PlexivoClient c) => c.model('dart_tags',
        columns: {
          'id': 'bigserial primary key',
          'name': {'type': 'text', 'unique': true}
        },
        policies: own);
    PlexivoModel postTags(PlexivoClient c) => c.model('dart_post_tags',
        columns: {
          'post_id': {'type': 'bigint', 'notNull': true, 'references': 'dart_posts(id)', 'onDelete': 'cascade'},
          'tag_id': {'type': 'bigint', 'notNull': true, 'references': 'dart_tags(id)', 'onDelete': 'cascade'},
        },
        compositeKey: ['post_id', 'tag_id'],
        policies: own);

    final ddl = await server.migrator.autoMigrate([authors(server), posts(server), tags(server), postTags(server)]);
    expect(ddl.any((s) => s.startsWith('CREATE TABLE IF NOT EXISTS "dart_posts"')), 'autoMigrate creates tables, row-level security and policies');
    expect((await server.migrate([PlexivoMigration.sql('dart_001_tags', "insert into dart_tags (name) values ('dart'), ('flutter')")])).length == 1,
        'a versioned migration applies once');
    expect(
        (await server.raw(r'select count(*)::int as n from dart_tags where name = any($1)', [
              ['dart', 'flutter']
            ]))
                .first['n'] ==
            2,
        'raw SQL with typed parameters');
    await rejects(alice.raw('select 1'), (e) => e is PlexivoException && e.code == 'secret_key_required', 'raw SQL is refused without the secret key');

    final author = authors(alice);
    final post = posts(alice);
    tags(alice);
    final asha = await author.create({'name': 'Asha'});
    final created = await post.createMany([
      {
        'author_id': asha['id'],
        'title': 'Dart at scale',
        'likes': 40,
        'meta': {'lang': 'en'}
      },
      {
        'author_id': asha['id'],
        'title': 'Flutter tips',
        'likes': 5,
        'meta': {'lang': 'hi'}
      },
    ]);
    final dartTags = await alice.from('dart_tags').order('name').find();
    await post.association(created.first, 'tags').append(dartTags.toList());
    final rich = await post.query().preload('author', (PlexivoEmbed a) => a.select('name')).preload('tags').order('id').find();
    expect(rich.first['author']['name'] == 'Asha' && (rich.first['tags'] as List).length == 2, 'preload belongsTo and many-to-many', rich.first);
    expect((await post.whereHas('tags', (PlexivoEmbed t) => t.where('name', 'flutter')).pluck('title')).join() == 'Dart at scale',
        'whereHas through the link table');
    expect((await post.query().whereJson('meta', 'lang', 'hi').pluck('title')).join() == 'Flutter tips', 'JSON path filter');
    final groups = await post.query().groupBy('author_id').aggregate({'count': true, 'sum': 'likes'}) as List;
    expect(groups.length == 1 && groups.first['count'] == 2, 'group by and aggregate', groups);
    await post.where('id', created.last['id']).delete();
    expect(await post.count() == 1 && await post.query().unscoped().count() == 2, 'soft delete hides the row; unscoped shows it');

    final results = await alice.transaction((tx) {
      final a = tx.from('dart_authors').insert({'name': 'Devi'});
      tx.from('dart_posts').insert({'author_id': a.ref('id'), 'title': 'From a transaction'});
    });
    expect(((results[1] as List).first as Map)['author_id'] == ((results[0] as List).first as Map)['id'], 'a transaction with a reference between steps');
    await rejects(alice.transaction((tx) {
      tx.from('dart_authors').insert({'name': 'Ghost'});
      tx.from('dart_posts').insert({'author_id': 987654321, 'title': 'Orphan'});
    }), (e) => e is PlexivoException && e.code == 'foreign_key_violation' && e.operation == 1, 'a failing step rolls the whole transaction back');
    expect(await author.where('name', 'Ghost').count() == 0, 'nothing from the failed transaction remains');
  }

  stdout.writeln('ALL PASSED');
  exit(0);
}
