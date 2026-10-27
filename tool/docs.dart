// Runs every code block of README.md against a live Plexivo Postgres, and the
// examples it links to, so the documentation can never drift from the SDK.
//
//   dart run tool/docs.dart                # a fresh project from the local harness
//   API_URL=… PUBLISHABLE_KEY=… SECRET_KEY=… dart run tool/docs.dart
//   dart run tool/docs.dart --no-flutter   # skip the Flutter widget test and web build
//
// Conventions in README.md:
//
// * ```sql blocks run first, in order, with the secret key, after
//   example/blog.sql and example/schema.sql (the schema the examples use).
// * ```dart blocks of one `## ` section run in order as one program (each
//   section in its own function). Lines starting with `import ` are hoisted.
//   String literals naming a project are rewritten to the live one:
//   'https://api.plexivo.io/client/v1/…', 'plx_publishable_…' and
//   'plx_secret_…'; `…@example.com` emails get a per-run suffix.
// * `<!-- docs:prelude … -->` (an HTML comment, hidden on pub.dev) holds code
//   that runs at the start of its section, before the visible blocks; its
//   helpers are in tool/docs/helpers.dart.
// * `<!-- docs:compile-only <reason> -->` before a block compiles it with the
//   rest, without running it (an emailed code, a provider's redirect).
// * A ```dart block importing package:flutter is a Flutter example: it is
//   written to example/flutter_app/lib/readme/<section>.dart, where
//   tool/flutter_check.dart runs it as a widget test against the live project
//   and builds it for the web.
//
// Prints `ok …` / `FAIL …` per check, `N passed, M failed`, and `ALL PASSED`.
import 'dart:convert';
import 'dart:io';

import 'package:plexivo_client/plexivo_client.dart';

import 'e2e/harness.dart';
import 'flutter_check.dart' as flutter_check;

/// One fenced block of the README.
class Block {
  /// A block in [section] of language [lang].
  Block(this.section, this.lang, this.code, {this.compileOnly});

  /// The `## ` section it belongs to.
  final String section;

  /// The fence's language.
  final String lang;

  /// The code.
  final String code;

  /// Why it is only compiled, or null to run it.
  final String? compileOnly;
}

/// What the README holds: its blocks and each section's prelude.
({List<Block> blocks, Map<String, String> preludes}) parseReadme(String text) {
  final blocks = <Block>[];
  final preludes = <String, String>{};
  var section = 'Introduction';
  String? compileOnly;
  final lines = const LineSplitter().convert(text);
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.startsWith('## ')) {
      section = line.substring(3).trim();
      continue;
    }
    if (line.startsWith('<!-- docs:prelude')) {
      final body = StringBuffer();
      for (i++; i < lines.length && lines[i].trim() != '-->'; i++) {
        body.writeln(lines[i]);
      }
      preludes[section] = '${preludes[section] ?? ''}$body';
      continue;
    }
    final co = RegExp(r'^<!-- docs:compile-only (.*) -->$').firstMatch(line.trim());
    if (co != null) {
      compileOnly = co[1];
      continue;
    }
    final fence = RegExp(r'^```(\w+)\s*$').firstMatch(line);
    if (fence != null) {
      final body = StringBuffer();
      for (i++; i < lines.length && lines[i] != '```'; i++) {
        body.writeln(lines[i]);
      }
      blocks.add(Block(section, fence[1]!, body.toString(), compileOnly: compileOnly));
      compileOnly = null;
    }
  }
  return (blocks: blocks, preludes: preludes);
}

/// Splits SQL into statements, keeping `$$ … $$` bodies and quotes whole and dropping comments.
List<String> splitSql(String sql) {
  final out = <String>[];
  final cur = StringBuffer();
  var i = 0;
  String? dollar;
  var quoted = false;
  while (i < sql.length) {
    final ch = sql[i];
    if (dollar == null && !quoted && sql.startsWith('--', i)) {
      final end = sql.indexOf('\n', i);
      i = end < 0 ? sql.length : end;
      continue;
    }
    if (!quoted) {
      final tag = RegExp(r'\$[A-Za-z_]*\$').matchAsPrefix(sql, i);
      if (tag != null) {
        if (dollar == null) {
          dollar = tag[0];
        } else if (dollar == tag[0]) {
          dollar = null;
        }
        cur.write(tag[0]);
        i += tag[0]!.length;
        continue;
      }
    }
    if (dollar == null && ch == "'") quoted = !quoted;
    if (dollar == null && !quoted && ch == ';') {
      if (cur.toString().trim().isNotEmpty) out.add(cur.toString().trim());
      cur.clear();
    } else {
      cur.write(ch);
    }
    i++;
  }
  if (cur.toString().trim().isNotEmpty) out.add(cur.toString().trim());
  return out;
}

