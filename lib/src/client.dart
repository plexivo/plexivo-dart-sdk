import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

class PlexivoClient {
  PlexivoClient(this.apiUrl, this.publishableKey,
      {http.Client? httpClient, Map<String, dynamic>? initialSession})
      : _http = httpClient ?? http.Client(),
        _session = initialSession;

  final String apiUrl;
  final String publishableKey;
  final http.Client _http;
  Map<String, dynamic>? _session;
  String? _lastTraceId;
  Future<Map<String, dynamic>>? _refreshing;
  final _authChanges = StreamController<PlexivoAuthState>.broadcast();

  Map<String, dynamic>? get session => _session;
  String? get lastTraceId => _lastTraceId;
  Stream<PlexivoAuthState> get authStateChanges => _authChanges.stream;
  PlexivoTable from(String table) => PlexivoTable(this, table);
  PlexivoMfa get mfa => PlexivoMfa(this);
  PlexivoStorage get storage => PlexivoStorage(this);

  Future<Map<String, dynamic>> signUp(
          {required String email, required String password}) =>
      _authenticate('/auth/signup', {'email': email, 'password': password});

  Future<Map<String, dynamic>> signInWithPassword(
          {required String email, required String password, String? mfaCode}) =>
      _authenticate('/auth/login', {
        'email': email,
        'password': password,
        if (mfaCode != null) 'mfa_code': mfaCode
      });

  Future<Map<String, dynamic>> getAuthProviders() =>
      _request('/auth/providers');

  Future<void> resetPasswordForEmail(String email) async {
    await _request('/auth/password/recovery',
        method: 'POST', body: {'email': email});
  }

  Future<void> verifyPasswordRecovery(
      {required String email,
      required String code,
      required String newPassword}) async {
    await _request('/auth/password/reset', method: 'POST', body: {
      'email': email,
      'code': code,
      'new_password': newPassword,
    });
  }

  Future<void> signInWithOtp(String email) async {
    await _request('/auth/passwordless',
        method: 'POST', body: {'email': email});
  }

  Future<Map<String, dynamic>> verifyOtp(
          {required String email, required String token, String? mfaCode}) =>
      _authenticate('/auth/passwordless/verify', {
        'email': email,
        'code': token,
        if (mfaCode != null) 'mfa_code': mfaCode,
      });

  Future<Map<String, dynamic>> refreshSession([String? refreshToken]) =>
      _authenticate(
        '/auth/refresh',
        {'refresh_token': refreshToken ?? _session?['refresh_token']},
      );

  Future<Map<String, dynamic>> getUser() async =>
      (await _request('/auth/user', authenticated: true))['user']
          as Map<String, dynamic>;

  Future<void> updatePassword(
      {required String currentPassword, required String newPassword}) async {
    await _request('/auth/password',
        method: 'POST',
        body: {
          'current_password': currentPassword,
          'new_password': newPassword
        },
        authenticated: true);
    _setSession(null, 'PASSWORD_CHANGED');
  }

  Future<void> deleteUser({required String password}) async {
    await _request('/auth/user',
        method: 'DELETE', body: {'password': password}, authenticated: true);
    _setSession(null, 'USER_DELETED');
  }

  Future<void> signOut({bool allSessions = false}) async {
    try {
      await _request('/auth/logout',
          method: 'POST',
          body:
              allSessions ? {} : {'refresh_token': _session?['refresh_token']},
          authenticated: true,
          allowRefresh: false);
    } finally {
      _setSession(null, 'SIGNED_OUT');
    }
  }

  PlexivoRealtimeChannel channel([String table = 'items']) =>
      PlexivoRealtimeChannel(this, table);

  Future<Map<String, dynamic>> _authenticate(
      String path, Map<String, dynamic> body) async {
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

  Future<Map<String, dynamic>> _request(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
    bool authenticated = false,
    bool allowRefresh = true,
  }) async {
    final headers = <String, String>{
      'content-type': 'application/json',
      'apikey': publishableKey
    };
    if (authenticated) {
      final accessToken = _session?['access_token'];
      if (accessToken == null)
        throw StateError('An authenticated application user is required');
      headers['authorization'] = 'Bearer $accessToken';
    }
    final request = http.Request(
        method, Uri.parse('${apiUrl.replaceFirst(RegExp(r'/+$'), '')}$path'))
      ..headers.addAll(headers);
    if (body != null) request.body = jsonEncode(body);
    final streamed = await _http.send(request);
    final response = await http.Response.fromStream(streamed);
    _lastTraceId = response.headers['x-trace-id'];
    final payload = response.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (authenticated &&
          allowRefresh &&
          response.statusCode == 401 &&
          payload['error']?['code'] == 'token_expired' &&
          _session?['refresh_token'] != null) {
        await _refreshExpiredSession();
        return _request(path,
            method: method,
            body: body,
            authenticated: true,
            allowRefresh: false);
      }
      throw PlexivoException(
        response.statusCode,
        payload['error']?['code']?.toString() ?? 'request_failed',
        traceId: payload['trace_id']?.toString() ?? _lastTraceId,
      );
    }
    return payload;
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
      throw PlexivoException(
        response.statusCode,
        payload?['error']?['code']?.toString() ?? 'request_failed',
        traceId: payload?['trace_id']?.toString() ?? _lastTraceId,
      );
    }
    return response;
  }
}

