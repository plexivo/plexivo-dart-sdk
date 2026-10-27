import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'errors.dart';
import 'model.dart';
import 'query.dart';
import 'realtime.dart';
import 'sql.dart';

/// The client for one Plexivo Postgres database.
///
/// One object for the Data API (Supabase-style and GORM-style queries on one
/// builder), models, transactions, authentication, file storage, realtime,
/// GraphQL and Plexivo Functions. With the secret key, on a server, it also
/// runs raw SQL, migrations and user import.
///
/// ```dart
/// final db = PlexivoClient(dataUrl, publishableKey);
///
/// await db.signInWithPassword(email: email, password: password);
/// final notes = await db.from('notes').select('id, body').eq('pinned', true);
///
/// db.authStateChanges.listen((state) => print(state.event));
/// ```
///
/// Keep one client for the life of your app. It holds the signed-in [session],
/// sends its access token with each request, and when the Data API reports
/// `token_expired` it refreshes the session once and retries.
class PlexivoClient implements DataLayer, RealtimeHost {
  /// Creates a client for the database at [apiUrl] with its [publishableKey].
  ///
  /// Both are on the database's **Connect** tab. Pass the secret key in place of
  /// the publishable key only in server code.
  ///
  /// - [httpClient] replaces the default `http.Client`, for tests or a custom
  ///   transport.
  /// - [initialSession] restores a [session] saved earlier, so the user stays
  ///   signed in across app restarts. Null starts signed out.
  /// - [realtimeClientId] is sent as `client_id` when a realtime channel joins.
  ///
  /// ```dart
  /// final saved = await loadSessionFromSecureStorage(); // may be null
  /// final db = PlexivoClient(dataUrl, publishableKey, initialSession: saved);
  /// db.authStateChanges.listen((s) => saveSessionToSecureStorage(s.session));
  /// ```
  PlexivoClient(this.apiUrl, this.publishableKey, {http.Client? httpClient, Map<String, dynamic>? initialSession, this.realtimeClientId})
      : _http = httpClient ?? http.Client(),
        _session = initialSession;

  /// The database's Data API URL, from the **Connect** tab.
  @override
  final String apiUrl;

  /// The project key sent with every request.
  ///
  /// Use the publishable key in apps. The secret key bypasses row-level security
  /// and belongs only on servers.
  @override
  final String publishableKey;

  /// An optional id sent as `client_id` when a realtime channel joins.
  ///
  /// Null sends none.
  final String? realtimeClientId;
  final http.Client _http;
  Map<String, dynamic>? _session;
  String? _lastTraceId;
  String? _pkceVerifier;
  Future<Map<String, dynamic>>? _refreshing;
  final _authChanges = StreamController<PlexivoAuthState>.broadcast();
  final _models = <String, PlexivoModel>{};

  /// The signed-in session as the server returned it, or null when signed out.
  ///
  /// It includes `access_token` and `refresh_token`. Save it in encrypted device
  /// storage and pass it back as `initialSession` to stay signed in.
  Map<String, dynamic>? get session => _session;

  /// The trace id of the most recent response, or null if it had none.
  ///
  /// Quote it to support when something looks wrong.
  String? get lastTraceId => _lastTraceId;

  /// Authentication events, as they happen.
  ///
  /// Each [PlexivoAuthState] names the event (`SIGNED_UP`, `SIGNED_IN`,
  /// `TOKEN_REFRESHED`, `USER_UPDATED`, `PASSWORD_CHANGED`, `USER_DELETED` or
  /// `SIGNED_OUT`) and carries the session after it. It is a broadcast stream
  /// and does not replay the current state: read [session] for that.
  ///
  /// ```dart
  /// db.authStateChanges.listen((state) {
  ///   if (state.session == null) {
  ///     router.go('/sign-in');
  ///   } else {
  ///     secureStorage.write(state.session);
  ///   }
  /// });
  /// ```
  Stream<PlexivoAuthState> get authStateChanges => _authChanges.stream;
  @override
  String? get accessToken => _session?['access_token']?.toString();

  /// Two-factor authentication (TOTP) for the signed-in user.
  PlexivoMfa get mfa => PlexivoMfa(this);

  /// File storage for the signed-in user.
  PlexivoStorage get storage => PlexivoStorage(this);

  /// Organisations, members and invitations for your app's users.
  PlexivoOrgs get orgs => PlexivoOrgs(this);

  /// Calls to your Plexivo Functions.
  PlexivoFunctions get functions => PlexivoFunctions(this);

  // ── data ───────────────────────────────────────────────────────────────

  /// Starts a query on [table].
  ///
  /// Chain filters, columns and order, then `await` the builder to read rows, or
  /// call a terminal method such as `first()`, `create()` or `count()`. If
  /// [model] defined [table], its primary key, relations, hooks, scopes and soft
  /// deletes apply. Queries go to the Data API (`POST /query/v1`), and
  /// row-level security decides what comes back.
  ///
  /// ```dart
  /// final open = await db.from('orders')
  ///     .where('status', 'open')
  ///     .order('created_at', 'desc')
  ///     .limit(20);
  ///
  /// final order = await db.from('orders').first(42); // or RecordNotFoundException
  /// await db.from('orders').where('id', 42).update({'status': 'paid'});
  /// ```
  ///
  /// See [PlexivoQuery] for everything a query can do.
  @override
  PlexivoQuery from(String table) => PlexivoQuery(ModelContext(this, table, _models[table]));

  /// Starts a query on [table]: the same as [from], in GORM's words.
  PlexivoQuery table(String table) => from(table);

