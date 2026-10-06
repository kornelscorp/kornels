import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

void main() => runApp(const NuestraIaApp());

// ───────────────────────── App ─────────────────────────

class NuestraIaApp extends StatelessWidget {
  const NuestraIaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nuestra IA',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const ChatScreen(),
    );
  }
}

// ───────────────────── Historial (SQLite) ─────────────────────

class Msg {
  final int? id;
  final String role; // 'user' | 'assistant'
  final String content;
  final String mode; // 'online' | 'offline' | ''
  final DateTime createdAt;

  Msg({
    this.id,
    required this.role,
    required this.content,
    this.mode = '',
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();
}

class AppDb {
  AppDb._();
  static final AppDb instance = AppDb._();
  Database? _db;

  Future<Database> get db async {
    if (_db != null) return _db!;
    final path = p.join(await getDatabasesPath(), 'nuestra_ia.db');
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (d, v) async {
        await d.execute(
          'CREATE TABLE messages ('
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
          'role TEXT NOT NULL, '
          'content TEXT NOT NULL, '
          'mode TEXT NOT NULL, '
          'created_at INTEGER NOT NULL)',
        );
      },
    );
    return _db!;
  }

  Future<void> insert(Msg m) async {
    final d = await db;
    await d.insert('messages', {
      'role': m.role,
      'content': m.content,
      'mode': m.mode,
      'created_at': m.createdAt.millisecondsSinceEpoch,
    });
  }

  Msg _fromRow(Map<String, Object?> r) => Msg(
        id: r['id'] as int,
        role: r['role'] as String,
        content: r['content'] as String,
        mode: r['mode'] as String,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
      );

  Future<List<Msg>> all() async {
    final d = await db;
    final rows = await d.query('messages', orderBy: 'id ASC');
    return rows.map(_fromRow).toList();
  }

  Future<List<Msg>> recent(int n) async {
    final d = await db;
    final rows = await d.query('messages', orderBy: 'id DESC', limit: n);
    return rows.reversed.map(_fromRow).toList();
  }

  Future<void> clear() async {
    final d = await db;
    await d.delete('messages');
  }
}

// ───────────────────── Configuración ─────────────────────

enum AiMode { auto, online, offline }

class AppSettings {
  static Future<AiMode> getMode() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString('mode') ?? 'auto';
    return AiMode.values.firstWhere(
      (m) => m.name == v,
      orElse: () => AiMode.auto,
    );
  }

  static Future<void> setMode(AiMode m) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('mode', m.name);
  }

  static Future<String> getApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('api_key') ?? '';
  }

  static Future<void> setApiKey(String k) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_key', k.trim());
  }
}

// ───────────────────── Cerebro (online / offline) ─────────────────────

class AiReply {
  final String text;
  final String mode; // 'online' | 'offline'
  AiReply(this.text, this.mode);
}

class AiService {
  static const _model = 'claude-haiku-4-5-20251001';
  static const _system =
      'Eres un asistente general amable. Responde en español, de forma clara y breve.';

  static Future<bool> hasInternet() async {
    final r = await Connectivity().checkConnectivity();
    return r.any((x) => x != ConnectivityResult.none);
  }

  static Future<AiReply> reply(List<Msg> history) async {
    final mode = await AppSettings.getMode();
    final key = await AppSettings.getApiKey();

    var online = false;
    if (mode == AiMode.online) {
      online = true;
    } else if (mode == AiMode.auto) {
      online = await hasInternet();
    }

    if (online && key.isEmpty) {
      return AiReply(
        'Falta la clave de API. Ve a Configuración (⚙️) y pégala para usar el modo online.',
        'offline',
      );
    }

    if (online) {
      try {
        return AiReply(await _askCloud(history, key), 'online');
      } catch (e) {
        return AiReply(
          'No pude conectar con la nube ($e). Respondo en modo offline.\n\n${_offline(history)}',
          'offline',
        );
      }
    }
    return AiReply(_offline(history), 'offline');
  }

