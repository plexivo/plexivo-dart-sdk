// The bulletproof end-to-end suite for plexivo_client: everything a Flutter
// or Dart developer does with Plexivo Postgres, against a live backend over
// real HTTP and WebSockets and a real PostgreSQL database.
//
//   dart run tool/e2e.dart                 # a fresh project from the local harness
//   POOLED=1 dart run tool/e2e.dart        # through the connection pooler (transaction mode)
//   API_URL=… PUBLISHABLE_KEY=… SECRET_KEY=… ALLOWED_ORIGIN=… dart run tool/e2e.dart
//
// Prints `ok <check>` or `FAIL <check> <details>` per check, then
// `N passed, M failed` and `ALL PASSED`; exits 0 only when everything passed.
import 'e2e/auth.dart';
import 'e2e/concurrency.dart';
import 'e2e/context.dart';
import 'e2e/data.dart';
import 'e2e/embeds.dart';
import 'e2e/harness.dart';
import 'e2e/realtime.dart';
import 'e2e/schema.dart';
import 'e2e/security.dart';
import 'e2e/writes.dart';

Future<void> main() async {
  final t = Suite();
  final project = await projectFromEnvironment();
  t.note('project ${project.url} (${project.pooled ? 'through the connection pooler' : 'direct'})');
  final c = Ctx(project);

  final ready = await t.check('setup: the schema, with the secret key (raw SQL, transactions of up to 50 statements)', () async {
    var done = 0;
    for (var i = 0; i < schemaStatements.length; i += 40) {
      final chunk = schemaStatements.sublist(i, i + 40 > schemaStatements.length ? schemaStatements.length : i + 40);
      done += (await c.server.sql.transaction(chunk)).length;
    }
    expect(done == schemaStatements.length, 'one result per statement', done);
    final api = await c.anon.getApi();
    final tables = (api['tables'] as List).map((x) => (x as Map)['name']).toSet();
    expect(tables.containsAll(['posts', 'comments', 'profiles', 'post_feed']) && !tables.contains('hidden') && !tables.contains('audit'),
        'exposed: RLS tables with a policy and the security_invoker view; not the others', tables);
  });
  if (!ready) t.finish();

  c.shortTokens = await shortTokenProject();
  await shortTokenSetup(t, c);

  await authChecks(t, c);
  await dataChecks(t, c);
  await embedChecks(t, c);
  await writeChecks(t, c);
  await realtimeChecks(t, c);
  await securityChecks(t, c);
  await concurrencyChecks(t, c);
  t.note('Plexivo Functions are not part of this backend (no functions runtime): skipped');
  t.finish();
}
