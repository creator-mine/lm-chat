import 'package:flutter/material.dart' hide Text;
import 'package:provider/provider.dart';

import '../api.dart';
import '../app_state.dart';
import '../e2e.dart';
import '../format_utils.dart';
import '../l10n_text.dart';
import '../models.dart';
import '../plugin_client.dart';

class ServerEditDialog extends StatefulWidget {
  const ServerEditDialog({super.key, this.server});

  final ServerConfig? server;

  @override
  State<ServerEditDialog> createState() => _ServerEditDialogState();
}

class _ServerEditDialogState extends State<ServerEditDialog> {
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _key;
  late bool _chatViaBridge;
  late bool _mcpEnabled;
  late final TextEditingController _mcpIntegration;
  late final TextEditingController _pluginToken;
  late final TextEditingController _relayUrl;
  late final TextEditingController _relayDevice;
  late final TextEditingController _relayToken;
  late final TextEditingController _relayPublicKey;
  late bool _relayEnabled;
  late bool _relayE2e;

  /// Bridge address stored with the server. When the bridge is enabled from
  /// this dialog, it is derived from the server address; for existing servers
  /// a custom port is preserved.
  late String _bridgeAddress;
  late bool _bridgeEnabled;
  String? _bridgeError;
  bool _testing = false;
  String? _testMessage;
  bool _testOk = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.server?.name ?? 'Мой ПК');
    _url = TextEditingController(
      text: widget.server?.baseUrl.isNotEmpty == true
          ? widget.server!.baseUrl
          : 'http://192.168.1.100:1234',
    );
    _key = TextEditingController(text: widget.server?.apiKey ?? '');
    _bridgeAddress = widget.server?.bridgeUrl.trim() ?? '';
    _bridgeEnabled = _bridgeAddress.isNotEmpty;
    _chatViaBridge = widget.server?.chatViaBridge ?? true;
    _mcpEnabled = widget.server?.mcpEnabled ?? false;
    _mcpIntegration = TextEditingController(
      text:
          widget.server?.mcpIntegrationId ??
          ServerConfig.defaultMcpIntegrationId,
    );
    _pluginToken = TextEditingController(
      text: widget.server?.pluginToken ?? '',
    );
    _relayEnabled = widget.server?.hasRelay ?? false;
    _relayUrl = TextEditingController(text: widget.server?.relayUrl ?? '');
    _relayDevice = TextEditingController(
      text: widget.server?.relayDevice ?? '',
    );
    _relayToken = TextEditingController(text: widget.server?.relayToken ?? '');
    _relayE2e = widget.server?.relayE2e ?? false;
    _relayPublicKey = TextEditingController(
      text: widget.server?.relayPublicKey ?? '',
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _key.dispose();
    _mcpIntegration.dispose();
    _pluginToken.dispose();
    _relayUrl.dispose();
    _relayDevice.dispose();
    _relayToken.dispose();
    _relayPublicKey.dispose();
    super.dispose();
  }

  String get _baseHost {
    var value = _url.text.trim();
    if (value.isEmpty) return '';
    if (!value.contains('://')) value = 'http://$value';
    return Uri.tryParse(value)?.host ?? '';
  }

  /// Public device base derived from the relay fields.
  String get _relayBase {
    var value = _relayUrl.text.trim();
    if (value.isEmpty) return '';
    if (!value.contains('://')) value = 'https://$value';
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    final device = _relayDevice.text.trim();
    return device.isEmpty ? value : '$value/d/${Uri.encodeComponent(device)}';
  }

  /// Keeps a custom bridge port of an existing server, but follows the server
  /// address when its host changes. New bridges always use port 1235.
  String get _effectiveBridgeUrl {
    if (_relayEnabled) return _relayBase;
    if (!_bridgeEnabled) return '';
    if (_bridgeAddress.isNotEmpty) {
      var stored = _bridgeAddress;
      if (!stored.contains('://')) stored = 'http://$stored';
      final storedHost = Uri.tryParse(stored)?.host ?? '';
      if (storedHost.isNotEmpty && storedHost == _baseHost) {
        return _bridgeAddress;
      }
    }
    return ServerConfig.bridgeUrlForBase(_url.text);
  }

  String get _derivedPluginUrl =>
      _relayEnabled ? _relayBase : ServerConfig.pluginUrlForBase(_url.text);

  String get _relayKeyHint {
    final value = _relayPublicKey.text.trim();
    if (value.isEmpty) {
      return L10n.t('Возьмите из lm-relay-agent -print-identity.');
    }
    try {
      final key = parseE2ePublicKey(value);
      return L10n.tf('Отпечаток: {fp}', {'fp': e2eFingerprint(key)});
    } on E2eException catch (error) {
      return error.message;
    }
  }

  void _toggleBridge() {
    if (_bridgeEnabled) {
      setState(() {
        _bridgeEnabled = false;
        _bridgeAddress = '';
        _bridgeError = null;
      });
      return;
    }
    final address = ServerConfig.bridgeUrlForBase(_url.text);
    if (address.isEmpty) {
      setState(() => _bridgeError = L10n.t('Сначала укажите адрес сервера'));
      return;
    }
    setState(() {
      _bridgeEnabled = true;
      _bridgeAddress = address;
      _bridgeError = null;
    });
  }

  ServerConfig _build() => ServerConfig(
    id: widget.server?.id ?? newId(),
    name: _name.text.trim().isEmpty ? 'LM Studio' : _name.text.trim(),
    baseUrl: _url.text.trim(),
    apiKey: _key.text.trim(),
    bridgeUrl: _relayEnabled ? '' : _effectiveBridgeUrl,
    chatViaBridge: _chatViaBridge,
    mcpEnabled: _mcpEnabled,
    mcpIntegrationId: _mcpIntegration.text.trim().isEmpty
        ? ServerConfig.defaultMcpIntegrationId
        : _mcpIntegration.text.trim(),
    pluginToken: _pluginToken.text.trim(),
    relayUrl: _relayEnabled ? _relayUrl.text.trim() : '',
    relayDevice: _relayEnabled ? _relayDevice.text.trim() : '',
    relayToken: _relayEnabled ? _relayToken.text.trim() : '',
    relayE2e: _relayEnabled && _relayE2e,
    relayPublicKey: _relayEnabled && _relayE2e
        ? _relayPublicKey.text.trim()
        : '',
  );

  void _save() {
    final server = _build();
    final security = server.securityError;
    if (security != null) {
      setState(() {
        _testOk = false;
        _testMessage = security;
      });
      return;
    }
    if (server.pluginUrl.trim().isNotEmpty &&
        server.pluginSecurityError != null) {
      setState(() {
        _testOk = false;
        _testMessage = 'Плагин: ${server.pluginSecurityError}';
      });
      return;
    }
    if (server.hasRelay && server.relayDevice.trim().isEmpty) {
      setState(() {
        _testOk = false;
        _testMessage = L10n.t('Укажите ID устройства relay');
      });
      return;
    }
    if (server.hasRelay && server.effectiveRelayToken.isEmpty) {
      setState(() {
        _testOk = false;
        _testMessage = L10n.t('Укажите токен relay');
      });
      return;
    }
    if (server.relayE2e) {
      if (server.relayPublicKey.trim().isEmpty) {
        setState(() {
          _testOk = false;
          _testMessage = L10n.t('Укажите публичный ключ устройства');
        });
        return;
      }
      try {
        parseE2ePublicKey(server.relayPublicKey);
      } on E2eException catch (error) {
        setState(() {
          _testOk = false;
          _testMessage = error.message;
        });
        return;
      }
    }
    if (_bridgeEnabled && !server.hasRelay && server.bridgeUrl.isEmpty) {
      setState(() {
        _testOk = false;
        _testMessage = L10n.t('Сначала укажите адрес сервера');
      });
      return;
    }
    Navigator.pop(context, server);
  }

  Future<void> _test() async {
    final state = context.read<AppState>();
    final server = _build();
    if (!server.hasRelay && server.baseUrl.isEmpty) {
      setState(() {
        _testOk = false;
        _testMessage = 'Укажите адрес сервера';
      });
      return;
    }
    if (server.securityError != null) {
      setState(() {
        _testOk = false;
        _testMessage = server.securityError;
      });
      return;
    }
    setState(() {
      _testing = true;
      _testMessage = null;
    });
    final result = await state.refreshModels(server);
    BridgeHealth? bridge;
    if (server.hasBridge) {
      bridge = await state.bridgeHealth(server);
    }
    if (!mounted) return;
    final lines = <String>[];
    var ok = result.error == null;
    lines.add(
      result.error ??
          L10n.tf('Подключено. Доступно моделей: {count}', {
            'count': result.models.length,
          }),
    );
    if (bridge != null) {
      if (bridge.ok) {
        final version = bridge.version;
        lines.add(
          version == null || version.isEmpty
              ? L10n.t('Мостик GPU отвечает')
              : L10n.tf('Мостик GPU: {version}', {
                  'version': stripAnsi(version),
                }),
        );
      } else {
        ok = false;
        lines.add(
          L10n.tf('Мостик GPU: {error}', {
            'error': bridge.error ?? L10n.t('не отвечает'),
          }),
        );
      }
    }
    if (server.hasPlugin && server.pluginToken.trim().isNotEmpty) {
      final client = PluginClient(server);
      try {
        final plugin = await client.status();
        lines.add(
          L10n.tf('Плагин lm-computer {version}, лог: {level}', {
            'version': plugin.version.isEmpty ? '?' : plugin.version,
            'level': plugin.logLevel,
          }),
        );
      } on PluginException catch (error) {
        ok = false;
        lines.add(
          L10n.tf('Плагин lm-computer: {error}', {'error': error.message}),
        );
      } catch (error) {
        ok = false;
        lines.add(L10n.tf('Плагин lm-computer: {error}', {'error': error}));
      } finally {
        client.close();
      }
    }
    setState(() {
      _testing = false;
      _testOk = ok;
      _testMessage = lines.join('\n');
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.server == null ? 'Новый сервер' : 'Изменить сервер'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: InputDecoration(labelText: L10n.t('Название')),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              onChanged: (_) => setState(() {
                if (_bridgeError != null) _bridgeError = null;
              }),
              decoration: InputDecoration(
                labelText: L10n.t('Адрес'),
                hintText: 'http://192.168.1.50:1234',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _key,
              obscureText: true,
              decoration: InputDecoration(
                labelText: L10n.t('API-токен (если включён)'),
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Плагин lm-computer — токен для плагина и моста',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _pluginToken,
              obscureText: true,
              decoration: InputDecoration(
                labelText: L10n.t('Токен плагина'),
                helperText: _derivedPluginUrl.isEmpty
                    ? L10n.t(
                        'Из ~/.config/lm-computer/token.txt. '
                        'Сначала укажите адрес сервера.',
                      )
                    : L10n.tf(
                        'Из ~/.config/lm-computer/token.txt. Общий для плагина '
                        'и моста. Адрес: {url}',
                        {'url': _derivedPluginUrl},
                      ),
              ),
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(L10n.t('Доступ через интернет (relay)')),
              subtitle: Text(
                L10n.t(
                  'lm-relay на VPS. Локальный адрес выше останется для LAN.',
                ),
                style: TextStyle(
                  fontSize: 11.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              value: _relayEnabled,
              onChanged: (value) => setState(() => _relayEnabled = value),
            ),
            if (_relayEnabled) ...[
              TextField(
                controller: _relayUrl,
                keyboardType: TextInputType.url,
                autocorrect: false,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: L10n.t('Адрес relay'),
                  hintText: 'https://lm.example.com',
                  helperText: L10n.t(
                    'HTTPS. Для IP нужен самоподписанный сертификат.',
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _relayDevice,
                autocorrect: false,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: L10n.t('ID устройства'),
                  hintText: 'home-pc',
                  helperText: L10n.t('Ключ из devices в relay.json.'),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _relayToken,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: L10n.t('Токен relay'),
                  helperText: L10n.t(
                    'Отдельный токен relay. Не подставляется из токена плагина.',
                  ),
                ),
              ),
              if (_relayToken.text.trim().isEmpty &&
                  _pluginToken.text.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    L10n.t(
                      'Токен плагина больше не используется для relay. '
                      'Укажите отдельный токен relay.',
                    ),
                    style: TextStyle(fontSize: 11.5, color: scheme.error),
                  ),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(L10n.t('Сквозное шифрование (E2E)')),
                subtitle: Text(
                  L10n.t('Relay не видит пути, заголовки и содержимое.'),
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                value: _relayE2e,
                onChanged: (value) => setState(() => _relayE2e = value),
              ),
              if (_relayE2e)
                TextField(
                  controller: _relayPublicKey,
                  autocorrect: false,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: L10n.t('Публичный ключ устройства'),
                    hintText: 'base64 или hex, 32 байта',
                    helperText: _relayKeyHint,
                    helperMaxLines: 3,
                  ),
                ),
            ],
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Мост GPU — необязательно',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (_bridgeEnabled)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.check_circle_rounded,
                          size: 16,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          L10n.t('Мост включён'),
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: scheme.primary,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  OutlinedButton.icon(
                    onPressed: _toggleBridge,
                    icon: const Icon(
                      Icons.power_settings_new_rounded,
                      size: 18,
                    ),
                    label: Text(L10n.t('Включить мост')),
                  ),
                if (_bridgeEnabled)
                  TextButton(
                    onPressed: _toggleBridge,
                    child: Text(L10n.t('Отключить')),
                  ),
              ],
            ),
            if (_bridgeEnabled)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  L10n.tf('Адрес моста: {url}', {'url': _effectiveBridgeUrl}),
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (_bridgeError != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _bridgeError!,
                    style: TextStyle(fontSize: 11.5, color: scheme.error),
                  ),
                ),
              ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                L10n.t('Мост использует токен плагина выше.'),
                style: TextStyle(
                  fontSize: 11.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            if (_bridgeEnabled)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _chatViaBridge,
                onChanged: (value) => setState(() => _chatViaBridge = value),
                title: const Text('Чат через мост'),
                subtitle: const Text(
                  'Ответ готовится на сервере и не обрывается в фоне. '
                  'Нужен обновлённый lms_gpu_bridge.py.',
                ),
              ),
            const Divider(height: 24),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _mcpEnabled,
              onChanged: (value) => setState(() => _mcpEnabled = value),
              title: Text(L10n.t('MCP-инструменты')),
              subtitle: Text(
                L10n.t(
                  'Модель вызывает инструменты плагина (файлы, команды). '
                  'Нужен LM Studio 0.4+, API-токен и разрешение на серверы '
                  'из mcp.json. Чат через мост и структурированный вывод '
                  'при этом не используются.',
                ),
              ),
            ),
            if (_mcpEnabled) ...[
              TextField(
                controller: _mcpIntegration,
                decoration: InputDecoration(
                  labelText: L10n.t('ID интеграции'),
                  helperText: L10n.t(
                    'mcp/lm-computer — сервер из mcp.json. '
                    'lmchat/lm-computer — нативный плагин.',
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  L10n.t(
                    'Инструменты выполняет LM Studio, приложение только '
                    'показывает ответ.',
                  ),
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _testing ? null : _test,
                icon: _testing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_tethering_rounded, size: 18),
                label: const Text('Проверить подключение'),
              ),
            ),
            if (_testMessage != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: (_testOk ? scheme.primary : scheme.error).withValues(
                      alpha: 0.12,
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    _testMessage!,
                    style: TextStyle(
                      fontSize: 12,
                      color: _testOk ? scheme.primary : scheme.error,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(onPressed: _save, child: const Text('Сохранить')),
      ],
    );
  }
}
