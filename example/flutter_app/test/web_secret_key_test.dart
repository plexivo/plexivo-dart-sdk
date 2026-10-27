// In a web build the client refuses a secret key before sending anything:
//   flutter test --platform chrome test/web_secret_key_test.dart
@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:plexivo_client/plexivo_client.dart';

void main() {
  test('a web build refuses the secret key and accepts the publishable key', () {
    expect(() => PlexivoClient('https://api.plexivo.io/client/v1/data-x', 'plx_secret_example'),
        throwsA(isA<PlexivoException>().having((e) => e.code, 'code', 'secret_key_in_browser')));
    expect(PlexivoClient('https://api.plexivo.io/client/v1/data-x', 'plx_publishable_example').publishableKey, 'plx_publishable_example');
  });
}
