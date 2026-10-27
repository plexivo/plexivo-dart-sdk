## 0.4.0

Joins, functions and realtime that look after themselves — every README
example now runs against a live Plexivo Postgres before release.

- **Order by a related column**: `order('profiles.username', 'desc')`, with a
  foreign-key hint (`'profiles!posts_author_fk.username'`) or a model
  relation name (`'author.username'`), as GORM's
  `Joins("Author").Order("Author.name")`. `orderReferenced('comments', 'id')`
  orders an embed's rows (Supabase's `referencedTable`).
- **Subqueries**: `whereIn('author_id', db.from('profiles').select('id').eq('country', 'IN'))`,
  `whereNotIn`, and `where(column, 'in', query)`; the subquery runs as the
  caller, under its table's row-level security.
- **Chainable `rpc`**: `db.rpc('search_posts', {'q': …})` is awaited as
  before, and now also takes `select` (with related rows), filters, `order`,
  `limit`, `range`, a count, `single()` and `maybeSingle()` for functions
  that return rows.
- **Preload by path**: `preload('comments.author')` and `joins('comments.author')`,
  as GORM's `Preload("Comments.Author")`, merging into an embed already in
  the query.
- **User metadata**: `signUp(…, data: {...})`, `updateUser(data: {...})`
  (merged; null removes a key) and `currentUser`, with `user_metadata`.
- **Realtime that stays joined**: after a dropped connection, a server
  `phx_close` / `phx_error`, or an expired access token, a channel refreshes
  the session if needed and rejoins by itself with backoff, and renews the
  token before it expires. A refused join is final and reported once. New
  `status`, `statusChanges`, `isJoined` and `reconnect()`; live GraphQL
  queries resubscribe after a rejoin.
- **Secret key refused on the web**: a web build throws
  `secret_key_in_browser` when given a `plx_secret_` key.
- **Fixes**: `DateTime` values in inserts and updates are sent as UTC ISO
  8601 (they failed to encode); `pluck()`, `exists()`, `count()` and other
  aggregates keep inner joins (`joins(…)`) as filters.
- **Docs and tests**: a new README (quick start in Flutter, auth, filters,
  joins, aggregates, upserts, transactions, raw SQL on a server, realtime,
  security recipes, types, errors, coming from Firebase and Supabase);
  `tool/docs.dart` runs every README block, the Flutter quick start as a
  widget test and a web build; `tool/e2e.dart` is the end-to-end suite,
  direct and through the connection pooler; `example/blog.sql`.

## 0.3.0

Plexivo Postgres as a Backend-as-a-Service, documented end to end.

- **Documentation**: a new README (quick start in five minutes, auth, data,
  realtime, GraphQL and live queries, Plexivo Functions, files, errors and
  null safety, security, coming from Firebase) and dartdoc on every public
  member, with examples, for the pub.dev API reference.
- **Examples**: `example/main.dart` (auth, todo CRUD, realtime, GraphQL with
  a live query, a function call), a Flutter app (`example/flutter_app`:
  sign-in, live todos, realtime chat), `example/schema.sql`,
  `example/setup.dart` and the `hello` function. Analyzed clean, and
  `example/main.dart` ran against a live Plexivo Postgres before release.
- **Functions**: `functions.invoke(name, path:, query:)` calls a sub-route
  with a query string, as the JavaScript client does.
- **Fixes**: a non-JSON error body (a proxy's error page) fails as a
  `PlexivoException` with its status; `signOut()` while signed out
  completes; a refused realtime join completes `ready()` with a
  `PlexivoException` and reaches `graphqlSubscribe`'s `onResult` instead of
  waiting forever.

## 0.2.0

Everything Plexivo Postgres offers, from Flutter and Dart.

- **Queries**: an immutable builder you `await`, with GORM-style conditions
  (operators, maps, groups, `whereNot`, `whereIn`, `whereBetween`, `whereNull`,
  JSON paths, arrays, full-text search, `whereHas`, `whereDoesntHave`) and
  Supabase / PostgREST names (`eq`, `inFilter`, `isFilter`, `or('a.eq.1,…')`,
  `match`, `not`, `textSearch`, `range`, `single`, `maybeSingle`), with
  PostgREST select strings and embeds.
- **Reading**: `first`, `last`, `take`, `find(ids)`, `firstOrNull`, `sole`,
  `pluck`, `count`, `exists`, `sum`/`avg`/`min`/`max`, `paginate`,
  `findInBatches`, `each()` stream, `distinct`, row locks.
- **Writing**: `create`, `createMany`, `createInBatches`, `insert`, `upsert`
  with chosen update columns or ignore, `save`, `update`/`delete` by filter,
  `updateById`/`deleteById`, `increment`/`decrement`, `firstOrCreate`,
  `firstOrInit`, `updateOrCreate`; unfiltered writes refused unless
  `allowGlobalUpdate()`.
- **Models**: relations (belongsTo, hasOne, hasMany, manyToMany), `preload`,
  `joins`, `withCount`, `withAggregate`, hooks, scopes, soft deletes,
  association mode.
- **Aggregates** grouped with `having`; **transactions** in one request with
  `.ref()` between steps and row locks.
- **Server (secret key)**: `raw`, `exec`, `sql.transaction`,
  `migrator.autoMigrate(models)`, the migrator, versioned `migrate`/`rollback`.
- **Auth**: guests and `linkEmail`, OAuth with PKCE, devices, organisations
  with roles and invitations, user import.
- **Realtime over WebSockets**: row-change feeds (with filters) delivered as
  each subscriber may read them, rooms with broadcast and presence, live
  GraphQL; reconnects on its own.
- **GraphQL** (persisted queries), **functions**, **RPC**, the live API
  description; typed `PlexivoException` (`code`, `message`, `hint`,
  `sqlstate`, `traceId`, `operation`) and `RecordNotFoundException`.

Breaking: `from(table)` returns the query builder (awaiting `select()` still
gives the rows, as a `PlexivoResult` list with `count`); `get/update/delete`
by id are `first(id)`, `updateById`, `deleteById`; channel changes are
`PlexivoChange` objects. Needs a Plexivo Postgres with the structured Data API.

## 0.1.0

- Initial staging package contract for Auth, lifecycle, TOTP MFA, starter-table CRUD, Realtime mutation events, and Trace ID errors.
