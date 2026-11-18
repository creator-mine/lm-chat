import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lm_chat/models.dart';
import 'package:lm_chat/widgets/version_sheet.dart';

void main() {
  testWidgets('version sheet lists saved answers and selects one', (
    tester,
  ) async {
    final message = ChatMessage(
      id: 'message',
      role: 'assistant',
      content: 'Новый ответ',
      model: 'model',
      versions: [
        ChatMessageVersion(id: 'old', content: 'Старый ответ', model: 'model'),
      ],
    );
    int? selected;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showVersionsSheet(
                context,
                message: message,
                onSelect: (number) => selected = number,
                onDelete: (_) {},
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Варианты ответа'), findsOneWidget);
    expect(find.text('Старый ответ'), findsOneWidget);
    expect(find.text('Новый ответ'), findsOneWidget);

    await tester.tap(find.text('Старый ответ'));
    await tester.pumpAndSettle();

    expect(selected, 1);
    expect(find.text('Варианты ответа'), findsNothing);
  });
}
