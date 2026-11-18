import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lm_chat/api.dart';
import 'package:lm_chat/app_state.dart';
import 'package:lm_chat/models.dart';
import 'package:lm_chat/secret_store.dart';
import 'package:lm_chat/widgets/model_picker.dart';
import 'package:provider/provider.dart';

class _FakeClient extends LmClient {
  @override
  Future<List<LmModelInfo>> fetchModelsInfo(
    ServerConfig server,
  ) async => const [
    LmModelInfo(key: 'model-a', displayName: 'Model A', maxContextLength: 8192),
    LmModelInfo(key: 'model-b', displayName: 'Model B', maxContextLength: 4096),
  ];
}

void main() {
  testWidgets('the model picker lists and selects models', (tester) async {
    final state = AppState(
      client: _FakeClient(),
      secretStore: MemorySecretStore(),
    );
    addTearDown(state.dispose);
    final server = ServerConfig(
      id: 'server',
      name: 'PC',
      baseUrl: 'http://192.168.1.5:1234',
    );
    final chat = ChatSession(id: 'chat', serverId: server.id, model: 'model-a');
    state.data.servers.add(server);
    state.data.chats.add(chat);
    state.activeChat = chat;

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showModelPicker(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Model A'), findsOneWidget);
    expect(find.text('Model B'), findsOneWidget);

    await tester.tap(find.text('Model B'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 700));

    expect(chat.model, 'model-b');
  });
}
