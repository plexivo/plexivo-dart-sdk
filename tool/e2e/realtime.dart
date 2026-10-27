import 'dart:async';

import 'package:plexivo_client/plexivo_client.dart';

import 'context.dart';
import 'harness.dart';

/// Row changes with row-level security, presence, broadcast, reconnects, and GraphQL live queries.
Future<void> realtimeChecks(Suite t, Ctx c) async {
  final aliceAll = c.alice.channel('changes:posts');
  final alicePublished = c.alice.channel('changes:posts', 'status=eq.published');
  final bobAll = c.bob.channel('changes:posts');
  final got = <String, List<PlexivoChange>>{'aliceAll': [], 'alicePublished': [], 'bobAll': []};
  aliceAll.changes.listen(got['aliceAll']!.add);
  alicePublished.changes.listen(got['alicePublished']!.add);
  bobAll.changes.listen(got['bobAll']!.add);
  bool has(String who, String type, bool Function(Map<String, dynamic>?) row) =>
      got[who]!.any((ch) => ch.type == type && row(ch.type == 'delete' ? ch.old : ch.record));
  late int draftId;

  final joined = await t.check('realtime: channels join (signed in, with a filter)', () async {
    for (final ch in [aliceAll, alicePublished, bobAll]) {
      ch.subscribe();
    }
    await Future.wait([aliceAll.ready(), alicePublished.ready(), bobAll.ready()]).timeout(const Duration(seconds: 15));
    expect(aliceAll.status == PlexivoChannelStatus.joined && aliceAll.isJoined, 'status joined');
  });
  if (!joined) return;

  await t.check('realtime: insert reaches the author; row-level security keeps it from others; the filter applies', () async {
    final draft = await c.alice.from('posts').create({'title': 'Live draft'});
    draftId = draft['id'] as int;
    expect(await eventually(() => has('aliceAll', 'insert', (r) => r?['id'] == draftId)), 'alice receives her draft');
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(!has('bobAll', 'insert', (r) => r?['id'] == draftId), 'bob does not receive a draft he may not read', got['bobAll']!.map((e) => e.record).toList());
    expect(!has('alicePublished', 'insert', (r) => r?['id'] == draftId), 'the status=eq.published filter excludes it');
  });

  await t.check('realtime: update and delete are delivered, as each subscriber may see them', () async {
    await c.alice.from('posts').where('id', draftId).update({'status': 'published', 'title': 'Live published'});
    expect(await eventually(() => has('aliceAll', 'update', (r) => r?['id'] == draftId && r?['status'] == 'published')), 'alice: update');
    expect(await eventually(() => has('bobAll', 'update', (r) => r?['id'] == draftId)), 'bob now may read it: update');
    expect(await eventually(() => has('alicePublished', 'update', (r) => r?['title'] == 'Live published')), 'filtered channel: update');
    await c.alice.from('posts').deleteById(draftId);
    expect(await eventually(() => has('aliceAll', 'delete', (r) => r?['id'] == draftId)), 'alice: delete with the old key',
        got['aliceAll']!.map((e) => [e.type, e.old]).toList());
  });

  await t.check('realtime: a dropped connection reconnects and rejoins by itself; changes flow again', () async {
    final statuses = <PlexivoChannelStatus>[];
    final sub = aliceAll.statusChanges.listen(statuses.add);
    aliceAll.reconnect();
    expect(await eventually(() => statuses.contains(PlexivoChannelStatus.reconnecting) && aliceAll.isJoined, timeout: const Duration(seconds: 15)),
        'reconnected', statuses);
    final row = await c.alice.from('posts').create({'title': 'After reconnect'});
    expect(await eventually(() => has('aliceAll', 'insert', (r) => r?['id'] == row['id'])), 'delivered after the reconnect');
    await sub.cancel();
    await c.alice.from('posts').deleteById(row['id'] as Object);
  });

  await t.check('realtime: refused joins are reported and not retried', () async {
    final hidden = c.alice.channel('changes:hidden')..subscribe();
    await refused(hidden.ready(), code: 'table_not_exposed');
    final private = c.anon.channel('room:private:${c.n}')..subscribe();
    await refused(private.ready(), code: 'sign_in_required');
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(hidden.status == PlexivoChannelStatus.refused && private.status == PlexivoChannelStatus.refused, 'stays refused');
    await hidden.unsubscribe();
    await private.unsubscribe();
  });

  await t.check('realtime: broadcast and presence in a room', () async {
    final room = 'room:e2e-${c.n}';
    final a = c.alice.channel(room, null, {'name': 'Alice'})..subscribe();
    await a.ready();
    final presence = <PlexivoPresence>[];
    a.presence.listen(presence.add);
    final heard = <Map<String, dynamic>>[];
    final b = c.bob.channel(room, null, {'name': 'Bob'})..subscribe();
    b.on('wave').listen(heard.add);
    await b.ready();
    expect(await eventually(() => presence.any((p) => p.event == 'presence_diff' && '${p.state}'.contains('Bob'))), 'alice sees bob join',
        presence.map((p) => p.state).toList());
    a.sendBroadcast('wave', {'from': 'alice'});
    expect(await eventually(() => heard.any((h) => h['from'] == 'alice')), 'bob hears the broadcast');
    await b.unsubscribe();
    expect(await eventually(() => presence.where((p) => p.event == 'presence_diff').length >= 2), 'alice sees bob leave');
    await a.unsubscribe();
  });

  await t.check('graphql: query and mutation, as the user', () async {
    final r = await c.alice.graphql(r'query($t: String!) { posts(where: {title: {eq: $t}}) { id title } }', variables: {'t': 'Postgres at scale'});
    expect(r['errors'] == null && ((r['data'] as Map)['posts'] as List).length == 1, 'query', r);
    final bobView = await c.bob.graphql('{ posts(where: {status: {eq: "draft"}}) { id author_id } }');
    final drafts = ((bobView['data'] as Map?)?['posts'] as List?) ?? const [];
    expect(drafts.every((x) => (x as Map)['author_id'] == c.bobId), "bob's GraphQL sees no one else's drafts", bobView);
  });

  await t.check('graphql: a live query answers now and again when a row it reads changes', () async {
    final answers = <Map<String, dynamic>>[];
    final stop = await c.alice.graphqlSubscribe('subscription { notes { body } }', answers.add);
    expect(await eventually(() => answers.isNotEmpty), 'first answer');
    await c.alice.from('notes').insert({'body': 'live gql ${c.n}'});
    expect(
        await eventually(() => answers.any((a) => (((a['data'] as Map?)?['notes'] as List?) ?? const []).any((x) => (x as Map)['body'] == 'live gql ${c.n}'))),
        'updated',
        answers);
    await stop();
  });

  for (final ch in [aliceAll, alicePublished, bobAll]) {
    await ch.unsubscribe();
  }

  final short = c.shortTokens;
  if (short == null) {
    t.note('no short-token project: realtime-after-token-expiry check skipped');
    return;
  }
  await t.check('realtime: past the access token expiry, the channel refreshes and rejoins; changes keep flowing', () async {
    final db = PlexivoClient(short.url, short.publishableKey);
    await db.signUp(email: c.email('ttl-live'), password: password);
    final ch = db.channel('changes:notes')..subscribe();
    final received = <PlexivoChange>[];
    final statuses = <PlexivoChannelStatus>[];
    ch.changes.listen(received.add);
    ch.statusChanges.listen(statuses.add);
    await ch.ready();
    await db.from('notes').insert({'body': 'before'});
    expect(await eventually(() => received.any((r) => r.record?['body'] == 'before')), 'delivered before expiry');
    await Future<void>.delayed(const Duration(seconds: 9));
    // A second user's client, signed in on the same account, writes after expiry.
    final writer = PlexivoClient(short.url, short.publishableKey);
    await writer.signInWithPassword(email: c.email('ttl-live'), password: password);
    await writer.from('notes').insert({'body': 'after expiry'});
    expect(await eventually(() => received.any((r) => r.record?['body'] == 'after expiry'), timeout: const Duration(seconds: 15)), 'delivered after expiry',
        [statuses, received.map((r) => r.record).toList()]);
    expect(statuses.contains(PlexivoChannelStatus.reconnecting) && ch.isJoined, 'it rejoined with a fresh token', statuses);
    await ch.unsubscribe();
  }, timeout: const Duration(seconds: 60));
}
