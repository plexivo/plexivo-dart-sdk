// The Flutter half of the docs check: the example app (and the README's
// Flutter quick start, which tool/docs.dart writes into it) analysed, run as
// a widget test against a live Plexivo Postgres, the secret-key refusal
// tested in Chrome, and both built for the web.
//
//   dart run tool/flutter_check.dart       # a fresh project from the local harness
//
// tool/docs.dart runs it too. Set FLUTTER to the flutter executable when it
// is not on PATH; without Flutter (or Chrome, for the browser test) those
// checks are skipped with a note.
import 'dart:io';

import 'e2e/harness.dart';

/// Runs the Flutter checks as part of [t] against [project].
Future<void> run(Suite t, Project project, bool readmeApp) async {
  final root = File.fromUri(Platform.script).parent.parent;
  final app = '${root.path}/example/flutter_app';
  final flutter = Platform.environment['FLUTTER'] ?? 'flutter';
  Future<ProcessResult> sh(List<String> args, {String? cwd}) => Process.run(flutter, args, workingDirectory: cwd ?? app, runInShell: true);
  try {
    final v = await sh(['--version']);
    if (v.exitCode != 0) throw StateError('${v.stderr}');
  } catch (_) {
    t.note('Flutter is not installed (set FLUTTER): the widget test and web build were skipped');
    return;
  }
  final defines = ['--dart-define=PLEXIVO_URL=${project.url}', '--dart-define=PLEXIVO_PUBLISHABLE_KEY=${project.publishableKey}'];

  final got = await t.check('flutter: the example app resolves and analyses clean', () async {
    final get = await sh(['pub', 'get']);
    expect(get.exitCode == 0, 'pub get', get.stderr);
    final analyze = await sh(['analyze', '--no-fatal-infos']);
    expect(analyze.exitCode == 0, 'flutter analyze', '${analyze.stdout}${analyze.stderr}');
  }, timeout: const Duration(minutes: 5));
  if (!got) return;

  if (readmeApp) {
    await t.check('flutter: the README quick start as a widget test, live (guest, add, realtime, tick, sign out)', () async {
      final r = await sh(['test', ...defines, 'test/readme_quick_start_test.dart']);
      expect(r.exitCode == 0 && '${r.stdout}'.contains('All tests passed'), 'flutter test', '${r.stdout}${r.stderr}');
    }, timeout: const Duration(minutes: 8));
  }

  final chrome = Platform.environment['CHROME_EXECUTABLE'] ?? (Platform.isMacOS ? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' : null);
  if (chrome != null && (File(chrome).existsSync() || Platform.environment['CHROME_EXECUTABLE'] != null)) {
    await t.check('flutter web (Chrome): a web build refuses the secret key', () async {
      final r = await sh(['test', '--platform', 'chrome', 'test/web_secret_key_test.dart']);
      expect(r.exitCode == 0 && '${r.stdout}'.contains('All tests passed'), 'flutter test --platform chrome', '${r.stdout}${r.stderr}');
    }, timeout: const Duration(minutes: 8));
  } else {
    t.note('Chrome not found (set CHROME_EXECUTABLE): the in-browser secret-key test was skipped');
  }

  // A web build needs the web platform folder, so build a copy.
  final tmp = await Directory.systemTemp.createTemp('plexivo_flutter_web_');
  try {
    final copied = await t.check('flutter web: the app copied with its web platform', () async {
      for (final dir in ['lib', 'test']) {
        await _copy(Directory('$app/$dir'), Directory('${tmp.path}/$dir'));
      }
      final pubspec = File('$app/pubspec.yaml').readAsStringSync().replaceFirst('path: ../..', 'path: ${root.path}');
      File('${tmp.path}/pubspec.yaml').writeAsStringSync(pubspec);
      final create = await sh(['create', '--platforms=web', '--project-name', 'plexivo_flutter_example', '.'], cwd: tmp.path);
      expect(create.exitCode == 0, 'flutter create', '${create.stdout}${create.stderr}');
    }, timeout: const Duration(minutes: 5));
    if (copied) {
      final targets = ['lib/main.dart', if (readmeApp) 'lib/readme/quick_start_flutter.dart'];
      for (final target in targets) {
        await t.check('flutter build web: $target', () async {
          final r = await sh(['build', 'web', '-t', target, ...defines], cwd: tmp.path);
          expect(r.exitCode == 0 && File('${tmp.path}/build/web/main.dart.js').existsSync(), 'built', '${r.stdout}${r.stderr}');
        }, timeout: const Duration(minutes: 10));
      }
    }
  } finally {
    await tmp.delete(recursive: true);
  }
}

Future<void> _copy(Directory from, Directory to) async {
  await to.create(recursive: true);
  await for (final e in from.list()) {
    final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (e is Directory) {
      await _copy(e, Directory('${to.path}/$name'));
    } else if (e is File) {
      await e.copy('${to.path}/$name');
    }
  }
}

Future<void> main() async {
  final t = Suite();
  final project = await projectFromEnvironment();
  final readme = File.fromUri(Platform.script.resolve('../example/flutter_app/lib/readme/quick_start_flutter.dart')).existsSync();
  await run(t, project, readme);
  t.finish();
}