/// Rewrites the README's placeholder project and emails to the live run's.
String rewrite(String code) => code
    .replaceAllMapped(RegExp(r"'https://api\.plexivo\.io/client/v1/[^']*'"), (_) => 'docsUrl')
    .replaceAllMapped(RegExp(r"'plx_publishable_[^']*'"), (_) => 'docsPublishableKey')
    .replaceAllMapped(RegExp(r"'plx_secret_[^']*'"), (_) => 'docsSecretKey')
    .replaceAllMapped(RegExp(r"'([A-Za-z0-9._+-]+)@example\.com'"), (m) => "'${m[1]}-\$docsRun@example.com'");

String _slug(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');

/// The program that runs every Dart block, one function per section.
String program(List<Block> blocks, Map<String, String> preludes) {
  final imports = <String>{
    "import 'dart:async';",
    "import 'dart:io';",
    "import 'package:plexivo_client/plexivo_client.dart';",
    "import '../docs/helpers.dart';"
  };
  final sections = <String, List<Block>>{};
  for (final b in blocks.where((b) => b.lang == 'dart' && !b.code.contains('package:flutter/'))) {
    (sections[b.section] ??= []).add(b);
  }
  final fns = StringBuffer();
  final calls = <String>[];
  var n = 0;
  for (final entry in sections.entries) {
    final prelude = rewrite(preludes[entry.key] ?? '');
    final run = StringBuffer();
    for (final b in entry.value) {
      final body = rewrite(b.code.split('\n').where((l) {
        if (l.startsWith('import ')) {
          imports.add(l.trim());
          return false;
        }
        return true;
      }).join('\n'));
      if (b.compileOnly != null) {
        n++;
        fns.writeln('// Compiled, not run: ${b.compileOnly}\n// ignore: unused_element\nFuture<void> _compileOnly$n() async {\n'
            "  const codeFromEmail = '000000', codeFromRedirect = 'code', savedVerifier = 'verifier';\n$prelude\n$body\n}\n");
        calls.add("  skipped('${entry.key.replaceAll("'", r"\'")}: ${b.compileOnly!.replaceAll("'", r"\'")}');");
      } else {
        run.writeln('  {\n$body\n  }');
      }
    }
    if (run.isEmpty) continue;
    n++;
    fns.writeln('Future<void> _section$n() async {\n$prelude\n$run}\n');
    calls.add("  await section('${entry.key.replaceAll("'", r"\'")}', _section$n);");
  }
  return '''
// GENERATED by tool/docs.dart from README.md — do not edit.
${(imports.toList()..sort()).join('\n')}

var passed = 0, failed = 0;

Future<void> section(String name, Future<void> Function() body) async {
  final out = StringBuffer();
  Object? error;
  final done = Completer<void>();
  runZonedGuarded(() async {
    try {
      await body().timeout(const Duration(minutes: 2));
    } catch (e, st) {
      error ??= '\$e\\n\$st';
    }
    if (!done.isCompleted) done.complete();
  }, (e, st) {
    error ??= 'uncaught: \$e\\n\$st';
    if (!done.isCompleted) done.complete();
  }, zoneSpecification: ZoneSpecification(print: (self, parent, zone, line) => out.writeln(line)));
  await done.future;
  if (error == null) {
    passed++;
    stdout.writeln('ok README: \$name');
  } else {
    failed++;
    stdout.writeln('FAIL README: \$name \$error');
    stdout.writeln('    printed: \${out.toString().trim().replaceAll('\\n', '\\n    ')}');
  }
}

void skipped(String what) => stdout.writeln('# compiled, not run (\$what)');

$fns
Future<void> main() async {
${calls.join('\n')}
  stdout.writeln('README sections: \$passed passed, \$failed failed');
  exit(failed == 0 ? 0 : 1);
}
''';
}

Future<void> main(List<String> args) async {
  final t = Suite();
  final root = File.fromUri(Platform.script).parent.parent;
  String path(String p) => '${root.path}/$p';
  final project = await projectFromEnvironment();
  t.note('project ${project.url}');
  final env = {'PLEXIVO_URL': project.url, 'PLEXIVO_PUBLISHABLE_KEY': project.publishableKey, 'PLEXIVO_SECRET_KEY': project.secretKey};
  final server = PlexivoClient(project.url, project.secretKey);
  final readme = parseReadme(File(path('README.md')).readAsStringSync());

  Future<void> applySql(String sql) async {
    final statements = splitSql(sql);
    for (var i = 0; i < statements.length; i += 40) {
      await server.sql.transaction(statements.sublist(i, i + 40 > statements.length ? statements.length : i + 40));
    }
  }

  final schema = await t.check('example/blog.sql applies (the schema the README uses)', () => applySql(File(path('example/blog.sql')).readAsStringSync()));
  final setup = await t.check('example/setup.dart applies example/schema.sql', () async {
    final r = await Process.run(Platform.resolvedExecutable, ['run', 'example/setup.dart'],
        workingDirectory: root.path, environment: {'PLEXIVO_URL': project.url, 'PLEXIVO_SECRET_KEY': project.secretKey});
    expect(r.exitCode == 0, 'exit 0', '${r.stdout}${r.stderr}');
  });
  if (!schema || !setup) t.finish();

  var k = 0;
  for (final b in readme.blocks.where((b) => b.lang == 'sql')) {
    k++;
    await t.check('README sql #$k (${b.section})', () => applySql(b.code));
  }

  // Flutter examples: written into the example app, where flutter_check runs them.
  final flutterBlocks = readme.blocks.where((b) => b.lang == 'dart' && b.code.contains('package:flutter/')).toList();
  final dir = Directory(path('example/flutter_app/lib/readme'))..createSync(recursive: true);
  final counts = <String, int>{};
  for (final b in flutterBlocks) {
    final slug = _slug(b.section);
    final i = counts[slug] = (counts[slug] ?? 0) + 1;
    final file = File('${dir.path}/$slug${i == 1 ? '' : '_$i'}.dart');
    final content = '// GENERATED by tool/docs.dart from README.md (section "${b.section}") — do not edit.\n${b.code}';
    if (!file.existsSync() || file.readAsStringSync() != content) {
      file.writeAsStringSync(content);
      t.note('wrote ${file.path.substring(root.path.length + 1)} from the README');
    }
  }

  await t.check('README dart blocks: every section runs', () async {
    final out = Directory(path('tool/.docs'))..createSync(recursive: true);
    File('${out.path}/readme.dart').writeAsStringSync(program(readme.blocks, readme.preludes));
    final p = await Process.start(Platform.resolvedExecutable, ['run', 'tool/.docs/readme.dart'], workingDirectory: root.path, environment: env);
    final lines = <String>[];
    p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
      lines.add(l);
      stdout.writeln('  $l');
    });
    p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
      lines.add(l);
      stdout.writeln('  $l');
    });
    final code = await p.exitCode;
    expect(code == 0, 'every README section passed', lines.where((l) => l.startsWith('FAIL') || l.contains('Error')).take(5).toList());
  }, timeout: const Duration(minutes: 15));

  await t.check('example/main.dart runs end to end', () async {
    final r = await Process.run(Platform.resolvedExecutable, ['run', 'example/main.dart'], workingDirectory: root.path, environment: env);
    expect(r.exitCode == 0 && '${r.stdout}'.contains('realtime: insert') && '${r.stdout}'.contains('live counts'), 'exit 0 with realtime and live counts',
        '${r.stdout}${r.stderr}');
  }, timeout: const Duration(minutes: 3));

  if (args.contains('--no-flutter')) {
    t.note('--no-flutter: the Flutter widget test and web build were skipped');
  } else {
    await flutter_check.run(t, project, flutterBlocks.isNotEmpty);
  }
  t.finish();
}
