import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_log.dart';
import '../app_state.dart';
import '../app_version.dart';
import '../l10n_text.dart';
import '../stream_probe.dart';
import '../theme.dart';
import '../tool_file_saver.dart';

/// Shows the in-memory app log and the current server/model state.
///
/// Useful when a user reports "the answer hangs" or "the bridge does not
/// load": the screen contains no prompts, API keys or bridge tokens.
class DiagnosticsScreen extends StatelessWidget {
  const DiagnosticsScreen({super.key});

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: AppLog.instance.asText()));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Лог скопирован')));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final server = state.activeServer;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Диагностика'),
        actions: [
          IconButton(
            onPressed: () => _copy(context),
            icon: const Icon(Icons.copy_rounded),
            tooltip: L10n.t('Скопировать лог'),
          ),
          IconButton(
            onPressed: AppLog.instance.clear,
            icon: const Icon(Icons.delete_sweep_rounded),
            tooltip: L10n.t('Очистить лог'),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListenableBuilder(
            listenable: Listenable.merge([
              AppLog.instance,
              StreamProbe.instance,
            ]),
            builder: (context, _) {
              final entries = AppLog.instance.entries.reversed.toList();
              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _InfoRow(
                            label: 'Сервер',
                            value: server == null
                                ? 'не выбран'
                                : '${server.name} · ${server.normalizedBase}',
                          ),
                          if (server != null && server.hasBridge)
                            _InfoRow(
                              label: 'Мостик',
                              value: server.normalizedBridge,
                            ),
                          _InfoRow(
                            label: 'Моделей в кэше',
                            value: server == null
                                ? '0'
                                : '${state.modelsFor(server.id).length}',
                          ),
                          _InfoRow(
                            label: 'Версия',
                            value: 'LM Chat $appVersionLabel',
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Лог хранится только в памяти и очищается при '
                            'закрытии приложения.',
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const _ProbeCard(),
                  const SizedBox(height: 12),
                  if (entries.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 32),
                      child: Column(
                        children: [
                          Icon(
                            Icons.check_circle_outline_rounded,
                            size: 36,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Пока нет записей',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    )
                  else
                    ...entries.map((entry) => _LogTile(entry: entry)),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ProbeCard extends StatelessWidget {
  const _ProbeCard();

  Future<void> _save(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final saved = await ToolFileSaver.save(
        fileName: StreamProbe.instance.suggestedFileName,
        content: StreamProbe.instance.toJsonl(),
      );
      if (!context.mounted || !saved) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(L10n.t('Дамп сохранён'))));
    } catch (error) {
      if (!context.mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              L10n.tf('Не удалось сохранить дамп: {error}', {'error': error}),
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final probe = StreamProbe.instance;
    final scheme = Theme.of(context).colorScheme;
    final counts = probe.typeCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.monitor_heart_outlined,
                  size: 18,
                  color: scheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  L10n.t('Запись потока'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              L10n.t(
                'Пишутся только типы событий, время и размеры. '
                'Промпты, пути и содержимое файлов не сохраняются.',
              ),
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(
                L10n.t('Записывать поток событий'),
                style: const TextStyle(fontSize: 13),
              ),
              value: probe.enabled,
              onChanged: (value) => probe.enabled = value,
            ),
            if (probe.hasCapture) ...[
              const Divider(height: 16),
              _InfoRow(label: 'События', value: '${probe.sseCount}'),
              _InfoRow(
                label: 'Длительность',
                value: _probeDuration(probe.durationMs),
              ),
              _InfoRow(
                label: 'Максимальная пауза',
                value: '${(probe.maxGapMs / 1000).toStringAsFixed(1)} с',
                labelWidth: 140,
              ),
              _InfoRow(
                label: 'Принято',
                value: '${(probe.totalBytes / 1024).toStringAsFixed(1)} КБ',
              ),
              if (probe.stream.isNotEmpty)
                _InfoRow(
                  label: 'Поток',
                  value: probe.stream == 'mcp' && probe.integrationId.isNotEmpty
                      ? 'MCP · ${probe.integrationId}'
                      : probe.stream,
                ),
              if (probe.truncated)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    L10n.t('Запись остановлена лимитом'),
                    style: TextStyle(fontSize: 12, color: scheme.error),
                  ),
                ),
              if (counts.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  L10n.t('События по типам'),
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                ...counts
                    .take(10)
                    .map(
                      (entry) => Text(
                        '${entry.key} × ${entry.value}',
                        style: const TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: 11.5,
                        ),
                      ),
                    ),
              ],
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: () => _save(context),
                    icon: const Icon(Icons.save_alt_rounded, size: 18),
                    label: Text(L10n.t('Сохранить дамп…')),
                  ),
                  TextButton.icon(
                    onPressed: probe.clear,
                    icon: const Icon(Icons.delete_outline_rounded, size: 18),
                    label: Text(L10n.t('Очистить запись')),
                  ),
                ],
              ),
            ] else
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  probe.enabled
                      ? L10n.t('Следующий запрос к модели будет записан.')
                      : L10n.t('Пока нет записи.'),
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _probeDuration(int milliseconds) {
  final total = milliseconds ~/ 1000;
  final minutes = total ~/ 60;
  final seconds = total % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    this.labelWidth = 112,
  });

  final String label;
  final String value;
  final double labelWidth;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: labelWidth,
            child: Text(
              label,
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _LogTile extends StatelessWidget {
  const _LogTile({required this.entry});

  final LogEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (entry.level) {
      LogLevel.info => (Icons.info_outline_rounded, scheme.primary),
      LogLevel.warning => (
        Icons.warning_amber_rounded,
        AppColors.of(context).warning,
      ),
      LogLevel.error => (Icons.error_outline_rounded, scheme.error),
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 17, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        entry.formattedTime,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          entry.message,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (entry.detail != null && entry.detail!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: SelectableText(
                        entry.detail!,
                        style: TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: 11.5,
                          height: 1.45,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