  /// Defines the model for [table] and registers it on this client.
  ///
  /// From then on, every [from] on [table] uses it too. A second call for the
  /// same table replaces the first.
  ///
  /// - [primaryKey]: the key column, `id` by default.
  /// - [softDelete]: a timestamp column. Deletes set it instead of removing the
  ///   row, and reads skip rows where it is set.
  /// - [relations]: named [PlexivoRelation]s for `preload`, `joins`,
  ///   `whereHas`, `withCount` and [PlexivoModel.association].
  /// - [hooks]: [PlexivoHooks] run around reads and writes.
  /// - [scopes]: named, reusable query pieces for [PlexivoQuery.scopes].
  /// - [columns], [indexes], [policies], [compositeKey], [uniques], [checks] and
  ///   [rowLevelSecurity]: the schema [PlexivoMigrator.autoMigrate] creates.
  ///
  /// See [PlexivoModel] for an example.
  PlexivoModel model(String table,
      {String primaryKey = 'id',
      String? softDelete,
      Map<String, PlexivoRelation> relations = const {},
      PlexivoHooks hooks = const PlexivoHooks(),
      Map<String, PlexivoQuery Function(PlexivoQuery)> scopes = const {},
      Map<String, Object>? columns,
      List<Map<String, dynamic>> indexes = const [],
      List<Map<String, dynamic>> policies = const [],
      List<String>? compositeKey,
      List<Object> uniques = const [],
      List<String> checks = const [],
      bool? rowLevelSecurity}) {
    final m = PlexivoModel(this, table,
        primaryKey: primaryKey,
        softDelete: softDelete,
        relations: relations,
        hooks: hooks,
        scopes: scopes,
        columns: columns,
        indexes: indexes,
        policies: policies,
        compositeKey: compositeKey,
        uniques: uniques,
        checks: checks,
        rowLevelSecurity: rowLevelSecurity);
    _models[table] = m;
    return m;
  }

  @override
  PlexivoModel? modelOf(String table) => _models[table];
  @override
  bool get deferred => false;

  @override
  Future<Map<String, dynamic>> query(Map<String, dynamic> op) => _request('/query/v1', method: 'POST', body: op, auth: _Auth.optional);

  @override
  Future<T> send<T>(FutureOr<Map<String, dynamic>> Function() build, FutureOr<T> Function(Map<String, dynamic>) finish, String shape) async =>
      await finish(await query(await build()));

  /// Runs operations that commit together or not at all.
  ///
  /// Record operations on `tx` inside [callback] **without awaiting them**. When
  /// the callback has recorded them, they are sent in one request
  /// (`POST /query/v1/transaction`). Pass a value from one operation to a later
  /// one with `.ref('column')`. Returns each operation's result, in order; each
  /// recorded operation is also a Future of its own result.
  ///
  /// ```dart
  /// final results = await db.transaction((tx) {
  ///   final author = tx.from('authors').insert({'name': 'Asha'});
  ///   tx.from('posts').insert({'title': 'Hi', 'author_id': author.ref('id')});
  ///   tx.from('products').where('sku', 'B2').lockForUpdate().find();
  /// });
  /// ```
  ///
  /// If any operation fails, nothing is written and a [PlexivoException] is
  /// thrown, with [PlexivoException.operation] naming the failed operation.
  /// Recording an operation after awaiting one throws `transaction_already_sent`.
  /// Transactions do not nest: `tx.transaction` throws a [StateError]. An error
  /// thrown by [callback] is rethrown and nothing is sent. With no operations
  /// recorded, the result is an empty list.
  @override
  Future<List<dynamic>> transaction(FutureOr<void> Function(DataLayer tx) callback) async {
    final tx = _TxLayer(this);
    var settled = false;
    Object? failure;
    StackTrace? trace;
    final running = Future.sync(() => callback(tx)).then((_) {
      settled = true;
    }, onError: (Object e, StackTrace s) {
      settled = true;
      failure = e;
      trace = s;
    });
    while (true) {
      final before = tx.slots.length;
      await Future<void>.delayed(Duration.zero);
      if (settled) break;
      if (tx.slots.isNotEmpty && tx.slots.length == before && tx.building == 0) break;
    }
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
    if (tx.slots.isEmpty) return [];
    final results = await tx.commit();
    await running;
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
    return results;
  }

  /// Calls the database function [function] with named [args] and returns its result.
  ///
  /// Only functions exposed with `COMMENT ON FUNCTION … IS '@expose'` can be
  /// called (`POST /rest/v1/rpc/<function>`). They run as the signed-in user, or
  /// anonymously when signed out. The result is the function's return value
  /// decoded from JSON: a number, string, map, list, or null.
  ///
  /// ```dart
  /// final total = await db.rpc('cart_total', {'cart_id': 7});
  /// ```
  ///
  /// Throws a [PlexivoException] when the call fails.
  Future<dynamic> rpc(String function, [Map<String, dynamic> args = const {}]) async =>
      (await _request('/rest/v1/rpc/${Uri.encodeComponent(function)}', method: 'POST', body: args, auth: _Auth.optional))['data'];

