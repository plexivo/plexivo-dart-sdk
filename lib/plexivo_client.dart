/// The client for Plexivo Postgres: queries (Supabase-style and GORM-style),
/// models and relations, transactions, auth, storage, realtime, GraphQL,
/// functions, and — with the secret key, on a server — raw SQL and migrations.
library;

export 'src/client.dart';
export 'src/errors.dart';
export 'src/model.dart' show PlexivoModel, PlexivoRelation, PlexivoHooks, PlexivoAssociation, DataLayer;
export 'src/query.dart' show PlexivoQuery, PlexivoEmbed, PlexivoConditions, PlexivoPage, parseSelect, parseLogic;
export 'src/realtime.dart';
export 'src/result.dart';
export 'src/sql.dart' show PlexivoSql, PlexivoMigrator, PlexivoMigration, PlexivoMigrationPlan, columnSql;
