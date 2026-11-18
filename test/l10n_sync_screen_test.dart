import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lm_chat/l10n.dart';

void main() {
  tearDown(() => L10n.setLanguage('ru'));

  test('sync screen has English translations for its labels', () {
    L10n.setLanguage('en');
    final source = File('lib/screens/sync_screen.dart').readAsStringSync();
    final call = RegExp(
      r"Text\(\s*((?:'((?:[^'\\]|\\.)*)'\s*)+)",
      dotAll: true,
    );
    final literal = RegExp(r"'((?:[^'\\]|\\.)*)'");
    final cyrillic = RegExp('[А-Яа-яЁё]');
    final missing = <String>{};

    for (final match in call.allMatches(source)) {
      final text = literal
          .allMatches(match.group(1)!)
          .map((part) => part.group(1)!.replaceAll(r"\'", "'"))
          .join();
      if (!cyrillic.hasMatch(text)) continue;
      if (L10n.t(text) == text) missing.add(text);
    }

    expect(missing, isEmpty, reason: 'Untranslated:\n${missing.join('\n')}');
  });
}
