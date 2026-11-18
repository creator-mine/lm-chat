import 'package:flutter/material.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:lm_chat/l10n_text.dart';
import 'package:lm_chat/models.dart';
import 'package:lm_chat/server_share.dart';
import 'package:lm_chat/widgets/server_share_sheet.dart';
import 'package:qr_flutter/qr_flutter.dart';

ServerConfig _relayServer({String token = 'relay-secret'}) => ServerConfig(
  id: 'relay',
  name: 'Домашний ПК',
  baseUrl: 'http://192.168.1.50:1234',
  relayUrl: 'https://relay.example.com',
  relayDevice: 'home-pc',
  relayToken: token,
  relayE2e: true,
  relayPublicKey: 'public-key',
);

Future<void> _openSheet(
  WidgetTester tester,
  List<ServerConfig> servers, {
  bool all = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showServerShareSheet(context, servers: servers, all: all),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('without relay shows the QR immediately', (tester) async {
    await _openSheet(tester, [_relayServer()]);

    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.textContaining('Я понимаю'), findsNothing);
  });

  testWidgets('with relay hides the QR until the risk is confirmed', (
    tester,
  ) async {
    await _openSheet(tester, [_relayServer()]);

    await tester.tap(find.text(L10n.t('С relay')));
    await tester.pumpAndSettle();

    expect(find.byType(QrImageView), findsNothing);
    expect(find.textContaining('токен доступа'), findsWidgets);

    await tester.ensureVisible(find.textContaining('Я понимаю'));
    await tester.tap(find.textContaining('Я понимаю'));
    await tester.pumpAndSettle();

    expect(find.byType(QrImageView), findsOneWidget);
  });

  testWidgets('with relay without a token needs no confirmation', (
    tester,
  ) async {
    await _openSheet(tester, [_relayServer(token: '')]);

    await tester.tap(find.text(L10n.t('С relay')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Я понимаю'), findsNothing);
    expect(find.byType(QrImageView), findsOneWidget);
  });

  testWidgets('all servers produce one shared code', (tester) async {
    await _openSheet(tester, [_relayServer(), _relayServer()], all: true);

    expect(find.textContaining('Серверов: 2'), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
  });

  test('the single-server code fits in a QR image', () {
    final code = ServerShareCodec.encodeServer(
      _relayServer(),
      ServerShareMode.withoutRelay,
    );
    expect(ServerShareCodec.fitsQr(code), isTrue);
  });
}
