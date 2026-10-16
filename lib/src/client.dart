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

/// The client for Plexivo Postgres: data (Supabase-style and GORM-style on
/// one builder), models, transactions, auth, storage, realtime, GraphQL,
/// functions and — with the secret key, on a server — raw SQL and migrations.
class PlexivoClient implements DataLayer, RealtimeHost {
  PlexivoClient(this.apiUrl, this.publishableKey, {http.Client? httpClient, Map<String, dynamic>? initialSession, this.realtimeClientId})
      : _http = httpClient ?? http.Client(),
        _session = initialSession;

  @override
  final String apiUrl;

  /// The project key: publishable in apps; the secret key only on servers.
  @override
  final String publishableKey;
  final String? realtimeClientId;
  final http.Client _http;
  Map<String, dynamic>? _session;
  String? _lastTraceId;
  String? _pkceVerifier;
  Future<Map<String, dynamic>>? _refreshing;
  final _authChanges = StreamController<PlexivoAuthState>.broadcast();
  final _models = <String, PlexivoModel>{};

  Map<String, dynamic>? get session => _session;
  String? get lastTraceId => _lastTraceId;
  Stream<PlexivoAuthState> get authStateChanges => _authChanges.stream;
  @override
  String? get accessToken => _session?['access_token']?.toString();
  PlexivoMfa get mfa => PlexivoMfa(this);
  PlexivoStorage get storage => PlexivoStorage(this);
  PlexivoOrgs get orgs => PlexivoOrgs(this);
  PlexivoFunctions get functions => PlexivoFunctions(this);

  // ── data ───────────────────────────────────────────────────────────────

  /// A query on one table: chain filters, then await it or call a terminal method.
  @override
  PlexivoQuery from(String table) => PlexivoQuery(ModelContext(this, table, _models[table]));
  PlexivoQuery table(String table) => from(table);

  /// Defines a model: relations, hooks, scopes, soft deletes and columns for migrations.
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

  /// Operations that commit together or not at all. Record them on `tx`
  /// without awaiting; pass one result to the next with `.ref('id')`:
  ///
  /// ```dart
  /// final results = await db.transaction((tx) {
  ///   final author = tx.from('authors').insert({'name': 'Asha'});
  ///   tx.from('posts').insert({'title': 'Hi', 'author_id': author.ref('id')});
  /// });
  /// ```
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

  /// Calls a database function exposed with `COMMENT ON FUNCTION … IS '@expose'`.
  Future<dynamic> rpc(String function, [Map<String, dynamic> args = const {}]) async =>
      (await _request('/rest/v1/rpc/${Uri.encodeComponent(function)}', method: 'POST', body: args, auth: _Auth.optional))['data'];

  /// A GraphQL query or mutation: `{data, errors}`. `persisted: true` sends only the hash after the first time.
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

  /// A live query: the answer now, and again whenever a row it reads changes. Call the returned function to stop.
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

  /// The live Data API: every exposed table (columns, keys, relations) and function.
  Future<Map<String, dynamic>> getApi() => _request('/meta/api', auth: _Auth.optional);

  /// Realtime over a WebSocket: `changes:<table>` (with `filter`), `room:<name>` (with `presence`), or the starter `items`.
  PlexivoRealtimeChannel channel([String topic = 'items', String? filter, Map<String, dynamic>? presence]) =>
      PlexivoRealtimeChannel(this, topic, filter: filter, presenceMeta: presence, clientId: realtimeClientId);

  // ── server: raw SQL and migrations (secret key) ────────────────────────

  late final PlexivoSql sql = PlexivoSql((path, body) => _request(path, method: 'POST', body: body));
  Future<List<Map<String, dynamic>>> raw(String query, [List<Object?> params = const []]) => sql.raw(query, params);
  Future<({String? command, int rowCount})> exec(String query, [List<Object?> params = const []]) => sql.exec(query, params);
  PlexivoMigrator get migrator => sql.migrator;
  Future<List<String>> migrate(List<PlexivoMigration> migrations) => sql.migrate(migrations);
  Future<List<String>> rollback(List<PlexivoMigration> migrations, {int steps = 1}) => sql.rollback(migrations, steps: steps);

  // ── auth ───────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> signUp({required String email, required String password}) =>
      _authenticate('/auth/signup', {'email': email, 'password': password});

  Future<Map<String, dynamic>> signInWithPassword({required String email, required String password, String? mfaCode}) =>
      _authenticate('/auth/login', {'email': email, 'password': password, if (mfaCode != null) 'mfa_code': mfaCode});

  /// A guest session, when the project allows guests.
  Future<Map<String, dynamic>> signInAnonymously() => _authenticate('/auth/anonymous', {});

  /// The guest becomes an account, keeping its id and rows.
  Future<Map<String, dynamic>> linkEmail({required String email, required String password}) async {
    final s = await _request('/auth/upgrade', method: 'POST', body: {'email': email, 'password': password}, auth: _Auth.required);
    _setSession(s, 'USER_UPDATED');
    return s;
  }

