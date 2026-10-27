# Flutter example

A Flutter app on Plexivo Postgres: email sign-in, a todo list that stays in sync across devices, and a realtime chat with a typing indicator. Only the publishable key is in the app.

1. Create the example tables with [`../schema.sql`](../schema.sql) (or `dart run example/setup.dart` from the package root) and switch Realtime on for `todos` and `messages` in the console. For Flutter web, add the app's origin to the Data API's allowed origins.
2. `cp dart_defines.example.json dart_defines.json` and fill in the Project URL and publishable key from the database's **Connect** tab.
3. `flutter create --platforms=android,ios,web,macos .` once, to add the platform folders.
4. `flutter run --dart-define-from-file=dart_defines.json`

The code is in [`lib/main.dart`](lib/main.dart).
