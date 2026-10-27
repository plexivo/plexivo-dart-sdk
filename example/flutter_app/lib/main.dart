// A Flutter app on Plexivo Postgres: sign in, a todo list that stays in
// sync across devices, and a realtime chat. Only the publishable key is in
// the app; row-level security (example/schema.sql) decides what each user
// can read and write.
//
//   cp dart_defines.example.json dart_defines.json   # fill in from the Connect tab
//   flutter create --platforms=android,ios,web,macos .   # once, to add platform folders
//   flutter run --dart-define-from-file=dart_defines.json
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:plexivo_client/plexivo_client.dart';

const _url = String.fromEnvironment('PLEXIVO_URL');
const _key = String.fromEnvironment('PLEXIVO_PUBLISHABLE_KEY');

/// One client for the whole app.
///
/// To keep users signed in across launches, save each session from
/// `authStateChanges` in encrypted storage (for example flutter_secure_storage)
/// and pass it back as `initialSession`.
final plexivo = PlexivoClient(_url, _key);

void main() {
  runApp(const PlexivoExampleApp());
}

/// The app: the sign-in screen, or the signed-in home.
class PlexivoExampleApp extends StatelessWidget {
  /// Creates the app.
  const PlexivoExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Plexivo Postgres',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: Colors.indigo, brightness: Brightness.dark, useMaterial3: true),
      home: _url.isEmpty || _key.isEmpty
          ? const _MissingConfig()
          : StreamBuilder<PlexivoAuthState>(
              stream: plexivo.authStateChanges,
              builder: (context, _) => plexivo.session == null ? const SignInScreen() : const HomeScreen(),
            ),
    );
  }
}

class _MissingConfig extends StatelessWidget {
  const _MissingConfig();

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('Run with --dart-define-from-file=dart_defines.json\n(your project URL and publishable key).', textAlign: TextAlign.center),
          ),
        ),
      );
}

/// Shows a [PlexivoException]'s message (or any error) in a snack bar.
void showError(BuildContext context, Object error) {
  final text = error is PlexivoException ? '${error.message} (${error.code})' : '$error';
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

// ── sign in ──────────────────────────────────────────────────────────────

/// Email and password sign-in and sign-up.
class SignInScreen extends StatefulWidget {
  /// Creates the sign-in screen.
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  var _busy = false;

  Future<void> _submit({required bool create}) async {
    setState(() => _busy = true);
    try {
      if (create) {
        await plexivo.signUp(email: _email.text.trim(), password: _password.text);
      } else {
        await plexivo.signInWithPassword(email: _email.text.trim(), password: _password.text);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: _email, decoration: const InputDecoration(labelText: 'Email'), keyboardType: TextInputType.emailAddress),
              TextField(controller: _password, decoration: const InputDecoration(labelText: 'Password (10+ characters)'), obscureText: true),
              const SizedBox(height: 24),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(onPressed: _busy ? null : () => _submit(create: true), child: const Text('Create account')),
                const SizedBox(width: 8),
                FilledButton(onPressed: _busy ? null : () => _submit(create: false), child: const Text('Sign in')),
              ]),
            ]),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }
}

// ── home ─────────────────────────────────────────────────────────────────

/// Todos and chat, in two tabs.
class HomeScreen extends StatelessWidget {
  /// Creates the home screen.
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(plexivo.session?['user']?['email']?.toString() ?? ''),
          actions: [IconButton(icon: const Icon(Icons.logout), tooltip: 'Sign out', onPressed: () => plexivo.signOut())],
          bottom: const TabBar(tabs: [Tab(text: 'Todos'), Tab(text: 'Chat')]),
        ),
        body: const TabBarView(children: [TodosTab(), ChatTab()]),
      ),
    );
  }
}

// ── todos ────────────────────────────────────────────────────────────────

/// The signed-in user's todos: create, complete, delete, kept in sync by
/// realtime row changes.
class TodosTab extends StatefulWidget {
  /// Creates the todos tab.
  const TodosTab({super.key});

  @override
  State<TodosTab> createState() => _TodosTabState();
}

class _TodosTabState extends State<TodosTab> {
  final _title = TextEditingController();
  List<Map<String, dynamic>> _todos = const [];
  late final PlexivoRealtimeChannel _feed;
  StreamSubscription<PlexivoChange>? _changes;