  /// Sign in with Google, GitHub or Microsoft (OAuth with PKCE): open the
  /// returned URL in a browser, then pass the `code` from the redirect to
  /// [exchangeCodeForSession]. The verifier is kept on this client.
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

  /// The PKCE verifier of the last [getOAuthSignInUrl], to keep if the app may restart mid sign-in.
  String? get oauthCodeVerifier => _pkceVerifier;

  Future<Map<String, dynamic>> exchangeCodeForSession(String code, {String? codeVerifier}) async {
    final verifier = codeVerifier ?? _pkceVerifier;
    if (verifier == null) throw StateError('The PKCE code verifier from getOAuthSignInUrl is required');
    final s = await _request('/auth/oauth/token', method: 'POST', body: {'code': code, 'code_verifier': verifier});
    _pkceVerifier = null;
    _setSession(s, 'SIGNED_IN');
    return s;
  }

  Future<Map<String, dynamic>> getAuthProviders() => _request('/auth/providers');

  Future<void> resetPasswordForEmail(String email) async {
    await _request('/auth/password/recovery', method: 'POST', body: {'email': email});
  }

  Future<void> verifyPasswordRecovery({required String email, required String code, required String newPassword}) async {
    await _request('/auth/password/reset', method: 'POST', body: {'email': email, 'code': code, 'new_password': newPassword});
  }

  Future<void> signInWithOtp(String email) async {
    await _request('/auth/passwordless', method: 'POST', body: {'email': email});
  }

  Future<Map<String, dynamic>> verifyOtp({required String email, required String token, String? mfaCode}) =>
      _authenticate('/auth/passwordless/verify', {'email': email, 'code': token, if (mfaCode != null) 'mfa_code': mfaCode});

  Future<Map<String, dynamic>> refreshSession([String? refreshToken]) =>
      _authenticate('/auth/refresh', {'refresh_token': refreshToken ?? _session?['refresh_token']});

  Future<Map<String, dynamic>> getUser() async => (await _request('/auth/user', auth: _Auth.required))['user'] as Map<String, dynamic>;

