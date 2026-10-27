import 'package:plexivo_client/plexivo_client.dart';

import 'harness.dart';

/// What the sections share: the project, its clients and the rows they made.
class Ctx {
  /// The context for [project].
  Ctx(this.project)
      : server = PlexivoClient(project.url, project.secretKey),
        anon = PlexivoClient(project.url, project.publishableKey),
        alice = PlexivoClient(project.url, project.publishableKey),
        bob = PlexivoClient(project.url, project.publishableKey),
        carol = PlexivoClient(project.url, project.publishableKey);

  /// The project under test.
  final Project project;

  /// The secret key, as a server holds it.
  final PlexivoClient server;

  /// Signed out.
  final PlexivoClient anon;

  /// Three signed-in users.
  final PlexivoClient alice, bob, carol;

  /// A suffix that keeps this run's emails and names unique.
  final n = DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  /// The users' ids.
  late String aliceId, bobId, carolId;

  /// Alice's posts by key (`p1` … `p6`), as inserted.
  final posts = <String, Map<String, dynamic>>{};

  /// Bob's published and draft posts.
  late Map<String, dynamic> bobPublic, bobDraft;

  /// Tag ids by name.
  final tags = <String, int>{};

  /// A short-token project, when the harness could make one.
  Project? shortTokens;

  /// A new client on the project with the publishable key.
  PlexivoClient client() => PlexivoClient(project.url, project.publishableKey);

  /// An email unique to this run.
  String email(String who) => '$who-$n@example.test';

  /// Alice's posts only (published posts of others are visible to her too).
  PlexivoQuery alicePosts() => alice.from('posts').eq('author_id', aliceId);
}

/// A good password.
const password = 'a long password 123';
