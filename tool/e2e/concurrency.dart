import 'context.dart';
import 'harness.dart';

/// 20 users × 25 parallel requests: no errors, and each sees only their own rows.
Future<void> concurrencyChecks(Suite t, Ctx c) async {
  await t.check('concurrency: 20 users × 25 parallel requests (500), each sees only their own rows', () async {
    final users = List.generate(20, (_) => c.client());
    await Future.wait([for (var i = 0; i < users.length; i++) users[i].signUp(email: c.email('crowd$i'), password: password)]);
    final ids = [for (final u in users) u.currentUser!['id'] as String];
    await Future.wait([
      for (var i = 0; i < users.length; i++)
        users[i].from('notes').insert([
          for (var k = 0; k < 3; k++) {'body': 'crowd $i note $k'}
        ])
    ]);
    final errors = <Object>[];
    var leaks = 0, requests = 0;
    Future<void> one(int i, int k) async {
      try {
        requests++;
        switch (k % 5) {
          case 0:
            final rows = await users[i].from('notes').select('owner_id, body');
            if (rows.length != 3 || rows.any((r) => r['owner_id'] != ids[i] || !(r['body'] as String).startsWith('crowd $i '))) leaks++;
          case 1:
            if (await users[i].from('notes').count() != 3) leaks++;
          case 2:
            final mine = await users[i].from('notes').where('owner_id', 'in', ids).select('owner_id');
            if (mine.any((r) => r['owner_id'] != ids[i])) leaks++;
          case 3:
            final t = await users[i].transaction((tx) {
              tx.from('notes').where('body', 'crowd $i note 0').update({'body': 'crowd $i note 0'});
              tx.from('notes').select('owner_id').find();
            });
            if ((t[1] as List).any((r) => (r as Map)['owner_id'] != ids[i])) leaks++;
          default:
            final g = await users[i].graphql('{ notes { owner_id } }');
            final list = ((g['data'] as Map?)?['notes'] as List?) ?? const [];
            if (list.length != 3 || list.any((r) => (r as Map)['owner_id'] != ids[i])) leaks++;
        }
      } catch (e) {
        errors.add(e);
      }
    }

    await Future.wait([
      for (var k = 0; k < 25; k++)
        for (var i = 0; i < users.length; i++) one(i, k)
    ]);
    expect(requests == 500, '500 requests', requests);
    expect(errors.isEmpty, 'no errors', errors.take(3).map((e) => '$e').toList());
    expect(leaks == 0, 'no rows of another user (no session state shared across pooled connections)', leaks);
    final server = await c.server.raw("select count(*)::int as n from notes where body like 'crowd %'");
    expect(server.single['n'] == 60, 'every row written once', server);
  }, timeout: const Duration(minutes: 3));

  await t.check('concurrency: parallel writes to one counter are atomic', () async {
    final post = await c.alice.from('posts').create({'title': 'Counter'});
    await Future.wait([for (var i = 0; i < 50; i++) c.alice.from('posts').where('id', post['id']).increment('views')]);
    expect((await c.alice.from('posts').first(post['id']))['views'] == 50, '50 increments');
    await c.alice.from('posts').deleteById(post['id'] as Object);
  });
}