  /// Runs a GraphQL query or mutation and returns `{data, errors}`.
  ///
  /// [variables] and [operationName] are sent as usual. With [persisted] true,
  /// the client sends only the query's SHA-256 hash (an automatic persisted
  /// query) and sends the full text only when the server has not seen it yet,
  /// which saves bandwidth on repeated calls.
  ///
  /// ```dart
  /// final r = await db.graphql(
  ///   r'query($b: String!) { notes(where: {body: {eq: $b}}) { body } }',
  ///   variables: {'b': 'Groceries'},
  /// );
  /// print(r['data']?['notes']);
  /// ```
  ///
  /// GraphQL errors come back in `errors`; a failed HTTP request throws a
  /// [PlexivoException].
  Future<Map<String, dynamic>> graphql(String query, {Map<String, dynamic> variables = const {}, String? operationName, bool persisted = false}) async {
    final base = <String, dynamic>{'variables': variables, if (operationName != null) 'operationName': operationName};
    Future<Map<String, dynamic>> post(Map<String, dynamic> body) => _request('/graphql/v1', method: 'POST', body: body, auth: _Auth.optional);
    if (!persisted) return post({'query': query, ...base});
    final extensions = {
      'persistedQuery': {'version': 1, 'sha256Hash': sha256.convert(utf8.encode(query)).toString()}
    };
    final first = await post({...base, 'extensions': extensions});
    final errors = (first['errors'] as List?) ?? const [];
    if (errors.any((e) => (e as Map)['message'] == 'PersistedQueryNotFound' || (e['extensions'] as Map?)?['code'] == 'PERSISTED_QUERY_NOT_FOUND')) {
      return post({'query': query, ...base, 'extensions': extensions});
    }
    return first;
  }

  /// Runs a live GraphQL query: [onResult] gets the answer now, and again whenever a row it reads changes.
  ///
  /// It runs over the realtime `graphql` channel, and each subscriber sees only
  /// the rows their row-level security allows. Returns a function that stops the
  /// subscription and closes its channel.
  ///
  /// ```dart
  /// final stop = await db.graphqlSubscribe(
  ///   'subscription { notes { body } }',
  ///   (result) => print(result['data']?['notes']),
  /// );
  /// // Later:
  /// await stop();
  /// ```
  ///
  /// If the server refuses the subscription, [onResult] gets a map with
  /// `errors`. The returned Future completes once the channel has joined.
  Future<Future<void> Function()> graphqlSubscribe(String query, void Function(Map<String, dynamic> result) onResult,
      {Map<String, dynamic> variables = const {}}) async {
    final id = 'q${Random().nextInt(1 << 31).toRadixString(36)}';
    final ch = channel('graphql');
    ch.onGraphql(id, onResult);
    ch.subscribe();
    await ch.ready();
    final reply = await ch.push('subscribe', {'id': id, 'query': query, 'variables': variables});
    if (reply['status'] != 'ok') {
      final response = reply['response'] as Map?;
      onResult({
        'errors': response?['errors'] ??
            [
              {'message': response?['reason'] ?? 'subscribe failed'}
            ]
      });
    }
    return () async {
      try {
        await ch.push('unsubscribe', {'id': id});
      } catch (_) {}
      await ch.unsubscribe();
    };
  }

  /// Describes the live Data API: every exposed table (columns, keys, relations) and function.
  ///
  /// Reads `GET /meta/api`. Useful for tooling and for checking that a table is
  /// exposed.
  Future<Map<String, dynamic>> getApi() => _request('/meta/api', auth: _Auth.optional);

  /// Creates a realtime channel on [topic]; call `subscribe()` to connect.
  ///
  /// Topics:
  /// - `changes:<table>`: row changes you may read. [filter] narrows them in
  ///   PostgREST form, such as `status=eq.open`.
  /// - `room:<name>`: broadcast and presence for everyone who joins; [presence]
  ///   is what this client shares about itself. `room:private:<name>` is for
  ///   signed-in users only.
  /// - `items` (the default) or another table name: the per-user starter channel.
  ///
  /// ```dart
  /// final feed = db.channel('changes:orders', 'status=eq.open')..subscribe();
  /// feed.changes.listen((c) => print('${c.type} ${c.record}'));
  ///
  /// final room = db.channel('room:lobby', null, {'name': 'Asha'})..subscribe();
  /// await room.ready();
  /// room.sendBroadcast('wave', {'from': 'Asha'});
  /// ```
  PlexivoRealtimeChannel channel([String topic = 'items', String? filter, Map<String, dynamic>? presence]) =>
      PlexivoRealtimeChannel(this, topic, filter: filter, presenceMeta: presence, clientId: realtimeClientId);

  // ── server: raw SQL and migrations (secret key) ────────────────────────

  /// Raw SQL and migrations, for servers holding the secret key.
  ///
  /// **Server only.** With the publishable key the platform refuses every call.
  /// Never ship the secret key in a Flutter app.
  late final PlexivoSql sql = PlexivoSql((path, body) => _request(path, method: 'POST', body: body));

  /// Runs [query] with `$1`, `$2` … [params] and returns its rows.
  ///
  /// **Server only, with the secret key.** The same as `sql.raw`; see
  /// [PlexivoSql.raw].
  ///
  /// ```dart
  /// final big = await server.raw(r'select * from orders where total > $1', [100]);
  /// ```
  Future<List<Map<String, dynamic>>> raw(String query, [List<Object?> params = const []]) => sql.raw(query, params);

  /// Runs a statement and returns its command tag and affected row count.
  ///
  /// **Server only, with the secret key.** The same as `sql.exec`; see
  /// [PlexivoSql.exec].
  Future<({String? command, int rowCount})> exec(String query, [List<Object?> params = const []]) => sql.exec(query, params);

  /// Schema inspection and changes, like GORM's Migrator.
  ///
  /// **Server only, with the secret key.** See [PlexivoMigrator].
  PlexivoMigrator get migrator => sql.migrator;

  /// Applies the [migrations] not yet applied, in order, and returns their ids.
  ///
  /// **Server only, with the secret key.** See [PlexivoSql.migrate].
  Future<List<String>> migrate(List<PlexivoMigration> migrations) => sql.migrate(migrations);

  /// Undoes the newest [steps] applied migrations and returns their ids.
  ///
  /// **Server only, with the secret key.** See [PlexivoSql.rollback].
  Future<List<String>> rollback(List<PlexivoMigration> migrations, {int steps = 1}) => sql.rollback(migrations, steps: steps);

