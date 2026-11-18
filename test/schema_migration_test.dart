import 'package:flutter_test/flutter_test.dart';
import 'package:lm_chat/models.dart';

void main() {
  test('older history is stamped with the current schema version', () {
    final migrated = AppData.migrate({
      'schemaVersion': 1,
      'servers': <Object>[],
      'chats': <Object>[],
    });

    expect(migrated['schemaVersion'], AppData.currentSchemaVersion);
    expect(migrated['servers'], isEmpty);
  });

  test('history from a newer app version is not rewritten', () {
    expect(
      () =>
          AppData.migrate({'schemaVersion': AppData.currentSchemaVersion + 1}),
      throwsA(isA<SchemaTooNewException>()),
    );
  });

  test('a history without a version is treated as the first schema', () {
    final migrated = AppData.migrate({'chats': <Object>[]});

    expect(migrated['schemaVersion'], AppData.currentSchemaVersion);
  });
}