class PlexivoAuthState {
  PlexivoAuthState(this.event, this.session);
  final String event;
  final Map<String, dynamic>? session;
}

class PlexivoMfa {
  PlexivoMfa(this._client);
  final PlexivoClient _client;

  Future<Map<String, dynamic>> enroll() async =>
      (await _client._request('/auth/mfa/totp/enroll',
          method: 'POST',
          body: {},
          authenticated: true))['factor'] as Map<String, dynamic>;

  Future<Map<String, dynamic>> verify(String code) async =>
      (await _client._request('/auth/mfa/totp/verify',
          method: 'POST',
          body: {'code': code},
          authenticated: true))['factor'] as Map<String, dynamic>;

  Future<void> unenroll({required String password}) async {
    await _client._request('/auth/mfa/totp',
        method: 'DELETE', body: {'password': password}, authenticated: true);
  }
}

class PlexivoStorage {
  PlexivoStorage(this._client);
  final PlexivoClient _client;

  Future<List<Map<String, dynamic>>> list() async {
    final response =
        await _client._request('/storage/v1/objects', authenticated: true);
    return (response['data'] as List<dynamic>)
        .map((object) => Map<String, dynamic>.from(object as Map))
        .toList();
  }

  Future<Map<String, dynamic>> upload(String path, List<int> bytes,
      {required String contentType}) async {
    final signed = (await _client._request('/storage/v1/objects/sign-upload',
        method: 'POST',
        body: {
          'path': path,
          'content_type': contentType,
          'size': bytes.length,
        },
        authenticated: true))['data'] as Map<String, dynamic>;

    final upload =
        http.Request('PUT', Uri.parse(signed['signed_url'] as String))
          ..headers['content-type'] = contentType
          ..bodyBytes = bytes;
    final response = await _client._signedRequest(upload);
    return Map<String, dynamic>.from(
        (jsonDecode(response.body) as Map<String, dynamic>)['data'] as Map);
  }

  Future<Map<String, dynamic>> createSignedDownloadUrl(String id) async =>
      Map<String, dynamic>.from((await _client._request(
          '/storage/v1/objects/${Uri.encodeComponent(id)}/sign-download',
          method: 'POST',
          authenticated: true))['data'] as Map);

  Future<PlexivoStorageDownload> download(String id) async {
    final signed = await createSignedDownloadUrl(id);
    final response = await _client._signedRequest(
        http.Request('GET', Uri.parse(signed['signed_url'] as String)));
    return PlexivoStorageDownload(
        response.bodyBytes, response.headers['content-type']);
  }

  Future<void> remove(String id) async {
    await _client._request('/storage/v1/objects/${Uri.encodeComponent(id)}',
        method: 'DELETE', authenticated: true);
  }
}

class PlexivoStorageDownload {
  PlexivoStorageDownload(this.bytes, this.contentType);
  final List<int> bytes;
  final String? contentType;
}

class PlexivoTable {
  PlexivoTable(this._client, this._table);
  final PlexivoClient _client;
  final String _table;
  String get _path => '/rest/v1/${Uri.encodeComponent(_table)}';

  Future<List<dynamic>> select() async =>
      (await _client._request(_path, authenticated: true))['data']
          as List<dynamic>;
  Future<dynamic> insert(Map<String, dynamic> value) async =>
      (await _client._request(_path,
          method: 'POST', body: value, authenticated: true))['data'];
  Future<dynamic> get(String id) async =>
      (await _client._request('$_path/${Uri.encodeComponent(id)}',
          authenticated: true))['data'];
  Future<dynamic> update(String id, Map<String, dynamic> value) async =>
      (await _client._request('$_path/${Uri.encodeComponent(id)}',
          method: 'PATCH', body: value, authenticated: true))['data'];
  Future<dynamic> delete(String id) async =>
      (await _client._request('$_path/${Uri.encodeComponent(id)}',
          method: 'DELETE', authenticated: true))['data'];
}

