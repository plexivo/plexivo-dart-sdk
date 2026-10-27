import 'dart:async';

import 'package:plexivo_client/plexivo_client.dart';

import 'context.dart';
import 'harness.dart';
import 'schema.dart';

/// Sign-up with metadata, sign-in, guests, sessions, OTP, OAuth, sign-out.
Future<void> authChecks(Suite t, Ctx c) async {
  final events = <String>[];
  c.alice.authStateChanges.listen((s) => events.add(s.event));

  final ok = await t.check('auth: sign up with profile metadata (user_metadata)', () async {
    final s = await c.alice.signUp(email: c.email('alice'), password: password, data: {'name': 'Alice', 'plan': 'pro'});
    c.aliceId = (s['user'] as Map)['id'] as String;
    expect(s['access_token'] is String && s['refresh_token'] is String, 'a session with tokens', s.keys.toList());
    expectEq((s['user'] as Map)['user_metadata'], {'name': 'Alice', 'plan': 'pro'}, 'user_metadata in the session');
    expectEq(c.alice.currentUser?['user_metadata'], {'name': 'Alice', 'plan': 'pro'}, 'currentUser');
    c.bobId = ((await c.bob.signUp(email: c.email('bob'), password: password))['user'] as Map)['id'] as String;
    c.carolId = ((await c.carol.signUp(email: c.email('carol'), password: password))['user'] as Map)['id'] as String;
    await Future<void>.delayed(Duration.zero);
    expect(events.contains('SIGNED_UP'), 'SIGNED_UP on authStateChanges', events);
  });
  if (!ok) {
    t.note('sign-up failed: the remaining checks need users');
    t.finish();
  }

  await t.check('auth: getUser includes user_metadata; updateUser merges and removes keys', () async {
    expectEq((await c.alice.getUser())['user_metadata'], {'name': 'Alice', 'plan': 'pro'}, 'getUser');
    final user = await c.alice.updateUser(data: {'theme': 'dark', 'plan': null});
    expectEq(user['user_metadata'], {'name': 'Alice', 'theme': 'dark'}, 'merged metadata');
    expectEq((await c.alice.getUser())['user_metadata'], {'name': 'Alice', 'theme': 'dark'}, 'fresh from the server');
    expectEq(c.alice.currentUser?['user_metadata'], {'name': 'Alice', 'theme': 'dark'}, 'session user updated');
    await Future<void>.delayed(Duration.zero);
    expect(events.contains('USER_UPDATED'), 'USER_UPDATED emitted', events);
    final again = c.client();
    final s = await again.signInWithPassword(email: c.email('alice'), password: password);
    expectEq((s['user'] as Map)['user_metadata'], {'name': 'Alice', 'theme': 'dark'}, 'metadata in a new session');
    await again.signOut();
  });

  await t.check('auth: metadata over 4 KB is refused (metadata_too_large)', () async {
    final big = {'blob': 'x' * 5000};
    await refused(c.client().signUp(email: c.email('big'), password: password, data: big), code: 'metadata_too_large', status: 422);
    await refused(c.alice.updateUser(data: big), code: 'metadata_too_large', status: 422);
    expectEq((await c.alice.getUser())['user_metadata'], {'name': 'Alice', 'theme': 'dark'}, 'unchanged after the refusal');
  });

  await t.check('auth: wrong password and a taken email are refused with typed errors', () async {
    final e = await refused(c.client().signInWithPassword(email: c.email('alice'), password: 'wrong password 999'));
    expect(e.statusCode == 400 || e.statusCode == 401, 'a 400/401', e);
    expect(e.code != 'request_failed' && e.traceId != null, 'a code and a trace id', e);
    final taken = await refused(c.client().signUp(email: c.email('alice'), password: password));
    expect(taken.statusCode >= 400 && taken.statusCode < 500, 'a 4xx for a taken email', taken);
    await refused(c.client().signUp(email: c.email('weak'), password: 'short'), code: 'weak_password', status: 422);
  });

  await t.check('auth: profiles for each user (insert as yourself)', () async {
    await c.alice.from('profiles').insert({'username': 'alice_${c.n}', 'country': 'IN'});
    await c.bob.from('profiles').insert({'username': 'bob_${c.n}', 'country': 'GB'});
    await c.carol.from('profiles').insert({'username': 'carol_${c.n}'});
    final all = await c.anon.from('profiles').select('id, username').inFilter('id', [c.aliceId, c.bobId, c.carolId]);
    expect(all.length == 3, 'three profiles, readable signed out', all);
    await refused(c.bob.from('profiles').insert({'id': c.carolId, 'username': 'impostor_${c.n}'}), code: 'permission_denied', status: 403);
  });

  await t.check('auth: sessions are listed and one can be revoked', () async {
    final second = c.client();
    await second.signInWithPassword(email: c.email('carol'), password: password);
    final sessions = await c.carol.listSessions();
    expect(sessions.length >= 2 && sessions.where((s) => s['current'] == true).length == 1, 'two devices, one current', sessions);
    final other = sessions.firstWhere((s) => s['current'] != true);
    await c.carol.revokeSession((other['id'] ?? other['session_id']).toString());
    await refused(second.refreshSession(), what: 'the revoked device can no longer refresh');
    expect((await c.carol.listSessions()).length == sessions.length - 1, 'one device fewer');
  });

  await t.check('auth: a guest writes rows, then becomes an account with the same id and rows', () async {
    final guest = c.client();
    final g = await guest.signInAnonymously();
    final id = (g['user'] as Map)['id'];
    expect((g['user'] as Map)['is_anonymous'] == true, 'is_anonymous', g['user']);
    await guest.from('notes').insert({'body': 'guest note'});
    final up = await guest.linkEmail(email: c.email('guest'), password: password);
    expect((up['user'] as Map)['id'] == id && (up['user'] as Map)['is_anonymous'] == false, 'same id, now an account', up['user']);
    expect((await guest.from('notes').select('body')).map((r) => r['body']).join() == 'guest note', 'its rows stay');
    final back = c.client();
    await back.signInWithPassword(email: c.email('guest'), password: password);
    expect((await back.from('notes').select('body')).length == 1, 'signs in with the new email and sees them');
  });

  await t.check('auth: one-time code is requested; a wrong code is refused', () async {
    await c.client().signInWithOtp(c.email('alice'));
    await refused(c.client().verifyOtp(email: c.email('alice'), token: '000000'), what: 'a wrong code');
    await c.client().resetPasswordForEmail(c.email('alice'));
    await refused(c.client().verifyPasswordRecovery(email: c.email('alice'), code: '000000', newPassword: 'another long password 1'),
        what: 'a wrong recovery code');
    await c.client().signInWithPassword(email: c.email('alice'), password: password);
  });

  await t.check('auth: OAuth URL carries a PKCE S256 challenge; a bogus code is refused', () async {
    final db = c.client();
    final url = db.getOAuthSignInUrl(provider: 'github', redirectTo: 'myapp://auth');
    expect(url.queryParameters['code_challenge_method'] == 'S256' && (url.queryParameters['code_challenge'] ?? '').length >= 43, 'challenge', url);
    expect(db.oauthCodeVerifier != null, 'verifier kept');
    await refused(db.exchangeCodeForSession('not-a-real-code'), what: 'a bogus code');
    expect((await db.getAuthProviders()).isNotEmpty, 'providers answer');
  });

  await t.check('auth: sign-out clears the session; the old refresh token is dead; data reads as anon', () async {
    final db = c.client();
    await db.signInWithPassword(email: c.email('bob'), password: password);
    final refreshToken = db.session!['refresh_token'] as String;
    await db.from('notes').insert({'body': 'bob private'});
    final states = <String>[];
    db.authStateChanges.listen((s) => states.add(s.event));
    await db.signOut();
    await Future<void>.delayed(Duration.zero);
    expect(db.session == null && states.contains('SIGNED_OUT'), 'signed out', states);
    expect((await db.from('notes').select()).isEmpty, 'reads as anon: no private rows');
    await refused(c.client().refreshSession(refreshToken), what: 'the signed-out refresh token');
  });

  await t.check('auth: sign-out everywhere ends every device', () async {
    final a = c.client(), b = c.client();
    final who = c.email('everywhere');
    await a.signUp(email: who, password: password);
    await b.signInWithPassword(email: who, password: password);
    final bRefresh = b.session!['refresh_token'] as String;
    await a.signOut(allSessions: true);
    await refused(c.client().refreshSession(bRefresh), what: 'the other device');
  });

  // ── access-token expiry, on a project whose tokens live 6 seconds ────────
  final short = c.shortTokens;
  if (short == null) {
    t.note('no short-token project (set TTL_API_URL/TTL_PUBLISHABLE_KEY/TTL_SECRET_KEY or run beside the harness): expiry checks skipped');
    return;
  }
  await t.check('auth: an expired access token is refreshed once and the request retried (TOKEN_REFRESHED)', () async {
    final db = PlexivoClient(short.url, short.publishableKey);
    await db.signUp(email: c.email('ttl'), password: password);
    await db.from('notes').insert({'body': 'before expiry'});
    final first = db.session!['access_token'];
    final states = <String>[];
    db.authStateChanges.listen((s) => states.add(s.event));
    await Future<void>.delayed(const Duration(seconds: 8));
    final rows = await db.from('notes').select('body');
    expect(rows.length == 1, 'the read succeeded after expiry', rows);
    expect(db.session!['access_token'] != first && states.contains('TOKEN_REFRESHED'), 'refreshed', states);
  }, timeout: const Duration(seconds: 60));
}

/// Builds the short-token project's schema.
Future<void> shortTokenSetup(Suite t, Ctx c) async {
  final short = c.shortTokens;
  if (short == null) return;
  final ok = await t.check('setup: the short-token project (6-second access tokens)', () async {
    await PlexivoClient(short.url, short.secretKey).sql.transaction(shortTokenSchema);
  });
  if (!ok) c.shortTokens = null;
}

/// Waits for [stream] to emit something matching [test].
Future<T?> firstWhere<T>(Stream<T> stream, bool Function(T) test, {Duration timeout = const Duration(seconds: 10)}) async {
  try {
    return await stream.firstWhere(test).timeout(timeout);
  } on TimeoutException {
    return null;
  }
}
