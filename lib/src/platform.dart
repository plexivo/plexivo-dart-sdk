import 'errors.dart';

/// Whether this program was compiled for the web (dart2js or dart2wasm).
const bool runningOnWeb = bool.fromEnvironment('dart.library.js_interop') || bool.fromEnvironment('dart.library.js_util');

/// Throws when [key] is a secret key and [web] is true: a web page cannot keep a secret.
///
/// The secret key bypasses row-level security; anyone can read it from a web
/// app's code. Apps use the publishable key, and servers keep the secret one.
void checkKeyForPlatform(String key, {bool web = runningOnWeb}) {
  if (web && key.startsWith('plx_secret_')) {
    throw PlexivoException(403, 'secret_key_in_browser',
        message: 'The secret key cannot be used in a web app: anyone can read it from the page, and it bypasses row-level security. '
            'Use the publishable key in the app, and keep the secret key on a server.',
        hint: 'Pass the publishable key from the Connect tab to PlexivoClient.');
  }
}
