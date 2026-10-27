/// Plexivo Postgres for Flutter and Dart.
///
/// A Backend-as-a-Service on PostgreSQL, and a Firebase alternative: one client
/// for your database's Data API, authentication, realtime over WebSockets,
/// GraphQL, Plexivo Functions and file storage. Query Supabase-style
/// (`from('notes').select().eq('pinned', true)`) or GORM-style: models,
/// relations, `preload`, `whereHas`, `first`, `create`, `save`, hooks, scopes,
/// soft deletes and transactions. Row-level security decides what every
/// request can read and write.
///
/// ```dart
/// import 'package:plexivo_client/plexivo_client.dart';
///
/// final db = PlexivoClient(dataUrl, publishableKey);
/// await db.signInWithPassword(email: email, password: password);
///
/// final posts = await db.from('posts')
///     .where('likes', '>', 10)
///     .preload('author')
///     .order('created_at', 'desc')
///     .limit(20);
/// print(posts.first['title']);
/// ```
///
/// Start with [PlexivoClient]. Queries are [PlexivoQuery] builders, models are
/// [PlexivoModel], realtime is [PlexivoRealtimeChannel], and every failure is a
/// [PlexivoException].
///
/// Your data URL and publishable key are on the database's **Connect** tab. The
/// publishable key belongs in your app. The secret key is for servers only: it
/// bypasses row-level security and unlocks raw SQL, migrations and user import
/// ([PlexivoSql], [PlexivoMigrator]). Never ship it in a Flutter app.
library;

export 'src/client.dart';
export 'src/errors.dart';
export 'src/model.dart' show PlexivoModel, PlexivoRelation, PlexivoHooks, PlexivoAssociation, DataLayer;
export 'src/query.dart' show PlexivoQuery, PlexivoEmbed, PlexivoConditions, PlexivoPage, parseSelect, parseLogic;
export 'src/realtime.dart';
export 'src/result.dart';
export 'src/sql.dart' show PlexivoSql, PlexivoMigrator, PlexivoMigration, PlexivoMigrationPlan, columnSql;