  // ── auth ───────────────────────────────────────────────────────────────

  /// Creates an account with [email] and [password], and signs it in.
  ///
  /// Calls `POST /auth/signup`, stores the returned session in [session], emits
  /// `SIGNED_UP` on [authStateChanges] and returns the session. Follow your
  /// project's email-verification policy.
  ///
  /// ```dart
  /// await db.signUp(email: 'asha@example.com', password: 'a long password');
  /// print(db.session?['user']);
  /// ```
  ///
  /// Throws a [PlexivoException] if the account cannot be created, for example
  /// when the email is taken.
  Future<Map<String, dynamic>> signUp({required String email, required String password}) =>
      _authenticate('/auth/signup', {'email': email, 'password': password});

  /// Signs in with [email] and [password], and returns the new session.
  ///
  /// If the account has two-factor authentication on, pass the current code from
  /// the authenticator app as [mfaCode]. Stores the session in [session] and
  /// emits `SIGNED_IN`.
  ///
  /// ```dart
  /// try {
  ///   await db.signInWithPassword(email: email, password: password);
  /// } on PlexivoException catch (e) {
  ///   showError(e.message);
  /// }
  /// ```
  Future<Map<String, dynamic>> signInWithPassword({required String email, required String password, String? mfaCode}) =>
      _authenticate('/auth/login', {'email': email, 'password': password, if (mfaCode != null) 'mfa_code': mfaCode});

  /// Starts a guest session, when the project allows guests.
  ///
  /// The guest can read and write like any user. Call [linkEmail] later to turn
  /// it into a full account that keeps its id and rows.
  Future<Map<String, dynamic>> signInAnonymously() => _authenticate('/auth/anonymous', {});

  /// Turns the signed-in guest into an account with [email] and [password].
  ///
  /// The user keeps its id and rows. Updates [session] and emits `USER_UPDATED`.
  /// Throws a [StateError] when no one is signed in.
  Future<Map<String, dynamic>> linkEmail({required String email, required String password}) async {
    final s = await _request('/auth/upgrade', method: 'POST', body: {'email': email, 'password': password}, auth: _Auth.required);
    _setSession(s, 'USER_UPDATED');
    return s;
  }

  /// Starts sign-in with an identity [provider] such as `google`, `github` or `microsoft`.
  ///
  /// Open the returned URL in a browser. After sign-in the browser returns to
  /// [redirectTo] with a `code`; pass it to [exchangeCodeForSession]. The flow
  /// uses PKCE: the verifier is kept on this client (see [oauthCodeVerifier]).
  ///
  /// ```dart
  /// final url = db.getOAuthSignInUrl(provider: 'github', redirectTo: 'myapp://auth');
  /// await launchUrl(url);
  /// // When the app opens myapp://auth?code=…
  /// await db.exchangeCodeForSession(code);
  /// ```
  Uri getOAuthSignInUrl({required String provider, required String redirectTo}) {
    final random = Random.secure();
    final verifier = base64Url.encode(List<int>.generate(32, (_) => random.nextInt(256))).replaceAll('=', '');
    _pkceVerifier = verifier;
    final challenge = base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');
    return Uri.parse('${_base()}/auth/oauth/${Uri.encodeComponent(provider)}/authorize').replace(queryParameters: {
      'redirect_to': redirectTo,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      'apikey': publishableKey,
    });
  }

  /// The PKCE verifier of the last [getOAuthSignInUrl], or null if there is none.
  ///
  /// Save it if the app may restart mid sign-in, then pass it to
  /// [exchangeCodeForSession] as `codeVerifier`.
  String? get oauthCodeVerifier => _pkceVerifier;

  /// Finishes identity-provider sign-in with the [code] from the redirect.
  ///
  /// Uses [codeVerifier], or the one kept from [getOAuthSignInUrl]. Stores the
  /// session, emits `SIGNED_IN` and returns it. Throws a [StateError] when there
  /// is no verifier, and a [PlexivoException] when the code is refused.
  Future<Map<String, dynamic>> exchangeCodeForSession(String code, {String? codeVerifier}) async {
    final verifier = codeVerifier ?? _pkceVerifier;
    if (verifier == null) throw StateError('The PKCE code verifier from getOAuthSignInUrl is required');
    final s = await _request('/auth/oauth/token', method: 'POST', body: {'code': code, 'code_verifier': verifier});
    _pkceVerifier = null;
    _setSession(s, 'SIGNED_IN');
    return s;
  }

  /// The sign-in methods this project offers, as the server describes them.
  Future<Map<String, dynamic>> getAuthProviders() => _request('/auth/providers');

  /// Emails a password-reset code to [email].
  ///
  /// Finish with [verifyPasswordRecovery].
  Future<void> resetPasswordForEmail(String email) async {
    await _request('/auth/password/recovery', method: 'POST', body: {'email': email});
  }

  /// Sets [newPassword] for [email] using the [code] from the reset email.
  ///
  /// It does not sign in: call [signInWithPassword] afterwards.
  Future<void> verifyPasswordRecovery({required String email, required String code, required String newPassword}) async {
    await _request('/auth/password/reset', method: 'POST', body: {'email': email, 'code': code, 'new_password': newPassword});
  }

  /// Emails a one-time sign-in code to [email].
  ///
  /// Finish with [verifyOtp].
  Future<void> signInWithOtp(String email) async {
    await _request('/auth/passwordless', method: 'POST', body: {'email': email});
  }

  /// Signs in with the emailed one-time code [token], and returns the session.
  ///
  /// Pass [mfaCode] if the account has two-factor authentication on. Emits
  /// `SIGNED_IN`.
  Future<Map<String, dynamic>> verifyOtp({required String email, required String token, String? mfaCode}) =>
      _authenticate('/auth/passwordless/verify', {'email': email, 'code': token, if (mfaCode != null) 'mfa_code': mfaCode});

