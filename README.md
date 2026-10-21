# Plexivo Postgres for Flutter and Dart

`plexivo_client` is the client for **Plexivo Postgres**: your database, its Data API, authentication, realtime over WebSockets, GraphQL, functions and file storage.

Use it **Supabase-style** (`from('notes').select().eq('pinned', true)`) or **GORM-style**: models, relations, `preload`, `whereHas`, `first`, `create`, `save`, hooks, scopes, soft deletes, transactions, association mode, and migrations and raw SQL on your server. Row-level security decides what every request can read and write.

```yaml
dependencies:
  plexivo_client: ^0.2.0
```

```dart
import 'package:plexivo_client/plexivo_client.dart';

final db = PlexivoClient(dataUrl, publishableKey);
await db.signInWithPassword(email: email, password: password);

final posts = await db.from('posts')
    .where('likes', '>', 10)
    .preload('author')
    .order('created_at', 'desc')
    .limit(20);
print(posts.first['title']);
```

Your data URL and publishable key are on the database's **Connect** tab. The publishable key belongs in your app. The **secret key** is for servers only: it bypasses row-level security and runs raw SQL and migrations. Never ship it in a Flutter app.

## Queries

### First working app

Create a Plexivo Postgres database, enable its Data API on **Connect**, and copy the project URL and publishable key. For Flutter Web, allow the application's exact origin. The secret key belongs only on a trusted server, never in a Flutter build.

Connect as the database owner using `plexivo db connect YOUR_DATABASE` and a PostgreSQL client such as `psql`, supplying credentials securely when prompted. Run this setup through that connection. The web SQL console intentionally does not accept policy or privilege-management statements:

```sql
CREATE TABLE public.quickstart_notes (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  owner_id uuid NOT NULL DEFAULT auth.uid(),
  body text NOT NULL
);
ALTER TABLE public.quickstart_notes ENABLE ROW LEVEL SECURITY;
CREATE POLICY own_notes ON public.quickstart_notes TO authenticated
  USING (owner_id = auth.uid()) WITH CHECK (owner_id = auth.uid());
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.quickstart_notes TO authenticated;
GRANT USAGE ON SEQUENCE public.quickstart_notes_id_seq TO authenticated;
```

Refresh the project's Data API schema and confirm `quickstart_notes` appears as exposed. A table needs row-level security and a policy to be exposed. This policy allows each signed-in user to access only their own notes. Close the administrative tunnel when setup is complete.

```dart
final db = PlexivoClient(projectUrl, publishableKey);
await db.signUp(email: email, password: password); // or signInWithPassword
await db.from('quickstart_notes').insert({'body': 'Hello from Flutter'});
final notes = await db.from('quickstart_notes').select('id, body');
print(notes);
```

Follow your project's email-verification policy. For `429` responses, wait for `Retry-After` rather than retrying immediately. Data API, Auth, Realtime and Functions require the control plane; they do not have the same independence as direct database connections.

### Query builder

A query is immutable and chainable; `await` runs it. Results are a `PlexivoResult`: a list of rows that also carries `count`.

```dart
db.from('posts')
  .where('likes', '>', 10)
  .where({'published': true, 'deleted_at': null})          // null → IS NULL
  .orWhere('title', 'ilike', '%postgres%')                  // AND binds tighter than OR
  .where((PlexivoConditions q) => q.where('a', 1).orWhere('b', 'in', [2, 3]))
  .whereNot('author_id', [1, 2])
  .whereBetween('score', 1, 5)
  .whereJson('meta', 'lang.code', 'hi')
  .whereContains('tags', ['postgres'])
  .whereSearch('body', 'fast cars', 'english')
  .whereHas('comments', (PlexivoEmbed c) => c.where('approved', true))
  .select('id, title as heading')
  .order('likes', 'desc', 'last')
  .page(2, 20);

// Supabase-style
final res = await db.from('notes')
    .select('id, body, author:authors(name)', 'exact')
    .eq('pinned', true)
    .or('priority.gte.3,body.ilike.*urgent*')
    .range(0, 19);
print(res.count);
final one = await db.from('notes').select().eq('id', 1).single(); // one.data
```

`is` and `in` are Dart keywords, so their PostgREST filters are `isFilter` and `inFilter`.

Reading: `first(id?)`, `last()`, `take()`, `firstOrNull()`, `sole()`, `find([ids])`, `pluck('col')`, `count()`, `exists()`, `sum/avg/min/max`, `aggregate(...)`, `paginate(page:, perPage:)`, `findInBatches(500, (rows, i) {...})`, `await for (final row in q.each())`. `first()` throws `RecordNotFoundException` when nothing matches.