class PlexivoRealtimeChannel {
  PlexivoRealtimeChannel(this._client, this._table);
  final PlexivoClient _client;
  final String _table;
  WebSocketChannel? _socket;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeat;
  Timer? _reconnect;
  var _active = false;
  var _reconnectAttempt = 0;
  var _ref = 1;
  final _changes = StreamController<Map<String, dynamic>>.broadcast();
  final _broadcasts = StreamController<PlexivoBroadcast>.broadcast();
  final _presence = StreamController<PlexivoPresence>.broadcast();
  Stream<Map<String, dynamic>> get changes => _changes.stream;
  Stream<PlexivoBroadcast> get broadcasts => _broadcasts.stream;
  Stream<PlexivoPresence> get presence => _presence.stream;

  void subscribe() {
    final accessToken = _client.session?['access_token'];
    if (accessToken == null) throw StateError('Sign in before subscribing');
    if (_active) return;
    _active = true;
    _connect();
  }

  void _connect() {
    final accessToken = _client.session?['access_token'];
    if (!_active || accessToken == null) return;
    final api = Uri.parse(_client.apiUrl);
    final project = api.pathSegments.last;
    final socketUri = Uri(
      scheme: api.scheme == 'https' ? 'wss' : 'ws',
      host: api.host,
      port: api.hasPort ? api.port : null,
      path: '/client-data/socket/websocket',
      queryParameters: {
        'vsn': '2.0.0',
        'project': project,
        'apikey': _client.publishableKey,
        'access_token': accessToken.toString(),
      },
    );
    final channel = WebSocketChannel.connect(socketUri);
    _socket = channel;
    channel.ready.then((_) {
      if (!_active || !identical(_socket, channel)) return;
      _reconnectAttempt = 0;
      _send('realtime:$_table', 'phx_join', {});
      _heartbeat?.cancel();
      _heartbeat = Timer.periodic(const Duration(seconds: 25),
          (_) => _send('phoenix', 'heartbeat', {}));
    }).catchError((_) => _scheduleReconnect());
    _subscription = channel.stream.listen((event) {
      final frame = jsonDecode(event.toString()) as List<dynamic>;
      if (frame.length != 5 || frame[2] != 'realtime:$_table') return;
      final name = frame[3];
      final payload = Map<String, dynamic>.from(frame[4] as Map);
      if (name == 'change') _changes.add(payload);
      if (name == 'broadcast') {
        _broadcasts.add(PlexivoBroadcast(
          payload['event']?.toString() ?? '',
          Map<String, dynamic>.from(payload['payload'] as Map? ?? {}),
        ));
      }
      if (name == 'presence_state' || name == 'presence_diff') {
        _presence.add(PlexivoPresence(name.toString(), payload));
      }
    }, onDone: _scheduleReconnect, onError: (_) => _scheduleReconnect());
  }

  void sendBroadcast(String event, [Map<String, dynamic> payload = const {}]) {
    if (!_active || _socket == null) {
      throw StateError('Realtime channel is not connected');
    }
    _send('realtime:$_table', 'broadcast', {
      'event': event,
      'payload': payload,
    });
  }

  void _send(String topic, String event, Map<String, dynamic> payload) {
    _socket?.sink.add(jsonEncode(['1', '${_ref++}', topic, event, payload]));
  }

  void _scheduleReconnect() {
    _heartbeat?.cancel();
    if (!_active || _reconnect?.isActive == true) return;
    final seconds = (1 << _reconnectAttempt.clamp(0, 3));
    _reconnectAttempt++;
    _reconnect = Timer(Duration(seconds: seconds), _connect);
  }

  Future<void> unsubscribe() async {
    _active = false;
    _heartbeat?.cancel();
    _reconnect?.cancel();
    await _subscription?.cancel();
    await _socket?.sink.close();
    await _changes.close();
    await _broadcasts.close();
    await _presence.close();
  }
}

class PlexivoBroadcast {
  PlexivoBroadcast(this.event, this.payload);
  final String event;
  final Map<String, dynamic> payload;
}

class PlexivoPresence {
  PlexivoPresence(this.event, this.state);
  final String event;
  final Map<String, dynamic> state;
}

class PlexivoException implements Exception {
  PlexivoException(this.statusCode, this.code, {this.traceId});
  final int statusCode;
  final String code;
  final String? traceId;
  @override
  String toString() =>
      'PlexivoException($statusCode, $code, traceId: $traceId)';
}
