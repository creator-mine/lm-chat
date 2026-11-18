import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../l10n_text.dart';
import '../sync/crypto.dart';
import '../sync/models.dart';
import '../sync/service.dart';

class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key});

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  bool _busy = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
  }

  SyncService get _sync => context.read<AppState>().sync;

  Future<void> _setEnabled(bool value) async {
    setState(() => _busy = true);
    try {
      await _sync.setEnabled(value);
    } catch (error) {
      _snack('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setName() async {
    final controller = TextEditingController(text: _sync.deviceName);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Имя устройства'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Как показывать в списке',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(L10n.t('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(L10n.t('Сохранить')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    await _sync.setDeviceName(name);
  }

  Future<void> _scan() async {
    if (!_sync.enabled) {
      _snack('Сначала включите синхронизацию');
      return;
    }
    setState(() => _busy = true);
    try {
      final peers = await _sync.scan();
      if (!mounted) return;
      if (peers.isEmpty) {
        final address = await _askAddress();
        if (address != null) await _pairAddress(address);
        return;
      }
      final selected = await showDialog<SyncDiscoveredPeer>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Найденные устройства'),
          content: SizedBox(
            width: 420,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final peer in peers)
                  ListTile(
                    leading: const Icon(Icons.devices_rounded),
                    title: Text(peer.name),
                    subtitle: Text(
                      '${peer.host}:${peer.port}'
                      '${_sync.pairedPeers.any((p) => p.deviceId == peer.deviceId) ? ' · сопряжено' : ''}',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.pop(context, peer),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(L10n.t('Отмена')),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(context);
                final address = await _askAddress();
                if (address != null) await _pairAddress(address);
              },
              child: const Text('Ввести адрес'),
            ),
          ],
        ),
      );
      if (selected != null) await _pair(selected);
    } catch (error) {
      _snack('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pair(SyncDiscoveredPeer peer) async {
    setState(() => _busy = true);
    _snack('Подтвердите 8 цифр на обоих устройствах');
    try {
      final paired = await _sync.pairWith(peer);
      _snack('Устройство «${paired.name}» сопряжено');
    } catch (error) {
      _snack('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pairAddress(String address) async {
    setState(() => _busy = true);
    try {
      final paired = await _sync.pairWithAddress(address);
      _snack('Устройство «${paired.name}» сопряжено');
    } catch (error) {
      _snack('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askAddress() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Добавить по адресу'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'IP:порт',
            hintText: '192.168.1.5:53421',
            helperText: 'Адрес показан на втором устройстве',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(L10n.t('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(L10n.t('Подключиться')),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }

  Future<void> _syncNow() async {
    setState(() => _busy = true);
    try {
      final result = await _sync.syncNow();
      if (!mounted) return;
      if (result.devices == 0 && result.errors.isEmpty) {
        _snack('Нет устройств онлайн');
      } else if (result.errors.isNotEmpty) {
        _snack(result.errors.join('\n'));
      } else {
        _snack(
          'Синхронизировано устройств: ${result.devices}\n'
          '${result.summary}',
        );
      }
    } catch (error) {
      _snack('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forget(SyncPeer peer) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Забыть устройство?'),
        content: Text(
          '«${peer.name}» больше не сможет синхронизироваться с этим '
          'устройством без повторного сопряжения.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(L10n.t('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(L10n.t('Забыть')),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _sync.forgetPeer(peer.deviceId);
    }
  }

  Future<void> _showAddresses() async {
    final addresses = await _sync.localAddresses();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Адрес этого устройства'),
        content: addresses.isEmpty
            ? const Text('Сначала включите синхронизацию.')
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Введите этот адрес на втором устройстве:'),
                  const SizedBox(height: 12),
                  for (final address in addresses)
                    SelectableText(
                      address,
                      style: const TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontSize: 14,
                      ),
                    ),
                ],
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(L10n.t('Закрыть')),
          ),
        ],
      ),
    );
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final sync = app.sync;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Синхронизация')),
      body: AnimatedBuilder(
        animation: sync,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Card(
              child: Column(
                children: [
                  SwitchListTile(
                    secondary: const Icon(Icons.sync_rounded),
                    title: const Text('Синхронизация по локальной сети'),
                    subtitle: const Text(
                      'Чаты и серверы между устройствами в одной сети',
                    ),
                    value: sync.enabled,
                    onChanged: _busy ? null : _setEnabled,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.badge_outlined),
                    title: const Text('Имя устройства'),
                    subtitle: Text(sync.deviceName),
                    trailing: const Icon(Icons.edit_outlined, size: 18),
                    onTap: _setName,
                  ),
                  ListTile(
                    leading: const Icon(Icons.fingerprint_rounded),
                    title: const Text('ID устройства'),
                    subtitle: Text(
                      sync.deviceId.isEmpty
                          ? 'ещё не создан'
                          : syncShortId(sync.deviceId),
                      style: const TextStyle(fontFamily: 'JetBrainsMono'),
                    ),
                  ),
                  ListTile(
                    leading: Icon(
                      sync.discoveryAvailable
                          ? Icons.wifi_tethering_rounded
                          : Icons.wifi_off_rounded,
                    ),
                    title: Text(
                      sync.discoveryAvailable
                          ? 'Поиск по LAN доступен'
                          : 'Поиск по LAN недоступен',
                    ),
                    subtitle: Text(
                      sync.listenerPort > 0
                          ? 'Порт: ${sync.listenerPort}'
                          : 'Слушатель не запущен',
                    ),
                    trailing: TextButton(
                      onPressed: sync.enabled ? _showAddresses : null,
                      child: const Text('Адрес'),
                    ),
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    secondary: const Icon(Icons.play_circle_outline_rounded),
                    title: const Text('Автосинхронизация при старте'),
                    value: sync.autoStart,
                    onChanged: sync.enabled
                        ? (value) => sync.setAutoStart(value)
                        : null,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                    child: Row(
                      children: [
                        Icon(
                          Icons.devices_rounded,
                          size: 18,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'Сопряжённые устройства',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const Spacer(),
                        Text(
                          '${sync.pairedPeers.length}',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  if (sync.pairedPeers.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
                      child: Text(
                        'Пока никого. Нажмите «Найти устройства» на обоих '
                        'устройствах и сравните 8 цифр.',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  else
                    for (final peer in sync.pairedPeers)
                      ListTile(
                        leading: CircleAvatar(
                          radius: 16,
                          child: Text(
                            peer.name.isEmpty
                                ? '?'
                                : peer.name.substring(0, 1).toUpperCase(),
                          ),
                        ),
                        title: Text(peer.name),
                        subtitle: Text(
                          [
                            sync.peerStatusLabel(peer.deviceId),
                            if (peer.lastSync != null)
                              'последняя: ${_time(peer.lastSync!)}',
                          ].join(' · '),
                        ),
                        trailing: IconButton(
                          onPressed: () => _forget(peer),
                          icon: const Icon(Icons.link_off_rounded, size: 18),
                          tooltip: L10n.t('Забыть'),
                        ),
                      ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        TextButton.icon(
                          onPressed: sync.enabled && !_busy ? _scan : null,
                          icon: const Icon(Icons.search_rounded, size: 18),
                          label: const Text('Найти устройства'),
                        ),
                        TextButton.icon(
                          onPressed: sync.enabled && !_busy
                              ? () async {
                                  final address = await _askAddress();
                                  if (address != null) {
                                    await _pairAddress(address);
                                  }
                                }
                              : null,
                          icon: const Icon(Icons.add_link_rounded, size: 18),
                          label: const Text('По адресу'),
                        ),
                        FilledButton.icon(
                          onPressed: sync.enabled && !_busy ? _syncNow : null,
                          icon: const Icon(Icons.sync_rounded, size: 18),
                          label: const Text('Синхронизировать'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Что синхронизируется',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Только чаты и серверы. Без API-токенов, шаблонов, '
                      'оформления и вложений. Удаления не переносятся: '
                      'удалённый на одном устройстве чат вернётся, если он '
                      'есть на другом.',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Оба приложения должны быть открыты в одной сети. '
                      'При первом сопряжении сравните 8 цифр на двух экранах.',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _time(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(local.day)}.${two(local.month)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