## Writes

```dart
final post = await db.from('posts').create({'title': 'Hello'});
await db.from('posts').createMany([{'title': 'a'}, {'title': 'b'}]);
await db.from('products').upsert({'sku': 'A1', 'price': 11}, onConflict: 'sku', update: ['price']);
await db.from('posts').save({'id': 7, 'title': 'New title'});
await db.from('posts').where('id', 7).update({'title': 'T'});
await db.from('posts').update({'title': 'T'}).eq('id', 7);      // Supabase order works too
await db.from('products').where('sku', 'A1').decrement('stock', by: 2);
await db.from('posts').where('id', 7).delete();
await db.from('products').firstOrCreate({'sku': 'D4'}, {'name': 'Desk'});
```

An update or delete must say which rows it touches (`missing_where` otherwise); `allowGlobalUpdate()` is the opt-in.

## Models, relations, transactions

```dart
final post = db.model('posts',
  softDelete: 'deleted_at',
  relations: {
    'author': const PlexivoRelation.belongsTo('authors', foreignKey: 'author_id'),
    'comments': const PlexivoRelation.hasMany('comments', foreignKey: 'post_id'),
    'tags': const PlexivoRelation.manyToMany('tags', through: 'post_tags', foreignKey: 'post_id', otherKey: 'tag_id'),
  },
  hooks: PlexivoHooks(beforeCreate: (row) => {...row, 'slug': slugify(row['title'])}),
  scopes: {'popular': (q) => q.where('likes', '>=', 10)},
);

final rows = await post.query()
    .scopes(['popular'])
    .preload('author', (PlexivoEmbed a) => a.select('name'))
    .preload('tags')
    .withCount('comments')
    .joins('comments', (PlexivoEmbed c) => c.where('approved', true));

await post.association(row, 'tags').append([tagId]);

// All or nothing, in one request; .ref() passes a result to the next step.
await db.transaction((tx) {
  final author = tx.from('authors').insert({'name': 'Asha'});
  tx.from('posts').insert({'title': 'Hi', 'author_id': author.ref('id')});
  tx.from('products').where('sku', 'B2').lockForUpdate().find();
});
```

## Realtime over WebSockets

```dart
final feed = db.channel('changes:orders', 'status=eq.open')..subscribe();
feed.changes.listen((c) => print('${c.type} ${c.record}'));   // insert | update | delete

final room = db.channel('room:lobby', null, {'name': 'Asha'})..subscribe();
room.on('cursor').listen((p) => print(p));
await room.ready();
room.sendBroadcast('cursor', {'x': 10});
room.presence.listen((p) => print(p.state));

final stop = await db.graphqlSubscribe('subscription { notes { body } }', (r) => print(r['data']));
```

Each subscriber receives only the rows their row-level security lets them read. Channels reconnect on their own.

## Auth

`signUp`, `signInWithPassword`, `signInWithOtp`/`verifyOtp`, `signInAnonymously` + `linkEmail`, `getOAuthSignInUrl(provider: 'google' | 'github' | 'microsoft')` + `exchangeCodeForSession(code)`, password recovery, `mfa.enroll/verify`, `listSessions`/`revokeSession`, `signOut`, `authStateChanges`, and `orgs` (create, invite, acceptInvitation, members, setRole). Keep sessions in encrypted device storage: pass `initialSession`, and write updated sessions from `authStateChanges`.

## Server: raw SQL and migrations (secret key)

```dart
final server = PlexivoClient(dataUrl, Platform.environment['PLEXIVO_SECRET_KEY']!);
await server.raw(r'select * from orders where total > $1', [100]);
await server.migrator.autoMigrate([postModel, commentModel]);   // creates what is missing, never drops
await server.migrate([PlexivoMigration.sql('001_slug', 'alter table posts add column slug text', 'alter table posts drop column slug')]);
```

## Also

`db.rpc('fn', {...})`, `db.graphql(query, persisted: true)`, `db.functions.invoke('name', body: {...})`, `db.storage.upload/download`, `db.getApi()`. Errors are `PlexivoException` with `code`, `message`, `hint`, `sqlstate`, `traceId` and, in a transaction, `operation`.

## Development

```sh
dart test
dart analyze
API_URL=… PUBLISHABLE_KEY=… SECRET_KEY=… dart run tool/e2e_frontend.dart   # against a live project
```
