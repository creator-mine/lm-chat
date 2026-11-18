import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lm_chat/l10n.dart';

void main() {
  tearDown(() => L10n.setLanguage('ru'));

  test('every Russian L10n literal has an English translation', () {
    L10n.setLanguage('en');
    final call = RegExp(
      r"L10n\.tf?\(\s*((?:'((?:[^'\\]|\\.)*)'\s*)+)",
      dotAll: true,
    );
    final literal = RegExp(r"'((?:[^'\\]|\\.)*)'");
    final cyrillic = RegExp('[А-Яа-яЁё]');
    final missing = <String>{};

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('l10n.dart')) continue;
      final source = entity.readAsStringSync();
      for (final match in call.allMatches(source)) {
        final text = literal
            .allMatches(match.group(1)!)
            .map((part) => part.group(1)!.replaceAll(r"\'", "'"))
            .join();
        if (!cyrillic.hasMatch(text)) continue;
        if (L10n.t(text) == text) missing.add(text);
      }
    }

    expect(missing, isEmpty, reason: 'Untranslated:\n${missing.join('\n')}');
  });
}
