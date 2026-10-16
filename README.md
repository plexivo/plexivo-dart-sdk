# Plexivo Client for Flutter and Dart

Use the project API URL and publishable key from Plexivo. Never embed a database URL or server-only secret key in a Flutter application.

```dart
final plexivo = PlexivoClient(dataUrl, publishableKey);
await plexivo.signInWithPassword(email: email, password: password);
final items = await plexivo.from('items').select();
```

The SDK supports application-user signup/login/refresh, password changes, server-side sign-out, self-service account disablement, TOTP MFA, RLS-backed HTTPS CRUD, and realtime item changes. An expired access token is refreshed once and the original request is retried.

Pass `initialSession` from encrypted device storage when constructing the client and write updated sessions from `authStateChanges` back to that encrypted store. The package intentionally does not place tokens in unencrypted preferences.

```dart
final factor = await plexivo.mfa.enroll();
// Render factor['uri'] as a QR code and collect a six-digit authenticator code.
await plexivo.mfa.verify(code);
await plexivo.signOut();
```

Password recovery delivery, social OAuth, arbitrary schemas, Functions, WAL change capture and advanced Storage are not part of the verified staging surface.

The minimal private Storage client is source-tested but disabled until a dedicated bucket-scoped MinIO identity and hostile staging acceptance exist:

```dart
final object = await plexivo.storage.upload(
  'documents/readme.txt',
  bytes,
  contentType: 'text/plain',
);
final downloaded = await plexivo.storage.download(object['id'] as String);
```

This surface does not claim resumable upload, CDN delivery, transforms, malware scanning, retention policies or public buckets.
