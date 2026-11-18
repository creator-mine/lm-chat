import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n_text.dart';
import '../models.dart';
import '../server_share.dart';
import 'model_picker.dart';

Future<void> showServerShareSheet(
  BuildContext context, {
  required List<ServerConfig> servers,
  required bool all,
}) {
  if (servers.isEmpty) return Future<void>.value();
  return showDialog<void>(
    context: context,
    builder: (_) => _ServerShareSheet(servers: servers, all: all),
  );
}

class _ServerShareSheet extends StatefulWidget {
  const _ServerShareSheet({required this.servers, required this.all});

  final List<ServerConfig> servers;
  final bool all;

  @override
  State<_ServerShareSheet> createState() => _ServerShareSheetState();
}

class _ServerShareSheetState extends State<_ServerShareSheet> {
  late ServerShareMode _mode;
  bool _confirmed = false;
  String? _code;
  String? _error;
  int _tokens = 0;
  int _skipped = 0;

  bool get _canRelay => widget.servers.any((server) => server.hasRelay);
  bool get _canLan => widget.servers.any(
    (server) => ServerShareCodec.supports(server, ServerShareMode.withoutRelay),
  );

  @override
  void initState() {
    super.initState();
    _mode = _canLan ? ServerShareMode.withoutRelay : ServerShareMode.withRelay;
    _buildCode();
  }

  void _buildCode() {
    final eligible = widget.servers
        .where((server) => ServerShareCodec.supports(server, _mode))
        .toList();
    _skipped = widget.servers.length - eligible.length;
    _tokens = _mode == ServerShareMode.withRelay
        ? eligible.where((server) => server.relayToken.trim().isNotEmpty).length
        : 0;
    if (eligible.isEmpty) {
      _code = null;
      _error = L10n.t('Нет серверов для этого варианта');
      return;
    }
    try {
      _code = widget.all
          ? ServerShareCodec.encodeAll(widget.servers, _mode)
          : ServerShareCodec.encodeServer(eligible.first, _mode);
      _error = null;
    } on ServerShareException catch (error) {
      _code = null;
      _error = error.message;
    }
  }

  void _setMode(ServerShareMode mode) {
    if (mode == _mode) return;
    setState(() {
      _mode = mode;
      _confirmed = false;
      _buildCode();
    });
  }

  bool get _needsConfirmation =>
      _mode == ServerShareMode.withRelay && _tokens > 0;

  bool get _visible => _code != null && (!_needsConfirmation || _confirmed);

  Future<void> _copy() async {
    final code = _code;
    if (code == null || !_visible) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            _tokens > 0
                ? L10n.t('Код с токеном скопирован')
                : L10n.t('Код сервера скопирован'),
          ),
        ),
      );
  }

  Future<void> _share() async {
    final code = _code;
    if (code == null || !_visible) return;
    final warning = _tokens > 0
        ? '\n\n${L10n.t('Содержит токен доступа. Передавайте только доверенным.')}'
        : '';
    try {
      await SharePlus.instance.share(
        ShareParams(
          text: '$code$warning',
          subject: widget.all
              ? L10n.t('Серверы LM Chat')
              : L10n.t('Сервер LM Chat'),
        ),
      );
    } catch (_) {
      await _copy();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final code = _code;
    final showQr = code != null && _visible && ServerShareCodec.fitsQr(code);

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.ios_share_rounded, size: 20, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.all
                  ? L10n.t('Поделиться всеми')
                  : L10n.t('Поделиться сервером'),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.all
                    ? L10n.tf('Серверов: {count}', {
                        'count': widget.servers.length,
                      })
                    : '${widget.servers.first.name} · '
                          '${serverLabel(widget.servers.first)}',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              if (_canLan || _canRelay)
                SegmentedButton<ServerShareMode>(
                  segments: [
                    ButtonSegment(
                      value: ServerShareMode.withoutRelay,
                      label: Text(L10n.t('Без relay')),
                      icon: const Icon(Icons.lan_outlined, size: 16),
                      enabled: _canLan,
                    ),
                    ButtonSegment(
                      value: ServerShareMode.withRelay,
                      label: Text(L10n.t('С relay')),
                      icon: const Icon(Icons.cloud_outlined, size: 16),
                      enabled: _canRelay,
                    ),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (selection) => _setMode(selection.first),
                ),
              if (_skipped > 0) ...[
                const SizedBox(height: 6),
                Text(
                  L10n.tf('Пропущено серверов без этого транспорта: {count}', {
                    'count': _skipped,
                  }),
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (_mode == ServerShareMode.withRelay) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: (_tokens > 0 ? scheme.error : scheme.tertiary)
                        .withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        _tokens > 0
                            ? Icons.warning_amber_rounded
                            : Icons.info_outline_rounded,
                        size: 18,
                        color: _tokens > 0 ? scheme.error : scheme.tertiary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _tokens > 0
                              ? L10n.t(
                                  'Код содержит токен доступа. Любой, у кого '
                                  'он есть, получит доступ к вашему relay.',
                                )
                              : L10n.t(
                                  'Без токена relay — получателю нужно ввести '
                                  'его вручную.',
                                ),
                          style: TextStyle(
                            fontSize: 11.5,
                            color: _tokens > 0
                                ? scheme.error
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: TextStyle(fontSize: 12, color: scheme.error),
                ),
              ],
              if (code != null && _needsConfirmation && !_confirmed) ...[
                const SizedBox(height: 12),
                Text(
                  L10n.t(
                    'Перед показом QR подтвердите, что понимаете риск. '
                    'Передавайте код только доверенным устройствам.',
                  ),
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: () => setState(() => _confirmed = true),
                  icon: const Icon(Icons.visibility_rounded, size: 18),
                  label: Text(L10n.t('Я понимаю, показать QR')),
                ),
              ],
              if (_visible && code != null) ...[
                const SizedBox(height: 12),
                if (showQr)
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      color: Colors.white,
                      child: QrImageView(
                        data: code,
                        version: QrVersions.auto,
                        size: 220,
                        backgroundColor: Colors.white,
                        errorCorrectionLevel: QrErrorCorrectLevel.L,
                      ),
                    ),
                  )
                else
                  Text(
                    L10n.t('QR не помещается — используйте код или файл.'),
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 110),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      code,
                      style: const TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton.icon(
                      onPressed: _copy,
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      label: Text(L10n.t('Копировать')),
                    ),
                    FilledButton.icon(
                      onPressed: _share,
                      icon: const Icon(Icons.share_rounded, size: 18),
                      label: Text(L10n.t('Поделиться')),
                    ),
                  ],
                ),
              ],
              if (_needsConfirmation && !_confirmed && code != null) ...[
                const SizedBox(height: 8),
                Text(
                  'LMSRV1.${'•' * 24}',
                  style: const TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 11,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(L10n.t('Закрыть')),
        ),
      ],
    );
  }
}
