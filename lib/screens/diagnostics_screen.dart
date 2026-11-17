import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_log.dart';
import '../app_state.dart';
import '../app_version.dart';
import '../l10n_text.dart';
import '../models.dart';
import '../plugin_client.dart';
import '../relay_client.dart';
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
                  if (server != null && server.hasRelay) ...[
                    const _RelayCard(),
                    const SizedBox(height: 12),
                  ],
                  const _ProbeCard(),
                  const SizedBox(height: 12),
                  const _PluginLogCard(),
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

class _RelayCard extends StatefulWidget {
  const _RelayCard();

  @override
  State<_RelayCard> createState() => _RelayCardState();
}

class _RelayCardState extends State<_RelayCard> {
  RelayStatus? _status;
  String? _error;
  String? _serverId;
  bool _loading = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final server = context.read<AppState>().activeServer;
    if (_configured(server)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_refresh(server!));
      });
    }
  }

  bool _configured(ServerConfig? server) =>
      server != null &&
      server.hasRelay &&
      server.effectiveRelayToken.isNotEmpty;

  Future<void> _refresh(ServerConfig server) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final status = await RelayClient(server).status();
      if (!mounted) return;
      setState(() {
        _status = status;
        _serverId = server.id;
      });
    } on RelayException catch (error) {
      if (mounted) {
        setState(() {
          _status = null;
          _error = error.message;
          _serverId = server.id;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _status = null;
          _error = '$error';
          _serverId = server.id;
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final server = context.select<AppState, ServerConfig?>(
      (state) => state.activeServer,
    );
    final scheme = Theme.of(context).colorScheme;
    final configured = _configured(server);
    final status = _serverId == server?.id ? _status : null;
    final error = _serverId == server?.id ? _error : null;
    final online = status?.online == true;
    final statusColor = status == null
        ? scheme.onSurfaceVariant
        : (online ? scheme.primary : scheme.error);

    if (configured && _serverId != server!.id && !_loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_loading) unawaited(_refresh(server));
      });
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.cloud_outlined, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  'Relay',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (server != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      server.name,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                const Spacer(),
                if (configured)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      status == null
                          ? L10n.t('нет данных')
                          : (online ? L10n.t('онлайн') : L10n.t('офлайн')),
                      style: TextStyle(fontSize: 11, color: statusColor),
                    ),
                  ),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else if (configured)
                  IconButton(
                    onPressed: () => _refresh(server!),
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    tooltip: L10n.t('Обновить'),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (!configured)
              Text(
                L10n.t(
                  'Relay не настроен. Укажите адрес, ID устройства и токен.',
                ),
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              )
            else ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      server!.relayBase,
                      style: TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontSize: 11.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Text(
                    server.hasRelayE2e ? L10n.t('E2E включено') : 'TLS',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                status == null
                    ? L10n.t('Нет данных от relay.')
                    : online
                    ? L10n.tf(
                        'Агент подключён · потоков: {count} · relay {version}',
                        {
                          'count': status.streams,
                          'version': status.version.isEmpty
                              ? '?'
                              : status.version,
                        },
                      )
                    : L10n.tf('Агент не подключён · relay {version}', {
                        'version': status.version.isEmpty
                            ? '?'
                            : status.version,
                      }),
                style: TextStyle(
                  fontSize: 12,
                  color: status == null ? scheme.onSurfaceVariant : statusColor,
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    error,
                    style: TextStyle(fontSize: 12, color: scheme.error),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PluginLogCard extends StatefulWidget {
  const _PluginLogCard();

  @override
  State<_PluginLogCard> createState() => _PluginLogCardState();
}

class _PluginLogCardState extends State<_PluginLogCard> {
  PluginStatus? _status;
  PluginLogPage? _page;
  String? _error;
  bool _loading = false;
  bool _started = false;
  String? _busyLevel;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final server = context.read<AppState>().activeServer;
    if (_configured(server)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_refresh(server!));
      });
    }
  }

  bool _configured(ServerConfig? server) =>
      server != null &&
      server.hasPlugin &&
      server.pluginToken.trim().isNotEmpty;

  Future<void> _refresh(ServerConfig server) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = PluginClient(server);
      final status = await client.status();
      final page = await client.logs();
      if (!mounted) return;
      setState(() {
        _status = status;
        _page = page;
      });
    } on PluginException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _setLevel(ServerConfig server, String level) async {
    setState(() {
      _busyLevel = level;
      _error = null;
    });
    try {
      await PluginClient(server).setLogLevel(level);
      await _refresh(server);
    } on PluginException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busyLevel = null);
    }
  }

  Future<void> _clear(ServerConfig server) async {
    setState(() => _error = null);
    try {
      await PluginClient(server).clearLogs();
      await _refresh(server);
    } on PluginException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _save() async {
    final page = _page;
    if (page == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final saved = await ToolFileSaver.save(
        fileName: 'lm-computer-logs-${_fileStamp()}.jsonl',
        content: page.toJsonl(),
      );
      if (!mounted || !saved) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(L10n.t('Дамп сохранён'))));
    } catch (error) {
      if (!mounted) return;
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

  String _fileStamp() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final server = context.select<AppState, ServerConfig?>(
      (state) => state.activeServer,
    );
    final scheme = Theme.of(context).colorScheme;
    final page = _page;
    final entries = page?.entries.take(50).toList() ?? const <PluginLogEntry>[];
    final level = _busyLevel ?? _status?.logLevel ?? page?.level ?? 'info';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.dns_outlined, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  L10n.t('Логи плагина'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (server != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      server.name,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (!_configured(server))
              Text(
                L10n.t('Укажите адрес и токен плагина в настройках сервера.'),
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              )
            else ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _status == null
                          ? L10n.t('lm-computer: нет данных')
                          : L10n.tf(
                              'lm-computer {version} · лог: {level} · записей: {count}',
                              {
                                'version': _status!.version.isEmpty
                                    ? '?'
                                    : _status!.version,
                                'level': level,
                                'count': _status!.logEntries,
                              },
                            ),
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (_loading)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    IconButton(
                      onPressed: () => _refresh(server!),
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      tooltip: L10n.t('Обновить'),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  DropdownButton<String>(
                    value: const ['off', 'info', 'debug'].contains(level)
                        ? level
                        : 'info',
                    items: const [
                      DropdownMenuItem(value: 'off', child: Text('off')),
                      DropdownMenuItem(value: 'info', child: Text('info')),
                      DropdownMenuItem(value: 'debug', child: Text('debug')),
                    ],
                    onChanged: _busyLevel == null
                        ? (value) {
                            if (value != null) _setLevel(server!, value);
                          }
                        : null,
                  ),
                  TextButton.icon(
                    onPressed: page == null || (_page!.entries.isEmpty)
                        ? null
                        : _save,
                    icon: const Icon(Icons.save_alt_rounded, size: 18),
                    label: Text(L10n.t('Сохранить дамп…')),
                  ),
                  TextButton.icon(
                    onPressed: () => _clear(server!),
                    icon: const Icon(Icons.delete_outline_rounded, size: 18),
                    label: Text(L10n.t('Очистить')),
                  ),
                ],
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _error!,
                    style: TextStyle(fontSize: 12, color: scheme.error),
                  ),
                ),
              if (page != null && entries.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    L10n.t(
                      'Пока нет записей. Включите debug и повторите запрос.',
                    ),
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              if (entries.isNotEmpty) ...[
                const SizedBox(height: 8),
                ...entries.map((entry) => _PluginLogLine(entry: entry)),
                const SizedBox(height: 4),
                Text(
                  L10n.t('Показаны последние 50 записей.'),
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _PluginLogLine extends StatelessWidget {
  const _PluginLogLine({required this.entry});

  final PluginLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (entry.level) {
      'error' => scheme.error,
      'warn' => AppColors.of(context).warning,
      'debug' => scheme.onSurfaceVariant,
      _ => scheme.onSurface,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(
        '${_pluginTime(entry.time)}  ${entry.level.padRight(5)}  '
        '${entry.event}  ${entry.summary}',
        style: TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: 11,
          height: 1.35,
          color: color,
        ),
      ),
    );
  }
}

String _pluginTime(DateTime? time) {
  if (time == null) return '--:--:--.---';
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}.'
      '${time.millisecond.toString().padLeft(3, '0')}';
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
