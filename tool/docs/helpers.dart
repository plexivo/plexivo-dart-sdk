// What the README's hidden preludes call when tool/docs.dart runs the
// README's code blocks: the live project, clients and a little seed data.
import 'dart:io';

import 'package:plexivo_client/plexivo_client.dart';

/// The live project's Data API URL.
final docsUrl = Platform.environment['PLEXIVO_URL']!;

/// The live project's publishable key.
final docsPublishableKey = Platform.environment['PLEXIVO_PUBLISHABLE_KEY']!;

/// The live project's secret key.
final docsSecretKey = Platform.environment['PLEXIVO_SECRET_KEY']!;

/// A suffix that keeps this run's emails and usernames unique.
final docsRun = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
var _readers = 0;

/// A client for the live project: signed out, or [signedIn] as a new user with a profile.
Future<PlexivoClient> docsClient({bool signedIn = false}) async {
  final db = PlexivoClient(docsUrl, docsPublishableKey);
  if (signedIn) {
    final n = _readers++;
    await db.signUp(email: 'reader$n-$docsRun@example.com', password: 'correct horse battery');
    await db.from('profiles').insert({'username': 'reader${n}_$docsRun', 'country': n.isEven ? 'IN' : 'GB'});
  }
  return db;
}

/// A few posts, comments and tags by the user of [db], as the blog examples expect.
Future<void> docsSeedBlog(PlexivoClient db) async {
  final posts = await db.from('posts').insert([
    {
      'title': 'Postgres for Flutter developers',
      'body': 'Joins, policies and realtime without an API server',
      'status': 'published',
      'likes': 12,
      'tags': ['dart', 'postgres'],
      'meta': {'lang': 'en'}
    },
    {
      'title': 'Joins without an API server',
      'body': 'Embeds and views',
      'status': 'published',
      'likes': 5,
      'tags': ['postgres']
    },
    {'title': 'Draft: realtime tips', 'body': 'Streams and StreamBuilder', 'likes': 0},
  ]);
  await db.from('comments').insert([
    {'post_id': posts[0]['id'], 'body': 'Exactly what I needed', 'approved': true},
    {'post_id': posts[0]['id'], 'body': 'Waiting for part two'},
  ]);
  await db.from('tags').upsert([
    {'name': 'dart'},
    {'name': 'postgres'},
  ], onConflict: 'name', ignore: true);
  final tags = await db.from('tags').inFilter('name', ['dart', 'postgres']);
  await db.from('post_tags').upsert([
    for (final tag in tags) {'post_id': posts[0]['id'], 'tag_id': tag['id']},
  ], onConflict: 'post_id,tag_id', ignore: true);
}