  static Future<String> _askCloud(List<Msg> history, String key) async {
    final msgs = history
        .map((m) => {'role': m.role, 'content': m.content})
        .toList();
    // La API exige que el primer mensaje sea del usuario.
    while (msgs.isNotEmpty && msgs.first['role'] != 'user') {
      msgs.removeAt(0);
    }

    final res = await http
        .post(
          Uri.parse('https://api.anthropic.com/v1/messages'),
          headers: {
            'content-type': 'application/json',
            'x-api-key': key,
            'anthropic-version': '2023-06-01',
          },
          body: jsonEncode({
            'model': _model,
            'max_tokens': 1024,
            'system': _system,
            'messages': msgs,
          }),
        )
        .timeout(const Duration(seconds: 45));

    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    final text = (data['content'] as List)
        .where((c) => c['type'] == 'text')
        .map((c) => c['text'] as String)
        .join('\n');
    return text.isEmpty ? '(respuesta vacía)' : text;
  }

  static String _offline(List<Msg> history) {
    return 'Estoy en modo offline. El modelo local se instalará en una etapa próxima; '
        'por ahora guardé tu mensaje en el historial y lo podré contestar cuando haya internet o cuando el modelo local esté listo.';
  }
}

// ───────────────────── Pantalla de chat ─────────────────────

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  List<Msg> _msgs = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final m = await AppDb.instance.all();
    if (!mounted) return;
    setState(() => _msgs = m);
    _toBottom();
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _busy) return;
    _ctrl.clear();
    setState(() => _busy = true);

    await AppDb.instance.insert(Msg(role: 'user', content: text));
    await _load();

    final history = await AppDb.instance.recent(20);
    final r = await AiService.reply(history);
    await AppDb.instance.insert(
      Msg(role: 'assistant', content: r.text, mode: r.mode),
    );
    await _load();

    if (mounted) setState(() => _busy = false);
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Borrar historial'),
        content: const Text('Se borrarán todos los mensajes. ¿Continuar?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Borrar'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await AppDb.instance.clear();
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nuestra IA'),
        actions: [
          IconButton(
            tooltip: 'Borrar historial',
            icon: const Icon(Icons.delete_outline),
            onPressed: _confirmClear,
          ),
          IconButton(
            tooltip: 'Configuración',
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _msgs.isEmpty
                ? const Center(child: Text('Escribe algo para empezar 👋'))
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: _msgs.length,
                    itemBuilder: (c, i) => _Bubble(msg: _msgs[i]),
                  ),
          ),
          if (_busy) const LinearProgressIndicator(),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(
                        hintText: 'Escribe tu mensaje',
                        filled: true,
                        fillColor: cs.surfaceContainerHighest,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton.filled(
                    onPressed: _busy ? null : _send,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final Msg msg;
  const _Bubble({required this.msg});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isUser = msg.role == 'user';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.82,
        ),
        decoration: BoxDecoration(
          color: isUser ? cs.primaryContainer : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(msg.content),
            if (!isUser && msg.mode.isNotEmpty) ...[
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    msg.mode == 'online' ? Icons.cloud : Icons.cloud_off,
                    size: 12,
                    color: cs.outline,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    msg.mode == 'online' ? 'online' : 'offline',
                    style: TextStyle(fontSize: 11, color: cs.outline),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ───────────────────── Pantalla de configuración ─────────────────────

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  AiMode _mode = AiMode.auto;
  final _key = TextEditingController();

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final m = await AppSettings.getMode();
    final k = await AppSettings.getApiKey();
    if (!mounted) return;
    setState(() {
      _mode = m;
      _key.text = k;
    });
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await AppSettings.setMode(_mode);
    await AppSettings.setApiKey(_key.text);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Configuración guardada')),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Configuración')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Modo', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          SegmentedButton<AiMode>(
            segments: const [
              ButtonSegment(value: AiMode.auto, label: Text('Auto')),
              ButtonSegment(value: AiMode.online, label: Text('Online')),
              ButtonSegment(value: AiMode.offline, label: Text('Offline')),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => setState(() => _mode = s.first),
          ),
          const SizedBox(height: 8),
          const Text(
            'Auto: usa internet si hay conexión y, si no, funciona offline.',
          ),
          const SizedBox(height: 24),
          const Text(
            'Clave de API (Anthropic)',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _key,
            obscureText: true,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'sk-ant-...',
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Se guarda solo en tu celular y se usa para el modo online.',
          ),
          const SizedBox(height: 24),
          FilledButton(onPressed: _save, child: const Text('Guardar')),
        ],
      ),
    );
  }
}
