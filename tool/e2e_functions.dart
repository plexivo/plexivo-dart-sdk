// Run by the Brain's Functions integration test against a disposable project.
// Credentials are supplied through the process environment and never printed.
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:plexivo_client/plexivo_client.dart';

void expect(bool value, String label) {
  if (!value) {
    stderr.writeln('FAIL $label');
    exit(1);
  }
  stdout.writeln('ok $label');
}

Future<void> main() async {
  final url = Platform.environment['API_URL']!;
  final key = Platform.environment['PUBLISHABLE_KEY']!;
  final visitorHttp = http.Client();
  final userHttp = http.Client();
  final visitor = PlexivoClient(url, key, httpClient: visitorHttp);
  final user = PlexivoClient(url, key, httpClient: userHttp);
  try {
    final reply =
        await visitor.functions.invoke('echo', body: {'from': 'dart'});
    expect(
        reply.status == 200 &&
            reply.data['role'] == 'anon' &&
            (reply.data['body'] as String).contains('"from":"dart"'),
        'visitor function');
    final session = await user.signUp(
        email: 'dart-fn-${DateTime.now().microsecondsSinceEpoch}@example.test',
        password: 'a long test-only password');
    final signedIn = await user.functions.invoke('echo', method: 'GET');
    expect(
        signedIn.data['role'] == 'authenticated' &&
            signedIn.data['user'] == session['user']['id'] &&
            signedIn.data['method'] == 'GET',
        'signed-in function');
    var rejected = false;
    try {
      await visitor.functions.invoke('missing');
    } on PlexivoException catch (error) {
      rejected = error.statusCode == 404 && error.code == 'function_not_found';
    }
    expect(rejected, 'missing function is an error');
    stdout.writeln('ALL PASSED');
  } finally {
    visitorHttp.close();
    userHttp.close();
  }
}
