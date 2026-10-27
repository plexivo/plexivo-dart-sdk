// The plumbing of the end-to-end suite: a project to test against, checks
// that print `ok` / `FAIL` lines, and HTTP helpers for the negative tests.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:plexivo_client/plexivo_client.dart';

/// One Plexivo Postgres project: its Data API URL and keys.
class Project {
  /// A project with its [url], keys and allowed [origin].
  Project(this.url, this.publishableKey, this.secretKey, this.origin, this.pooled);

  /// The Data API URL.
  final String url;

  /// The key apps use.
  final String publishableKey;

  /// The key servers use.
  final String secretKey;

  /// A browser origin the project allows.
  final String origin;

  /// Whether the project reaches its database through the connection pooler.
  final bool pooled;
}

/// The harness's control endpoint, which answers a fresh project.
final controlUrl = Platform.environment['PLEXIVO_HARNESS_CONTROL'] ?? 'http://127.0.0.1:47801/projects';

/// Whether this run goes through the connection pooler.
final pooled = Platform.environment['POOLED'] == '1';

/// A fresh project from the harness's control endpoint, retrying while the harness restarts.
Future<Project> newProject({int? accessTokenTtl, List<String>? origins, bool? viaPooler}) async {
  final body =
      jsonEncode({'pooled': viaPooler ?? pooled, if (accessTokenTtl != null) 'access_token_ttl': accessTokenTtl, if (origins != null) 'origins': origins});
  Object? last;
  for (var attempt = 0; attempt < 60; attempt++) {
    try {
      final r = await http.post(Uri.parse(controlUrl), headers: {'content-type': 'application/json'}, body: body).timeout(const Duration(seconds: 60));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        final origin = j['origin'] as String? ?? (j['origins'] as List?)?.first as String? ?? 'https://app.example';
        return Project(j['api_url'] as String, j['publishable_key'] as String, j['secret_key'] as String, origin, j['pooled'] == true);
      }
      last = 'HTTP ${r.statusCode}';
    } catch (e) {
      last = e;
    }
    await Future<void>.delayed(const Duration(seconds: 5));
  }
  throw StateError('the harness control endpoint did not answer: $last');
}

/// The project named by the environment (`API_URL`, `PUBLISHABLE_KEY`, `SECRET_KEY`, `ALLOWED_ORIGIN`), or a fresh one.
Future<Project> projectFromEnvironment() async {
  final env = Platform.environment;
  final url = env['API_URL'];
  if (url != null && url.isNotEmpty) {
    return Project(url, env['PUBLISHABLE_KEY']!, env['SECRET_KEY']!, env['ALLOWED_ORIGIN'] ?? 'https://app.example', pooled);
  }
  return newProject();
}

/// A second project whose access tokens live 6 seconds, for the expiry tests, or null when none can be had.
///
/// `TTL_API_URL`, `TTL_PUBLISHABLE_KEY` and `TTL_SECRET_KEY` name one;
/// otherwise the harness's control endpoint makes one.
Future<Project?> shortTokenProject() async {
  final env = Platform.environment;
  final url = env['TTL_API_URL'];
  if (url != null && url.isNotEmpty) return Project(url, env['TTL_PUBLISHABLE_KEY']!, env['TTL_SECRET_KEY']!, env['ALLOWED_ORIGIN'] ?? '', pooled);
  try {
    final r =
        await http.post(Uri.parse(controlUrl), headers: {'content-type': 'application/json'}, body: jsonEncode({'pooled': pooled, 'access_token_ttl': 6}));
    if (r.statusCode != 200) return null;
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return Project(j['api_url'] as String, j['publishable_key'] as String, j['secret_key'] as String, (j['origin'] ?? '') as String, j['pooled'] == true);
  } catch (_) {
    return null;
  }
}

/// An `http.Client` that adds an `Origin` header to every request, as a browser does.
class OriginClient extends http.BaseClient {
  /// Sends [origin] with each request through [_inner].
  OriginClient(this.origin, [http.Client? inner]) : _inner = inner ?? http.Client();

  /// The origin sent.
  final String origin;
  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['origin'] = origin;
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

/// A broken expectation inside a check.
class CheckFailure implements Exception {
  /// Fails with [message].
  CheckFailure(this.message);

  /// What was wrong.
  final String message;
  @override
  String toString() => message;
}

/// Runs checks, prints one line each, and counts them.
class Suite {
  /// How many checks passed.
  var passed = 0;

