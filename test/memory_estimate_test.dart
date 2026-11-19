import 'package:flutter_test/flutter_test.dart';
import 'package:lm_chat/format_utils.dart';
import 'package:lm_chat/l10n.dart';

const _estimate = '''
Model: gemma4-12b-qat-uncensored-hauhaucs-balanced
Estimated GPU Memory:   7.04 GiB
Estimated Total Memory: 7.04 GiB
Confidence: LOW

Estimate: This model may be loaded based on your resource guardrails settings.
''';

void main() {
  tearDown(() => L10n.setLanguage('ru'));

  test('memory estimate labels are translated to Russian', () {
    final text = localizeLmsEstimate(_estimate);

    expect(text, contains('Модель:'));
    expect(text, contains('Ожидаемая память GPU:'));
    expect(text, contains('Ожидаемая общая память:'));
    expect(text, contains('Уверенность: низкая'));
    expect(
      text,
      contains(
        'Оценка: модель может быть загружена с учётом настроек '
        'ограничений ресурсов.',
      ),
    );
    expect(text, isNot(contains('Confidence')));
    expect(text, isNot(contains('Estimated')));
    expect(text, isNot(contains('Estimate:')));
  });

  test('memory estimate is left untouched in English', () {
    L10n.setLanguage('en');
    expect(localizeLmsEstimate(_estimate), _estimate);
  });
}
