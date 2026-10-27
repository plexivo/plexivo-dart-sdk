// Plexivo Postgres from Dart: authentication, a todo list, realtime, GraphQL
// with a live query, and a Plexivo Function — the whole backend, on
// PostgreSQL, with row-level security deciding what each user can do.
//
// 1. Create the example tables (todos, messages) with example/schema.sql,
//    which also switches Realtime on for both.
// 2. Run it with your project's URL and publishable key (Connect tab):
//
//      PLEXIVO_URL=https://… PLEXIVO_PUBLISHABLE_KEY=… dart run example/main.dart
//
// The publishable key is safe in an app. Never ship the secret key.
import 'dart:async';
import 'dart:io';

import 'package:plexivo_client/plexivo_client.dart';

Future<void> main() async {
  final url = Platform.environment['PLEXIVO_URL'];
  final key = Platform.environment['PLEXIVO_PUBLISHABLE_KEY'];
  if (url == null || key == null) {
    stderr.writeln('Set PLEXIVO_URL and PLEXIVO_PUBLISHABLE_KEY (from your database\'s Connect tab).');
    exit(2);
  }
  final db = PlexivoClient(url, key);

  // ── Authentication ─────────────────────────────────────────────────────
  db.authStateChanges.listen((state) => print('auth: ${state.event}'));

  final email = Platform.environment['PLEXIVO_EXAMPLE_EMAIL'] ?? 'demo-${DateTime.now().millisecondsSinceEpoch}@example.com';
  const password = 'a long demo password 2026';
  try {
    await db.signInWithPassword(email: email, password: password);
  } on PlexivoException catch (e) {
    if (e.code != 'invalid_credentials') rethrow;
    await db.signUp(email: email, password: password); // first run: create the account
  }
  final user = await db.getUser();
  print('signed in as ${user['email']}');

  // ── Data: create, read with filters, order and pages, update, delete ───
  final milk = await db.from('todos').create({'title': 'Buy milk'});
  await db.from('todos').createMany([
    {'title': 'Book flights'},
    {'title': 'Call mum', 'done': true},
  ]);

  final open = await db.from('todos').select('id, title').where('done', false).order('created_at', 'desc').limit(10);
  print('open: ${open.map((t) => t['title']).toList()}');

  final page = await db.from('todos').order('id').paginate(page: 1, perPage: 2);
  print('page ${page.page} of ${page.totalPages}: ${page.data.length} rows');

  // Supabase-style names work too: eq, inFilter, isFilter, range, single.
  final done = await db.from('todos').select('*', 'exact').eq('done', true);
  print('${done.count} done');

  await db.from('todos').where('id', milk['id']).update({'done': true});
  await db.from('todos').where('id', milk['id']).delete();

  // Errors are PlexivoException with a code to branch on.
  try {
    await db.from('todos').create({'title': ''}); // the CHECK constraint refuses it
  } on PlexivoException catch (e) {
    print('refused: ${e.code} (${e.statusCode})');
  }

  // ── Realtime: row changes as a Stream ──────────────────────────────────
  final feed = db.channel('changes:todos')..subscribe();
  await feed.ready();
  final change = feed.changes.first.timeout(const Duration(seconds: 10));
  await db.from('todos').create({'title': 'Seen in realtime'});
  final c = await change;
  print('realtime: ${c.type} "${c.record?['title']}"');
  await feed.unsubscribe();

  // ── GraphQL, and a live query ──────────────────────────────────────────
  final result = await db.graphql(r'query { todos(where: {done: {eq: false}}, limit: 5) { id title } }');
  print('graphql: ${(result['data'] as Map)['todos']}');

  final counts = StreamController<int>();
  final stop = await db.graphqlSubscribe('subscription { todosAggregate { count } }', (r) {
    final data = r['data'] as Map?;
    if (data != null) counts.add((data['todosAggregate'] as Map)['count'] as int);
  });
  final updates = counts.stream.take(2).toList();
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await db.from('todos').create({'title': 'Counted live'});
  print('live counts: ${await updates.timeout(const Duration(seconds: 10))}');
  await stop();

  // ── Plexivo Functions (deploy example/functions/hello.js as `hello`) ───
  try {
    final hello = await db.functions.invoke('hello', body: {'name': 'Dart'});
    print('function: ${(hello.data as Map)['message']}');
  } on PlexivoException catch (e) {
    print('function not deployed yet: ${e.code}');
  }

  await db.signOut();
  exit(0);
}