  /// How many checks failed.
  var failed = 0;

  /// The names of failed checks.
  final failures = <String>[];

  /// Runs [body] as the check [name]: `ok name`, or `FAIL name details`.
  Future<bool> check(String name, FutureOr<void> Function() body, {Duration timeout = const Duration(seconds: 90)}) async {
    try {
      await Future.sync(body).timeout(timeout);
      passed++;
      stdout.writeln('ok $name');
      return true;
    } catch (e, st) {
      failed++;
      failures.add(name);
      final detail = e is CheckFailure ? e.message : '$e\n${st.toString().split('\n').take(4).join('\n')}';
      stdout.writeln('FAIL $name ${detail.replaceAll('\n', '\n    ')}');
      return false;
    }
  }

  /// A note: something skipped, and why.
  void note(String text) => stdout.writeln('# $text');

  /// Prints the count line (and `ALL PASSED`) and exits with 0 only when everything passed.
  Never finish() {
    stdout.writeln('$passed passed, $failed failed');
    if (failed == 0) {
      stdout.writeln('ALL PASSED');
    } else {
      stdout.writeln('Failed: ${failures.join('; ')}');
    }
    exit(failed == 0 ? 0 : 1);
  }
}

/// Fails the current check unless [cond] holds.
void expect(bool cond, String what, [Object? detail]) {
  if (!cond) throw CheckFailure('$what${detail == null ? '' : ': ${_short(detail)}'}');
}

/// Fails unless [actual] equals [expected] (deep, through JSON).
void expectEq(Object? actual, Object? expected, String what) {
  final a = jsonEncode(_canonical(actual)), b = jsonEncode(_canonical(expected));
  if (a != b) throw CheckFailure('$what: expected $b, got ${_short(a)}');
}

Object? _canonical(Object? v) {
  if (v is Map) {
    final keys = v.keys.map((k) => '$k').toList()..sort();
    return {for (final k in keys) k: _canonical(v[k])};
  }
  if (v is Iterable) return v.map(_canonical).toList();
  if (v is DateTime) return v.toIso8601String();
  return v;
}

String _short(Object? v) {
  final s = v is String
      ? v
      : (() {
          try {
            return jsonEncode(v);
          } catch (_) {
            return '$v';
          }
        })();
  return s.length > 600 ? '${s.substring(0, 600)}…' : s;
}

/// Awaits [f], which must fail with a [PlexivoException]; returns it.
///
/// [code] and [status], when given, must match. A result instead of an error fails the check.
Future<PlexivoException> refused(Future<Object?> f, {Object? code, int? status, String? what}) async {
  Object? result;
  try {
    result = await f;
  } on PlexivoException catch (e) {
    final codes = code is List ? code : (code == null ? null : [code]);
    if (codes != null && !codes.contains(e.code)) throw CheckFailure('${what ?? 'refusal'}: expected code ${codes.join('|')}, got $e');
    if (status != null && e.statusCode != status) throw CheckFailure('${what ?? 'refusal'}: expected status $status, got $e');
    return e;
  }
  throw CheckFailure('${what ?? 'refusal'}: expected an error, got data ${_short(result)}');
}

/// Waits until [cond] holds, up to [timeout].
Future<bool> eventually(bool Function() cond, {Duration timeout = const Duration(seconds: 10)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) return false;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return true;
}

/// A raw request to the Data API, outside the SDK, for the negative tests.
Future<({int status, Map<String, dynamic> body})> rawRequest(String url, String path,
    {String method = 'POST', Map<String, String> headers = const {}, Object? body}) async {
  final request = http.Request(method, Uri.parse('${url.replaceFirst(RegExp(r'/+$'), '')}$path'))
    ..headers.addAll({'content-type': 'application/json', ...headers});
  if (body != null) request.body = body is String ? body : jsonEncode(body);
  final response = await http.Response.fromStream(await http.Client().send(request));
  Map<String, dynamic> decoded;
  try {
    final j = jsonDecode(response.body);
    decoded = j is Map ? Map<String, dynamic>.from(j) : {'data': j};
  } catch (_) {
    decoded = {'raw': response.body.length > 200 ? response.body.substring(0, 200) : response.body};
  }
  return (status: response.statusCode, body: decoded);
}

/// The error code of a raw response body.
String? errorCode(Map<String, dynamic> body) => (body['error'] as Map?)?['code']?.toString();