  /// The user's signed-in devices; `current` marks this one.
  Future<List<Map<String, dynamic>>> listSessions() async =>
      ((await _request('/auth/sessions', auth: _Auth.required))['sessions'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();

  Future<void> revokeSession(String sessionId) async {
    await _request('/auth/sessions/${Uri.encodeComponent(sessionId)}', method: 'DELETE', auth: _Auth.required);
  }

  Future<void> updatePassword({required String currentPassword, required String newPassword}) async {
    await _request('/auth/password', method: 'POST', body: {'current_password': currentPassword, 'new_password': newPassword}, auth: _Auth.required);
    _setSession(null, 'PASSWORD_CHANGED');
  }

  Future<void> deleteUser({required String password}) async {
    await _request('/auth/user', method: 'DELETE', body: {'password': password}, auth: _Auth.required);
    _setSession(null, 'USER_DELETED');
  }

  Future<void> signOut({bool allSessions = false}) async {
    try {
      await _request('/auth/logout',
          method: 'POST', body: allSessions ? {} : {'refresh_token': _session?['refresh_token']}, auth: _Auth.required, allowRefresh: false);
    } finally {
      _setSession(null, 'SIGNED_OUT');
    }
  }

  /// Server-only, with the secret key: users from a migrated Supabase database, with their passwords.
  Future<Map<String, dynamic>> importUsersFromSupabase() => _request('/auth/admin/import/supabase', method: 'POST', body: {});

  /// Server-only, with the secret key: users from an export, with bcrypt hashes.
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
    final decoded = response.body.isEmpty ? <String, dynamic>{} : jsonDecode(response.body);
    final payload = decoded is Map ? Map<String, dynamic>.from(decoded) : <String, dynamic>{'data': decoded};
    if (response.statusCode < 200 || response.statusCode >= 300) {
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

class PlexivoAuthState {
  PlexivoAuthState(this.event, this.session);
  final String event;
  final Map<String, dynamic>? session;
}

/// Organisations for your app's own users: roles, members and invitations.
class PlexivoOrgs {
  PlexivoOrgs(this._c);
  final PlexivoClient _c;
  String _o(String id) => '/auth/orgs/${Uri.encodeComponent(id)}';
  List<Map<String, dynamic>> _list(Map<String, dynamic> r) => (r['data'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();

  Future<List<Map<String, dynamic>>> list() async => _list(await _c._request('/auth/orgs', auth: _Auth.required));
  Future<Map<String, dynamic>> create({required String name, String? slug, Map<String, dynamic>? metadata}) async =>
      Map<String, dynamic>.from((await _c._request('/auth/orgs',
          method: 'POST',
          body: {'name': name, if (slug != null) 'slug': slug, if (metadata != null) 'metadata': metadata},
          auth: _Auth.required))['data'] as Map);
  Future<void> delete(String orgId) async => _c._request(_o(orgId), method: 'DELETE', auth: _Auth.required);
  Future<List<Map<String, dynamic>>> members(String orgId) async => _list(await _c._request('${_o(orgId)}/members', auth: _Auth.required));
  Future<void> setRole(String orgId, String userId, String role) async =>
      _c._request('${_o(orgId)}/members/${Uri.encodeComponent(userId)}', method: 'PATCH', body: {'role': role}, auth: _Auth.required);
  Future<void> removeMember(String orgId, String userId) async =>
      _c._request('${_o(orgId)}/members/${Uri.encodeComponent(userId)}', method: 'DELETE', auth: _Auth.required);
  Future<List<Map<String, dynamic>>> invitations(String orgId) async => _list(await _c._request('${_o(orgId)}/invitations', auth: _Auth.required));
  Future<Map<String, dynamic>> invite(String orgId, {required String email, String role = 'member'}) async => Map<String, dynamic>.from(
      (await _c._request('${_o(orgId)}/invitations', method: 'POST', body: {'email': email, 'role': role}, auth: _Auth.required))['data'] as Map);
  Future<void> revokeInvitation(String orgId, String invitationId) async =>
      _c._request('${_o(orgId)}/invitations/${Uri.encodeComponent(invitationId)}', method: 'DELETE', auth: _Auth.required);
  Future<Map<String, dynamic>> acceptInvitation(String token) async =>
      Map<String, dynamic>.from((await _c._request('/auth/invitations/accept', method: 'POST', body: {'token': token}, auth: _Auth.required))['data'] as Map);
}

/// Plexivo Functions: your server-side code beside the data.
class PlexivoFunctions {
  PlexivoFunctions(this._c);
  final PlexivoClient _c;

  Future<({dynamic data, int status, Map<String, String> headers})> invoke(String name,
      {Object? body, String method = 'POST', Map<String, String> headers = const {}}) async {
    final request = http.Request(method, Uri.parse('${_c._base()}/functions/v1/${Uri.encodeComponent(name)}'))
      ..headers.addAll({'apikey': _c.publishableKey, ...headers});
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

class PlexivoMfa {
  PlexivoMfa(this._client);
  final PlexivoClient _client;

  Future<Map<String, dynamic>> enroll() async =>
      (await _client._request('/auth/mfa/totp/enroll', method: 'POST', body: {}, auth: _Auth.required))['factor'] as Map<String, dynamic>;

  Future<Map<String, dynamic>> verify(String code) async =>
      (await _client._request('/auth/mfa/totp/verify', method: 'POST', body: {'code': code}, auth: _Auth.required))['factor'] as Map<String, dynamic>;

  Future<void> unenroll({required String password}) async {
    await _client._request('/auth/mfa/totp', method: 'DELETE', body: {'password': password}, auth: _Auth.required);
  }
}

class PlexivoStorage {
  PlexivoStorage(this._client);
  final PlexivoClient _client;

  Future<List<Map<String, dynamic>>> list() async {
    final response = await _client._request('/storage/v1/objects', auth: _Auth.required);
    return (response['data'] as List<dynamic>).map((object) => Map<String, dynamic>.from(object as Map)).toList();
  }

  Future<Map<String, dynamic>> upload(String path, List<int> bytes, {required String contentType}) async {
    final signed = (await _client._request('/storage/v1/objects/sign-upload',
        method: 'POST', body: {'path': path, 'content_type': contentType, 'size': bytes.length}, auth: _Auth.required))['data'] as Map<String, dynamic>;
    final upload = http.Request('PUT', Uri.parse(signed['signed_url'] as String))
      ..headers['content-type'] = contentType
      ..bodyBytes = bytes;
    final response = await _client._signedRequest(upload);
    return Map<String, dynamic>.from((jsonDecode(response.body) as Map<String, dynamic>)['data'] as Map);
  }

  Future<Map<String, dynamic>> createSignedDownloadUrl(String id) async => Map<String, dynamic>.from(
      (await _client._request('/storage/v1/objects/${Uri.encodeComponent(id)}/sign-download', method: 'POST', auth: _Auth.required))['data'] as Map);

  Future<PlexivoStorageDownload> download(String id) async {
    final signed = await createSignedDownloadUrl(id);
    final response = await _client._signedRequest(http.Request('GET', Uri.parse(signed['signed_url'] as String)));
    return PlexivoStorageDownload(response.bodyBytes, response.headers['content-type']);
  }

  Future<void> remove(String id) async {
    await _client._request('/storage/v1/objects/${Uri.encodeComponent(id)}', method: 'DELETE', auth: _Auth.required);
  }
}

class PlexivoStorageDownload {
  PlexivoStorageDownload(this.bytes, this.contentType);
  final List<int> bytes;
  final String? contentType;
}
