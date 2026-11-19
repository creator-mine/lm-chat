import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lm_chat/app_state.dart';
import 'package:lm_chat/import_options.dart';
import 'package:lm_chat/models.dart';

ImportPreview _preview({bool archived = false}) => ImportPreview(
  servers: [
    ServerConfig(id: 'server', name: 'PC', baseUrl: 'http://192.168.1.5:1234'),
  ],
  templates: const [PromptTemplate(id: 't1', name: 'Шаблон', content: 'x')],
  chats: [
    ChatSession(
      id: 'incoming',
      title: 'Импорт',
      serverId: 'server',
      model: 'model',
      archived: archived,
      messages: [ChatMessage(id: 'u1', role: 'user', content: 'привет')],
    ),
  ],
);

Future<AppState> _state() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final dir = await Directory.systemTemp.createTemp('lm_chat_import_');
  addTearDown(() => dir.delete(recursive: true));
  final state = AppState();
  addTearDown(state.dispose);
  state.dataFileOverride = () async =>
      File('${dir.path}${Platform.pathSeparator}lm_chat_data.json');
  return state;
}

void main() {
  test('servers and templates can be left out', () async {
    final state = await _state();

    final result = state.importPreview(
      _preview(),
      options: const ImportOptions(
        includeServers: false,
        includeTemplates: false,
      ),
    );

    expect(result.ok, isTrue);
    expect(result.chats, 1);
    expect(result.servers, 0);
    expect(result.templates, 0);
    expect(state.data.servers, isEmpty);
    expect(state.data.promptTemplates, isEmpty);
    expect(state.data.chats, hasLength(1));
  });

  test('archived chats can be skipped', () async {
    final state = await _state();

    final result = state.importPreview(
      _preview(archived: true),
      options: const ImportOptions(includeArchived: false),
    );

    expect(result.ok, isFalse);
    expect(result.error, contains('Не выбран'));
    expect(state.data.chats, isEmpty);
  });

  test('existing chats can be skipped', () async {
    final state = await _state();

    final first = state.importPreview(_preview());
    expect(first.chats, 1);

    final second = state.importPreview(
      _preview(),
      options: const ImportOptions(skipExisting: true),
    );
    expect(second.ok, isFalse);
    expect(second.skipped, 1);
    expect(state.data.chats, hasLength(1));
  });

  test('existing chats can be imported as copies', () async {
    final state = await _state();

    state.importPreview(_preview());
    final second = state.importPreview(_preview());

    expect(second.ok, isTrue);
    expect(second.chats, 1);
    expect(state.data.chats, hasLength(2));
    expect(state.data.chats.first.id, isNot(state.data.chats.last.id));
  });
}
