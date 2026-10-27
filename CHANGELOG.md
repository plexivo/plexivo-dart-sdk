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
`PlexivoChange` objects. Needs a Plexivo Brain with the structured Data API
(R6.36).

## 0.1.0

- Initial staging package contract for Auth, lifecycle, TOTP MFA, starter-table CRUD, Realtime mutation events, and Trace ID errors.
