import 'dart:convert';

import 'package:plexivo_client/plexivo_client.dart';

import 'context.dart';
import 'harness.dart';

/// Every refusal must be a refusal: row-level security, keys, origins, injection, sizes, tokens.
Future<void> securityChecks(Suite t, Ctx c) async {
  final p1 = c.posts['p1']!['id'], p3 = c.posts['p3']!['id'];
  final url = c.project.url;
  Future<int> postCount() async => ((await c.server.raw('select count(*)::int as n from posts')).single['n'] as int);
  final before = await postCount();

  await t.check('RLS: another user cannot read, update or delete my rows, or insert as me', () async {
    expect((await c.bob.from('posts').eq('id', p3)).isEmpty, 'read a draft by id');
    expect((await c.bob.from('posts').update({'title': 'hacked'}).eq('id', p1)).isEmpty, 'update touches nothing');
    expect((await c.bob.from('posts').delete().eq('id', p1)).isEmpty, 'delete touches nothing');
    final e = await refused(c.bob.from('posts').insert({'title': 'as alice', 'author_id': c.aliceId}), code: 'permission_denied', status: 403);
    expect(e.sqlstate == '42501' && e.traceId != null, 'sqlstate and trace id', e);
    await refused(c.anon.from('posts').insert({'title': 'anon'}), status: 403);
    expect((await c.alice.from('posts').first(p1))['title'] == 'Postgres at scale', 'the row is unchanged');
    expect((await c.bob.from('notes').select()).every((r) => r['owner_id'] == c.bobId), "bob's notes only");
  });

  await t.check('RLS: crafted filters cannot widen what a user sees', () async {
    final crafted = await c.bob.from('posts').or('author_id.eq.${c.aliceId},status.eq.draft').select('id, author_id, status');
    expect(crafted.every((r) => r['status'] == 'published' || r['author_id'] == c.bobId), 'no foreign drafts', crafted);
    final viaNot = await c.bob.from('posts').not('status', 'eq', 'published');
    expect(viaNot.every((r) => r['author_id'] == c.bobId), 'not() as well');
    final viaEmbed = await c.bob.from('profiles').select('id, posts!posts_author_fk(id, status)').eq('id', c.aliceId).single();
    expect((viaEmbed.data?['posts'] as List).every((x) => (x as Map)['status'] == 'published'), 'embeds too');
    final viaCount = await c.bob.from('posts').eq('author_id', c.aliceId).count();
    expect(viaCount == 4, 'aggregates too', viaCount);
    final viaRpc = await c.bob.rpc('search_posts', {'q': 'dart'});
    expect((viaRpc as List).every((x) => (x as Map)['status'] == 'published' || x['author_id'] == c.bobId), 'rpc too');
    await refused(c.bob.from('hidden').select(), code: 'table_not_exposed', status: 404);
    await refused(c.bob.from('audit').select(), code: 'table_not_exposed', status: 404);
  });

  await t.check('keys: wrong, missing and another project\'s keys are refused', () async {
    await refused(PlexivoClient(url, 'plx_publishable_not-a-real-key').from('posts').select(), code: 'invalid_api_key', status: 401);
    final missing = await rawRequest(url, '/query/v1', body: {'op': 'select', 'from': 'posts'});
    expect(missing.status == 401 && missing.body['data'] == null, 'no key: 401', missing);
    final other = c.shortTokens;
    if (other != null) {
      await refused(PlexivoClient(url, other.publishableKey).from('posts').select(), code: 'invalid_api_key', status: 401);
      await refused(PlexivoClient(url, other.secretKey).raw('select 1'), code: 'invalid_api_key', status: 401);
    }
  });

  await t.check('origins: a browser origin the project does not allow is refused; an allowed one works', () async {
    final evil = PlexivoClient(url, c.project.publishableKey, httpClient: OriginClient('https://evil.example'));
    await refused(evil.from('posts').select(), code: 'origin_denied', status: 403);
    await refused(evil.signInWithPassword(email: c.email('alice'), password: password), code: 'origin_denied', status: 403);
    final good = PlexivoClient(url, c.project.publishableKey, httpClient: OriginClient(c.project.origin));
    expect((await good.from('posts').select('id').limit(1)).isNotEmpty, 'allowed origin reads');
  });

  await t.check('the secret key with an Origin header (a browser) is refused: secret_key_in_browser', () async {
    final leaked = PlexivoClient(url, c.project.secretKey, httpClient: OriginClient(c.project.origin));
    await refused(leaked.raw('select 1'), code: 'secret_key_in_browser', status: 403);
    await refused(leaked.from('posts').select(), code: 'secret_key_in_browser', status: 403);
    final evil = PlexivoClient(url, c.project.secretKey, httpClient: OriginClient('https://evil.example'));
    await refused(evil.from('posts').select(), code: ['secret_key_in_browser', 'origin_denied'], status: 403);
  });

  await t.check('the publishable key on /sql/v1 is refused, whatever it sends', () async {
    final r = await rawRequest(url, '/sql/v1', headers: {
      'apikey': c.project.publishableKey
    }, body: {
      'statements': [
        {'sql': 'drop table posts', 'params': []}
      ]
    });
    expect(r.status == 403 && errorCode(r.body) == 'secret_key_required', 'refused', r);
    expect(await postCount() >= before, 'posts survive');
  });

  const attacks = ["'; drop table posts; --", 'id) or (1=1', '"x" desc; select', r"\'; delete from posts where true; --", '1 or 1=1'];
  await t.check('injection: filter values are data, never SQL', () async {
    for (final a in attacks) {
      expect((await c.alice.from('posts').eq('title', a)).isEmpty, 'eq $a');
      expect((await c.alice.from('posts').ilike('title', a)).isEmpty, 'ilike $a');
      expect((await c.alice.from('posts').or('title.eq.$a,body.eq.x')).isEmpty, 'or $a');
      expect((await c.bob.from('posts').inFilter('title', [a, 'Draft about Dart'])).isEmpty, 'in $a');
      expect((await c.alice.from('posts').whereJson('meta', [a], 'x')).isEmpty, 'json path key $a');
      expect((await c.alice.from('posts').textSearch('search', a, type: 'websearch')).isEmpty, 'fts $a');
    }
    expect(await postCount() == before, 'no rows lost or added');
  });

  await t.check('injection: column names, order, select, embeds, on_conflict, rpc args are refused', () async {
    for (final a in attacks) {
      await refused(c.alice.from('posts').where(a, 1), status: 400, what: 'column $a');
      await refused(c.alice.from('posts').order({'column': a, 'dir': 'asc'}), status: 400, what: 'order $a');
      await refused(
          c.alice.from('posts').select([
            {'column': a}
          ]),
          status: 400,
          what: 'select $a');
      await refused(
          c.alice.from('posts').select([
            {'embed': a}
          ]),
          code: ['table_not_exposed', 'invalid_request'],
          what: 'embed $a');
      await refused(c.alice.from('products').upsert({'sku': 'Z', 'region': 'Z', 'name': 'z'}, onConflict: [a]), status: 400, what: 'on_conflict $a');
      await refused(c.alice.from('posts').order('profiles!posts_author_fk.username').order({'column': 'username', 'relation': a}),
          code: ['invalid_request', 'table_not_exposed'], what: 'related order $a');
      await refused(c.alice.rpc('add_numbers', {'a': a, 'b': 1}), status: 400, what: 'rpc arg $a');
      expect((await c.alice.rpc('search_posts', {'q': a}) as List).isEmpty, 'rpc text arg $a is data');
      await refused(c.alice.rpc(a), code: ['function_not_exposed', 'invalid_request'], what: 'rpc name $a');
    }
    var thrown = false;
    try {
      c.alice.from('posts').select('id, title; drop table posts');
    } on ArgumentError {
      thrown = true;
    }
    expect(thrown, 'a bad select string is refused before sending');
    expect(await postCount() == before, 'posts survive');
    expect((await c.bob.from('posts').eq('author_id', c.aliceId)).length == 4, 'and nothing leaked to bob');
  });

  await t.check('oversized: > 300 filter nodes, > 1,000 rows and a 12 MB body are refused cleanly', () async {
    var q = c.alice.from('posts');
    for (var i = 0; i < 301; i++) {
      q = q.orWhere('likes', i);
    }
    await refused(q, code: 'invalid_request', status: 400, what: '301 nodes');
    await refused(
        c.alice.from('notes').insert([
          for (var i = 0; i < 1001; i++) {'body': 'x'}
        ]),
        code: 'invalid_request',
        status: 400);
    await refused(c.alice.from('notes').insert({'body': 'x' * (12 * 1024 * 1024)}), code: 'too_large', status: 413, what: 'a 12 MB body');
    expect((await c.alice.from('posts').select('id').limit(1)).isNotEmpty, 'the API still answers');
  });

  final short = c.shortTokens;
  await t.check('tokens: tampered, foreign-project and expired access tokens are refused with 401 (never treated as anon)', () async {
    final token = c.alice.accessToken!;
    final parts = token.split('.');
    final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1])))) as Map;
    final forged = base64Url.encode(utf8.encode(jsonEncode({...payload, 'sub': c.bobId}))).replaceAll('=', '');
    for (final bad in ['${parts[0]}.$forged.${parts[2]}', '${parts[0]}.${parts[1]}.${parts[2].substring(1)}x', 'not-a-token']) {
      final r = await rawRequest(url, '/query/v1',
          headers: {'apikey': c.project.publishableKey, 'authorization': 'Bearer $bad'}, body: {'op': 'select', 'from': 'posts'});
      expect(r.status == 401 && r.body['data'] == null, 'refused: ${bad.length} chars', r);
    }
    if (short != null) {
      final other = PlexivoClient(short.url, short.publishableKey);
      await other.signUp(email: c.email('foreign'), password: password);
      final r = await rawRequest(url, '/query/v1',
          headers: {'apikey': c.project.publishableKey, 'authorization': 'Bearer ${other.accessToken}'}, body: {'op': 'select', 'from': 'posts'});
      expect(r.status == 401 && r.body['data'] == null, "another project's token", r);
      final expired = other.accessToken!;
      await Future<void>.delayed(const Duration(seconds: 8));
      final e = await rawRequest(short.url, '/query/v1',
          headers: {'apikey': short.publishableKey, 'authorization': 'Bearer $expired'}, body: {'op': 'select', 'from': 'notes'});
      expect(e.status == 401 && errorCode(e.body) == 'token_expired' && e.body['data'] == null, 'expired: 401 token_expired', e);
    } else {
      t.note('no short-token project: the foreign-project and expired-token parts were skipped');
    }
  }, timeout: const Duration(seconds: 60));

  await t.check('typed errors: status, code, sqlstate, hint, traceId for each failure kind', () async {
    final unique =
        await refused(c.alice.from('profiles').insert({'id': c.aliceId, 'username': 'alice_${c.n}'}), code: ['unique_violation', 'permission_denied']);
    expect(unique.traceId != null, 'traceId');
    final dup = await refused(c.alice.from('tags').insert({'name': 'db-${c.n}'}), code: 'unique_violation', status: 409);
    expect(dup.sqlstate == '23505' && dup.isUniqueViolation, 'unique sqlstate', dup);
    final fk = await refused(c.alice.from('post_tags').insert({'post_id': p1, 'tag_id': 987654321}), code: 'foreign_key_violation', status: 409);
    expect(fk.sqlstate == '23503', 'fk sqlstate', fk);
    final check = await refused(c.alice.from('posts').insert({'title': ''}), code: 'check_violation', status: 400);
    expect(check.sqlstate == '23514', 'check sqlstate', check);
    final notNull = await refused(c.alice.from('comments').insert({'post_id': p1}), code: 'not_null_violation', status: 400);
    expect(notNull.sqlstate == '23502', 'not null sqlstate', notNull);
    final bad = await refused(c.alice.from('posts').where('no_such_column', 1), code: 'invalid_request', status: 400);
    expect(bad.message.isNotEmpty, 'a message', bad);
    final enumValue = await refused(c.alice.from('posts').insert({'title': 'x', 'status': 'bogus'}), status: 400);
    expect(enumValue.sqlstate != null, 'an invalid enum value carries its sqlstate', enumValue);
    await refused(c.alice.from('nope_${c.n}').select(), code: 'table_not_exposed', status: 404);
    await refused(c.alice.rpc('not_exposed'), code: 'function_not_exposed', status: 404);
    await refused(c.anon.channel('items').subscribe().ready(), code: 'sign_in_required');
  });
}