  /// Exchanges a refresh token for a fresh session.
  ///
  /// Uses [refreshToken], or the current session's. Emits `TOKEN_REFRESHED`. The
  /// client already does this on its own when an access token expires.
  Future<Map<String, dynamic>> refreshSession([String? refreshToken]) =>
      _authenticate('/auth/refresh', {'refresh_token': refreshToken ?? _session?['refresh_token']});

  /// The signed-in user, fresh from the server.
  ///
  /// Throws a [StateError] when no one is signed in.
  Future<Map<String, dynamic>> getUser() async => (await _request('/auth/user', auth: _Auth.required))['user'] as Map<String, dynamic>;

  /// The user's signed-in devices; `current` marks this one.
  ///
  /// Throws a [StateError] when no one is signed in.
  Future<List<Map<String, dynamic>>> listSessions() async =>
      ((await _request('/auth/sessions', auth: _Auth.required))['sessions'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();

  /// Signs out the device with [sessionId], from [listSessions].
  Future<void> revokeSession(String sessionId) async {
    await _request('/auth/sessions/${Uri.encodeComponent(sessionId)}', method: 'DELETE', auth: _Auth.required);
  }

  /// Changes the signed-in user's password.
  ///
  /// Needs [currentPassword]. Afterwards this client is signed out ([session]
  /// becomes null and `PASSWORD_CHANGED` is emitted), so sign in again with
  /// [newPassword].
  Future<void> updatePassword({required String currentPassword, required String newPassword}) async {
    await _request('/auth/password', method: 'POST', body: {'current_password': currentPassword, 'new_password': newPassword}, auth: _Auth.required);
    _setSession(null, 'PASSWORD_CHANGED');
  }

  /// Deletes the signed-in user's account, confirmed with their [password].
  ///
  /// Clears [session] and emits `USER_DELETED`. This cannot be undone.
  Future<void> deleteUser({required String password}) async {
    await _request('/auth/user', method: 'DELETE', body: {'password': password}, auth: _Auth.required);
    _setSession(null, 'USER_DELETED');
  }

  /// Signs out this device, or every device with [allSessions].
  ///
  /// The local session is cleared and `SIGNED_OUT` emitted even if the request
  /// fails. Throws a [StateError] when no one is signed in.
  ///
  /// ```dart
  /// await db.signOut();                  // this device
  /// await db.signOut(allSessions: true); // every device
  /// ```
  Future<void> signOut({bool allSessions = false}) async {
    try {
      await _request('/auth/logout',
          method: 'POST', body: allSessions ? {} : {'refresh_token': _session?['refresh_token']}, auth: _Auth.required, allowRefresh: false);
    } finally {
      _setSession(null, 'SIGNED_OUT');
    }
  }

  /// Imports the users of a migrated Supabase database, with their passwords.
  ///
  /// **Server only, with the secret key.** Returns the import summary.
  Future<Map<String, dynamic>> importUsersFromSupabase() => _request('/auth/admin/import/supabase', method: 'POST', body: {});

  /// Imports [users] from an export, with their bcrypt password hashes.
  ///
  /// **Server only, with the secret key.** Returns the import summary.
  Future<Map<String, dynamic>> importUsers(List<Map<String, dynamic>> users) => _request('/auth/admin/import', method: 'POST', body: {'users': users});

  Future<Map<String, dynamic>> _authenticate(String path, Map<String, dynamic> body) async {
    final result = await _request(path, method: 'POST', body: body);
    _setSession(
        result,
        path == '/auth/signup'
            ? 'SIGNED_UP'
            : path == '/auth/refresh'
                ? 'TOKEN_REFRESHED'
                : 'SIGNED_IN');
    return result;
  }

  void _setSession(Map<String, dynamic>? value, String event) {
    _session = value;
    _authChanges.add(PlexivoAuthState(event, value));
  }

  Future<Map<String, dynamic>> _refreshExpiredSession() {
    final active = _refreshing;
    if (active != null) return active;
    final refresh = refreshSession();
    _refreshing = refresh;
    return refresh.whenComplete(() {
      if (identical(_refreshing, refresh)) _refreshing = null;
    });
  }

  String _base() => apiUrl.replaceFirst(RegExp(r'/+$'), '');

  Future<Map<String, dynamic>> _request(String path,
      {String method = 'GET', Map<String, dynamic>? body, _Auth auth = _Auth.none, bool allowRefresh = true}) async {
    final headers = <String, String>{'content-type': 'application/json', 'apikey': publishableKey};
    final token = _session?['access_token'];
    if (auth == _Auth.required && token == null) throw StateError('An authenticated application user is required');
    final sendToken = auth != _Auth.none && token != null;
    if (sendToken) headers['authorization'] = 'Bearer $token';
    final request = http.Request(method, Uri.parse('${_base()}$path'))..headers.addAll(headers);
    if (body != null) request.body = jsonEncode(body);
    final response = await http.Response.fromStream(await _http.send(request));
    _lastTraceId = response.headers['x-trace-id'];
    final ok = response.statusCode >= 200 && response.statusCode < 300;
    Object? decoded;
    try {
      decoded = response.body.isEmpty ? <String, dynamic>{} : jsonDecode(response.body);
    } on FormatException {
      // A proxy's HTML error page, say: the failure still surfaces as a
      // PlexivoException with its status, not as a parser error.
      if (ok) throw PlexivoException(response.statusCode, 'invalid_response', message: 'The Data API returned a response that is not JSON', traceId: _lastTraceId);
      decoded = <String, dynamic>{};
    }
    final payload = decoded is Map ? Map<String, dynamic>.from(decoded) : <String, dynamic>{'data': decoded};
    if (!ok) {
      if (sendToken && allowRefresh && response.statusCode == 401 && payload['error']?['code'] == 'token_expired' && _session?['refresh_token'] != null) {
        await _refreshExpiredSession();
        return _request(path, method: method, body: body, auth: auth, allowRefresh: false);
      }
      throw _error(response, payload);
    }
    return payload;
  }

  PlexivoException _error(http.Response response, Map<String, dynamic>? payload) {
    final e = (payload?['error'] as Map?) ?? const {};
    final failed = response.headers['x-plexivo-failed-operation'] ?? response.headers['x-plexivo-failed-statement'];
    return PlexivoException(
      response.statusCode,
      e['code']?.toString() ?? 'request_failed',
      message: e['message']?.toString(),
      hint: e['hint']?.toString(),
      sqlstate: e['sqlstate']?.toString(),
      traceId: payload?['trace_id']?.toString() ?? _lastTraceId,
      details: e['details'],
      operation: failed == null ? null : int.tryParse(failed),
    );
  }

  Future<http.Response> _signedRequest(http.Request request) async {
    final response = await http.Response.fromStream(await _http.send(request));
    _lastTraceId = response.headers['x-trace-id'];
    if (response.statusCode < 200 || response.statusCode >= 300) {
      Map<String, dynamic>? payload;
      try {
        payload = jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {
        payload = null;
      }
      throw _error(response, payload);
    }
    return response;
  }
}

enum _Auth { none, optional, required }

/// One recorded operation of a transaction: a Future for its result, and refs for later operations.
class _TxHandle<T> implements Future<T>, RefSource {
  _TxHandle(this.index, this.shape);
  final int index;
  final String shape;
  final Completer<T> completer = Completer<T>();

  @override
  Map<String, dynamic> ref([String path = '']) {
    final prefix = shape == 'rows' ? 'data.0' : 'data';
    return {r'$ref': path.isEmpty ? '$index.$prefix' : '$index.$prefix.$path'};
  }

  Future<T> get _f => completer.future;
  @override
  Future<R> then<R>(FutureOr<R> Function(T value) onValue, {Function? onError}) => _f.then(onValue, onError: onError);
  @override
  Future<T> catchError(Function onError, {bool Function(Object error)? test}) => _f.catchError(onError, test: test);
  @override
  Future<T> whenComplete(FutureOr<void> Function() action) => _f.whenComplete(action);
  @override
  Future<T> timeout(Duration timeLimit, {FutureOr<T> Function()? onTimeout}) => _f.timeout(timeLimit, onTimeout: onTimeout);
  @override
  Stream<T> asStream() => _f.asStream();
}

class _Slot {
  _Slot(this.handle, this.finish);
  final _TxHandle<dynamic> handle;
  final FutureOr<dynamic> Function(Map<String, dynamic>) finish;
  Map<String, dynamic>? op;
  late Future<void> ready;
}

/// The `tx` of a transaction: operations are recorded, then sent together.
class _TxLayer implements DataLayer {
  _TxLayer(this._client);
  final PlexivoClient _client;
  final slots = <_Slot>[];
  var building = 0;
  var sent = false;

  @override
  bool get deferred => true;
  @override
  PlexivoModel? modelOf(String table) => _client.modelOf(table);
  @override
  PlexivoQuery from(String table) => PlexivoQuery(ModelContext(this, table, _client.modelOf(table)));
  @override
  Future<List<dynamic>> transaction(FutureOr<void> Function(DataLayer tx) callback) =>
      throw StateError('transactions do not nest: record the operations on this tx');
  @override
  Future<Map<String, dynamic>> query(Map<String, dynamic> op) => send(() => op, (r) => r, 'raw');

  @override
  Future<T> send<T>(FutureOr<Map<String, dynamic>> Function() build, FutureOr<T> Function(Map<String, dynamic>) finish, String shape) {
    if (sent) {
      throw PlexivoException(400, 'transaction_already_sent',
          message: 'This transaction was already sent. Record every operation before awaiting any of them, and use .ref() to pass one result to the next.');
    }
    final handle = _TxHandle<T>(slots.length, shape);
    handle.completer.future.ignore();
    final slot = _Slot(handle, (r) => finish(r));
    building++;
    slot.ready = Future.sync(build).then((op) {
      slot.op = op;
    }).whenComplete(() => building--);
    slots.add(slot);
    return handle;
  }

  Future<List<dynamic>> commit() async {
    await Future.wait(slots.map((s) => s.ready));
    sent = true;
    List<dynamic> results;
    try {
      results = (await _client._request('/query/v1/transaction',
          method: 'POST', body: {'operations': slots.map((s) => s.op).toList()}, auth: _Auth.optional))['results'] as List;
    } catch (e) {
      for (final s in slots) {
        s.handle.completer.completeError(e);
      }
      rethrow;
    }
    final out = <dynamic>[];
    for (var i = 0; i < slots.length; i++) {
      try {
        final value = await slots[i].finish(Map<String, dynamic>.from(results[i] as Map));
        slots[i].handle.completer.complete(value);
        out.add(value);
      } catch (e) {
        slots[i].handle.completer.completeError(e);
        rethrow;
      }
    }
    return out;
  }
}

/// One authentication event from [PlexivoClient.authStateChanges].
class PlexivoAuthState {
  /// Creates an event named [event] with the [session] after it.
  PlexivoAuthState(this.event, this.session);

  /// What happened.
  ///
  /// One of `SIGNED_UP`, `SIGNED_IN`, `TOKEN_REFRESHED`, `USER_UPDATED`,
  /// `PASSWORD_CHANGED`, `USER_DELETED` or `SIGNED_OUT`.
  final String event;

  /// The session after the event, or null when signed out.
  final Map<String, dynamic>? session;
}

/// Organisations for your app's own users: roles, members and invitations.
///
/// Every call needs a signed-in user and throws a [StateError] otherwise.
///
/// ```dart
/// final team = await db.orgs.create(name: 'Design team');
/// final invite = await db.orgs.invite(team['id'] as String, email: 'bob@example.com');
///
/// // Bob, signed in on his own device:
/// await bobDb.orgs.acceptInvitation(invite['token'] as String);
/// ```
class PlexivoOrgs {
  /// Creates the organisations API for a client; use [PlexivoClient.orgs].
  PlexivoOrgs(this._c);
  final PlexivoClient _c;
  String _o(String id) => '/auth/orgs/${Uri.encodeComponent(id)}';
  List<Map<String, dynamic>> _list(Map<String, dynamic> r) => (r['data'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();

  /// The organisations the signed-in user belongs to.
  Future<List<Map<String, dynamic>>> list() async => _list(await _c._request('/auth/orgs', auth: _Auth.required));

  /// Creates an organisation called [name], with the signed-in user as owner.
  ///
  /// [slug] and [metadata] are optional. Returns the organisation, including its
  /// `id` and the caller's `role`.
  Future<Map<String, dynamic>> create({required String name, String? slug, Map<String, dynamic>? metadata}) async =>
      Map<String, dynamic>.from((await _c._request('/auth/orgs',
          method: 'POST',
          body: {'name': name, if (slug != null) 'slug': slug, if (metadata != null) 'metadata': metadata},
          auth: _Auth.required))['data'] as Map);

  /// Deletes the organisation [orgId].
  Future<void> delete(String orgId) async => _c._request(_o(orgId), method: 'DELETE', auth: _Auth.required);

  /// The members of [orgId], with their roles.
  Future<List<Map<String, dynamic>>> members(String orgId) async => _list(await _c._request('${_o(orgId)}/members', auth: _Auth.required));

  /// Gives member [userId] of [orgId] a new [role].
  Future<void> setRole(String orgId, String userId, String role) async =>
      _c._request('${_o(orgId)}/members/${Uri.encodeComponent(userId)}', method: 'PATCH', body: {'role': role}, auth: _Auth.required);

  /// Removes member [userId] from [orgId].
  Future<void> removeMember(String orgId, String userId) async =>
      _c._request('${_o(orgId)}/members/${Uri.encodeComponent(userId)}', method: 'DELETE', auth: _Auth.required);

  /// The open invitations of [orgId].
  Future<List<Map<String, dynamic>>> invitations(String orgId) async => _list(await _c._request('${_o(orgId)}/invitations', auth: _Auth.required));

  /// Invites [email] to [orgId] with [role], `member` by default.
  ///
  /// Returns the invitation, including the `token` the invitee passes to
  /// [acceptInvitation].
  Future<Map<String, dynamic>> invite(String orgId, {required String email, String role = 'member'}) async => Map<String, dynamic>.from(
      (await _c._request('${_o(orgId)}/invitations', method: 'POST', body: {'email': email, 'role': role}, auth: _Auth.required))['data'] as Map);

  /// Withdraws invitation [invitationId] of [orgId].
  Future<void> revokeInvitation(String orgId, String invitationId) async =>
      _c._request('${_o(orgId)}/invitations/${Uri.encodeComponent(invitationId)}', method: 'DELETE', auth: _Auth.required);

  /// Joins an organisation with an invitation [token]; returns the membership.
  Future<Map<String, dynamic>> acceptInvitation(String token) async =>
      Map<String, dynamic>.from((await _c._request('/auth/invitations/accept', method: 'POST', body: {'token': token}, auth: _Auth.required))['data'] as Map);
}

/// Plexivo Functions: your server-side code beside the data.
///
/// ```dart
/// final res = await db.functions.invoke('send-receipt', body: {'orderId': 42});
/// print(res.status); // 200
/// print(res.data);   // decoded JSON, or the body as text
/// ```
class PlexivoFunctions {
  /// Creates the functions API for a client; use [PlexivoClient.functions].
  PlexivoFunctions(this._c);
  final PlexivoClient _c;

  /// Calls the function [name] and returns its `data`, `status` and `headers`.
  ///
  /// The request goes to `<apiUrl>/functions/v1/<name>/<path>?<query>`.
  ///
  /// - [body]: a `List<int>` is sent as bytes, a `String` as is, and anything
  ///   else as JSON (with `content-type: application/json` unless [headers] set
  ///   one). Null sends no body.
  /// - [method]: `POST` by default.
  /// - [headers]: extra request headers. When a user is signed in, their access
  ///   token is sent as `authorization`.
  /// - [path]: a sub-path; each segment is URL-encoded.
  /// - [query]: query parameters; null values are left out, others are sent as
  ///   text.
  ///
  /// `data` is decoded JSON when the response is `application/json`, otherwise
  /// the body as text.
  ///
  /// ```dart
  /// final res = await db.functions.invoke('reports',
  ///     method: 'GET', path: 'monthly/2026-10', query: {'format': 'json'});
  /// ```
  ///
  /// Throws an [ArgumentError] for an empty name, `.` or `..`, or a [path] with
  /// `.` or `..` segments, and a [PlexivoException] for a response outside 2xx.
  Future<({dynamic data, int status, Map<String, String> headers})> invoke(String name,
      {Object? body, String method = 'POST', Map<String, String> headers = const {}, String path = '', Map<String, Object?> query = const {}}) async {
    if (name.isEmpty || name == '.' || name == '..') throw ArgumentError.value(name, 'name', 'Invalid function name');
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.any((s) => s == '.' || s == '..')) throw ArgumentError.value(path, 'path', 'Function path must not contain dot segments');
    final suffix = segments.isEmpty ? '' : '/${segments.map(Uri.encodeComponent).join('/')}';
    var uri = Uri.parse('${_c._base()}/functions/v1/${Uri.encodeComponent(name)}$suffix');
    final params = {
      for (final e in query.entries)
        if (e.value != null) e.key: e.value.toString()
    };
    if (params.isNotEmpty) uri = uri.replace(queryParameters: params);
    final request = http.Request(method, uri)..headers.addAll({'apikey': _c.publishableKey, ...headers});
    final token = _c._session?['access_token'];
    if (token != null) request.headers['authorization'] = 'Bearer $token';
    if (body != null) {
      if (body is List<int>) {
        request.bodyBytes = body;
      } else if (body is String) {
        request.body = body;
      } else {
        request.headers.putIfAbsent('content-type', () => 'application/json');
        request.body = jsonEncode(body);
      }
    }
    final response = await _c._signedRequest(request);
    final type = response.headers['content-type'] ?? '';
    return (data: type.contains('application/json') ? jsonDecode(response.body) : response.body, status: response.statusCode, headers: response.headers);
  }
}

/// Two-factor authentication with an authenticator app (TOTP).
///
/// Every call needs a signed-in user and throws a [StateError] otherwise.
class PlexivoMfa {
  /// Creates the two-factor API for a client; use [PlexivoClient.mfa].
  PlexivoMfa(this._client);
  final PlexivoClient _client;

  /// Starts two-factor enrolment and returns the new TOTP factor.
  ///
  /// The factor carries what an authenticator app needs to add the account.
  /// Confirm it with [verify].
  Future<Map<String, dynamic>> enroll() async =>
      (await _client._request('/auth/mfa/totp/enroll', method: 'POST', body: {}, auth: _Auth.required))['factor'] as Map<String, dynamic>;

  /// Confirms enrolment with a [code] from the authenticator app; returns the factor.
  Future<Map<String, dynamic>> verify(String code) async =>
      (await _client._request('/auth/mfa/totp/verify', method: 'POST', body: {'code': code}, auth: _Auth.required))['factor'] as Map<String, dynamic>;

  /// Turns two-factor authentication off, confirmed with the user's [password].
  Future<void> unenroll({required String password}) async {
    await _client._request('/auth/mfa/totp', method: 'DELETE', body: {'password': password}, auth: _Auth.required);
  }
}

/// File storage for the signed-in user.
///
/// Bytes go straight to storage through short-lived signed URLs. Every call
/// needs a signed-in user and throws a [StateError] otherwise.
///
/// ```dart
/// final object = await db.storage.upload('avatars/me.png', pngBytes, contentType: 'image/png');
/// final file = await db.storage.download(object['id'] as String);
/// print('${file.bytes.length} bytes of ${file.contentType}');
/// ```
class PlexivoStorage {
  /// Creates the storage API for a client; use [PlexivoClient.storage].
  PlexivoStorage(this._client);
  final PlexivoClient _client;

  /// The signed-in user's stored objects.
  Future<List<Map<String, dynamic>>> list() async {
    final response = await _client._request('/storage/v1/objects', auth: _Auth.required);
    return (response['data'] as List<dynamic>).map((object) => Map<String, dynamic>.from(object as Map)).toList();
  }

  /// Uploads [bytes] to [path] with [contentType], and returns the stored object.
  ///
  /// The object includes its `id`, for [download], [createSignedDownloadUrl]
  /// and [remove]. Throws a [PlexivoException] if the upload is refused.
  Future<Map<String, dynamic>> upload(String path, List<int> bytes, {required String contentType}) async {
    final signed = (await _client._request('/storage/v1/objects/sign-upload',
        method: 'POST', body: {'path': path, 'content_type': contentType, 'size': bytes.length}, auth: _Auth.required))['data'] as Map<String, dynamic>;
    final upload = http.Request('PUT', Uri.parse(signed['signed_url'] as String))
      ..headers['content-type'] = contentType
      ..bodyBytes = bytes;
    final response = await _client._signedRequest(upload);
    return Map<String, dynamic>.from((jsonDecode(response.body) as Map<String, dynamic>)['data'] as Map);
  }

  /// A short-lived download link for object [id], as `signed_url`.
  ///
  /// Share it, or hand it to an image widget, without sending the user's token.
  Future<Map<String, dynamic>> createSignedDownloadUrl(String id) async => Map<String, dynamic>.from(
      (await _client._request('/storage/v1/objects/${Uri.encodeComponent(id)}/sign-download', method: 'POST', auth: _Auth.required))['data'] as Map);

  /// Downloads object [id]: its bytes and content type.
  Future<PlexivoStorageDownload> download(String id) async {
    final signed = await createSignedDownloadUrl(id);
    final response = await _client._signedRequest(http.Request('GET', Uri.parse(signed['signed_url'] as String)));
    return PlexivoStorageDownload(response.bodyBytes, response.headers['content-type']);
  }

  /// Deletes object [id].
  Future<void> remove(String id) async {
    await _client._request('/storage/v1/objects/${Uri.encodeComponent(id)}', method: 'DELETE', auth: _Auth.required);
  }
}

/// A downloaded file: its [bytes] and [contentType].
class PlexivoStorageDownload {
  /// Wraps downloaded [bytes] and their [contentType].
  PlexivoStorageDownload(this.bytes, this.contentType);

  /// The file's contents.
  final List<int> bytes;

  /// The file's media type, such as `image/png`; null when the server sent none.
  final String? contentType;
}
