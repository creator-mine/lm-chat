import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../l10n_text.dart';
import '../server_share.dart';
import 'model_picker.dart';

Future<void> showServerImportDialog(
  BuildContext context, {
  String? initialCode,
}) async {
  final bundle = await showDialog<SharedServerBundle>(
    context: context,
    builder: (_) => _ImportCodeDialog(initialCode: initialCode),
  );
  if (bundle == null || !context.mounted) return;
  await _showPreview(context, bundle);
}

class _ImportCodeDialog extends StatefulWidget {
  const _ImportCodeDialog({this.initialCode});

  final String? initialCode;

  @override
  State<_ImportCodeDialog> createState() => _ImportCodeDialogState();
}

class _ImportCodeDialogState extends State<_ImportCodeDialog> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialCode ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData('text/plain');
    if (!mounted || data?.text == null) return;
    setState(() {
      _controller.text = data!.text!;
      _error = null;
    });
  }

  void _import() {
    try {
      final bundle = ServerShareCodec.decode(_controller.text);
      Navigator.pop(context, bundle);
    } on ServerShareException catch (error) {
      setState(() => _error = error.message);
    } catch (error) {
      setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Добавить сервер по коду'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Вставьте код или сообщение с кодом LMSRV1…',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _controller,
              maxLines: 6,
              minLines: 3,
              autofocus: widget.initialCode == null,
              style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11),
              decoration: const InputDecoration(
                hintText: 'LMSRV1.…',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(fontSize: 12, color: scheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: _paste,
          icon: const Icon(Icons.content_paste_rounded, size: 18),
          label: Text(L10n.t('Вставить')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(L10n.t('Отмена')),
        ),
        FilledButton(onPressed: _import, child: Text(L10n.t('Продолжить'))),
      ],
    );
  }
}

Future<void> _showPreview(
  BuildContext context,
  SharedServerBundle bundle,
) async {
  final accepted = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final scheme = Theme.of(dialogContext).colorScheme;
      return AlertDialog(
        title: Text(
          bundle.all ? L10n.t('Импорт серверов') : L10n.t('Импорт сервера'),
        ),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final server in bundle.servers)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      server.hasRelay
                          ? Icons.cloud_outlined
                          : Icons.lan_outlined,
                      size: 18,
                    ),
                    title: Text(server.name),
                    subtitle: Text(
                      serverLabel(server),
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                if (bundle.skipped > 0)
                  Text(
                    L10n.tf('Пропущено серверов: {count}', {
                      'count': bundle.skipped,
                    }),
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                if (bundle.includesToken) ...[
                  const SizedBox(height: 8),
                  Text(
                    L10n.t(
                      'Код содержит токен relay. Он будет сохранён в '
                      'защищённом хранилище этого устройства.',
                    ),
                    style: TextStyle(fontSize: 12, color: scheme.error),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(L10n.t('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(L10n.t('Импортировать')),
          ),
        ],
      );
    },
  );
  if (accepted != true || !context.mounted) return;

  final result = context.read<AppState>().importSharedServers(bundle);
  if (!context.mounted) return;
  final parts = <String>[];
  if (result.added > 0) {
    parts.add(L10n.tf('добавлено: {count}', {'count': result.added}));
  }
  if (result.updated > 0) {
    parts.add(L10n.tf('обновлено: {count}', {'count': result.updated}));
  }
  if (result.tokensImported > 0) {
    parts.add(L10n.tf('токенов: {count}', {'count': result.tokensImported}));
  }
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          parts.isEmpty
              ? L10n.t('Серверы не изменились')
              : '${L10n.t('Импорт завершён')} · ${parts.join(' · ')}',
        ),
      ),
    );
}
