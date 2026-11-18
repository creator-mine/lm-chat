import 'dart:async';

import 'package:flutter/material.dart';

import 'models.dart';
import 'service.dart';

/// Shows the global 8-digit pairing dialog while the app is open.
class SyncPairingHost extends StatefulWidget {
  const SyncPairingHost({
    super.key,
    required this.service,
    required this.navigatorKey,
    required this.child,
  });

  final SyncService service;
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  State<SyncPairingHost> createState() => _SyncPairingHostState();
}

class _SyncPairingHostState extends State<SyncPairingHost> {
  StreamSubscription<SyncPairingPrompt>? _subscription;
  final List<SyncPairingPrompt> _queue = [];
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    _subscription = widget.service.pairingPrompts.listen((prompt) {
      _queue.add(prompt);
      unawaited(_showNext());
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _showNext() async {
    if (_showing || _queue.isEmpty) return;
    _showing = true;
    final prompt = _queue.removeAt(0);
    await Future<void>.delayed(Duration.zero);
    if (!mounted) {
      _showing = false;
      return;
    }
    final context = widget.navigatorKey.currentContext;
    if (context == null || !context.mounted) {
      _showing = false;
      return;
    }

    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Сопряжение устройств'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              prompt.incoming
                  ? 'Устройство «${prompt.deviceName}» хочет '
                        'синхронизироваться.'
                  : 'Подключение к «${prompt.deviceName}».',
            ),
            const SizedBox(height: 14),
            const Text('Сравните цифры на двух экранах:'),
            const SizedBox(height: 8),
            SelectableText(
              prompt.sas,
              style: const TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 30,
                fontWeight: FontWeight.w600,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Если цифры не совпадают, нажмите «Отклонить».',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отклонить'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Совпадает'),
          ),
        ],
      ),
    );

    if (accepted == true) {
      await widget.service.acceptPairing(prompt);
    } else {
      await widget.service.declinePairing(prompt);
    }
    _showing = false;
    unawaited(_showNext());
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