  @override
  void initState() {
    super.initState();
    _load();
    // Another device changed a todo: reload. Each user receives only the
    // rows row-level security lets them read.
    _feed = plexivo.channel('changes:todos')..subscribe();
    _changes = _feed.changes.listen((_) => _load());
  }

  Future<void> _load() async {
    try {
      final rows = await plexivo.from('todos').order('done').order('created_at', 'desc').limit(100);
      if (mounted) setState(() => _todos = rows);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _run(Future<Object?> Function() action) async {
    try {
      await action();
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(
          controller: _title,
          decoration: const InputDecoration(hintText: 'What needs doing?', prefixIcon: Icon(Icons.add)),
          onSubmitted: (title) => _run(() async {
            if (title.trim().isEmpty) return null;
            await plexivo.from('todos').create({'title': title.trim()});
            _title.clear();
            return null;
          }),
        ),
      ),
      Expanded(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(children: [
            for (final todo in _todos)
              Dismissible(
                key: ValueKey(todo['id']),
                onDismissed: (_) => _run(() => plexivo.from('todos').where('id', todo['id']).delete()),
                child: CheckboxListTile(
                  title: Text(todo['title'] as String),
                  value: todo['done'] as bool,
                  onChanged: (done) => _run(() => plexivo.from('todos').where('id', todo['id']).update({'done': done})),
                ),
              ),
          ]),
        ),
      ),
    ]);
  }

  @override
  void dispose() {
    _changes?.cancel();
    _feed.unsubscribe();
    _title.dispose();
    super.dispose();
  }
}

// ── chat ─────────────────────────────────────────────────────────────────

/// A chat room for everyone signed in: messages as realtime row changes,
/// and a typing indicator over a room broadcast (nothing stored).
class ChatTab extends StatefulWidget {
  /// Creates the chat tab.
  const ChatTab({super.key});

  @override
  State<ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends State<ChatTab> {
  final _body = TextEditingController();
  final _messages = <Map<String, dynamic>>[];
  late final PlexivoRealtimeChannel _feed;
  late final PlexivoRealtimeChannel _room;
  final _subscriptions = <StreamSubscription<Object?>>[];
  String? _typing;
  Timer? _typingTimer;

  @override
  void initState() {
    super.initState();
    _loadRecent();
    _feed = plexivo.channel('changes:messages', 'room=eq.lobby')..subscribe();
    _subscriptions.add(_feed.changes.listen((change) {
      if (change.type == 'insert' && change.record != null) setState(() => _messages.add(change.record!));
    }));
    _room = plexivo.channel('room:lobby')..subscribe();
    _subscriptions.add(_room.on('typing').listen((payload) {
      setState(() => _typing = '${payload['email']} is typing…');
      _typingTimer?.cancel();
      _typingTimer = Timer(const Duration(milliseconds: 1500), () => setState(() => _typing = null));
    }));
  }

  Future<void> _loadRecent() async {
    final recent = await plexivo.from('messages').where('room', 'lobby').order('id', 'desc').limit(30);
    if (mounted) setState(() => _messages.insertAll(0, recent.reversed));
  }

  Future<void> _send(String body) async {
    if (body.trim().isEmpty) return;
    try {
      await plexivo.from('messages').create({'body': body.trim()});
      _body.clear();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Expanded(
        child: ListView(padding: const EdgeInsets.all(12), children: [
          for (final m in _messages) ListTile(dense: true, title: Text(m['body'] as String)),
        ]),
      ),
      if (_typing != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(_typing!, style: Theme.of(context).textTheme.bodySmall)),
      Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(
          controller: _body,
          decoration: const InputDecoration(hintText: 'Say hello', suffixIcon: Icon(Icons.send)),
          onChanged: (_) {
            try {
              _room.sendBroadcast('typing', {'email': plexivo.session?['user']?['email']});
            } on StateError {
              // Not connected yet: a missed typing hint is harmless.
            }
          },
          onSubmitted: _send,
        ),
      ),
    ]);
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    _typingTimer?.cancel();
    _feed.unsubscribe();
    _room.unsubscribe();
    _body.dispose();
    super.dispose();
  }
}
