# lm-relay

Небольшой relay для LM Chat: агент на машине с LM Studio открывает исходящее
WebSocket-соединение, а relay на VPS мультиплексирует в него HTTP-запросы
приложения. Входящие порты дома не открываются, NAT и CGNAT не мешают.

```text
телефон/ПК                     VPS                         дом с LM Studio
LM Chat ── HTTPS/SSE ──▶ nginx (TLS) ──▶ relay ◀── WSS ── agent
                                       :8787              ├─ 1234 LM Studio
                                                          ├─ 1235 мост
                                                          └─ 1236 плагин
```

Один публичный origin `/d/<device>/…` заменяет три локальных адреса:

| Путь | Куда |
|---|---|
| `/v1/*`, `/api/v1/*` | LM Studio `1234` |
| `/api/*` (кроме `/api/v1/*`) | плагин `1236` |
| `/health`, `/ps`, `/load`, `/unload`, `/estimate`, `/chat`, `/chat/*` | мост `1235` |

Порт `1237` (MCP) наружу не выносится: LM Studio вызывает плагин локально.

## Состояние

Реализовано ядро: протокол кадров, relay, агент, маршрутизация, аутентификация,
flow control, SSE без буферизации, конфиги, nginx и systemd.

Ещё не сделано: режим relay в самом приложении LM Chat, E2E-шифрование,
статус «онлайн/офлайн» в диагностике. До этого relay можно проверять `curl`.

## Сборка

```bash
cd tools/lm-relay
go build ./cmd/relay ./cmd/agent
go test ./...
```

Бинарники появятся в текущем каталоге: `relay` и `agent` (`agent.exe` на
Windows).

## Секреты

Для каждого устройства нужны два независимых секрета:

```bash
openssl rand -base64 32   # agent_secret
openssl rand -base64 32   # access_token
```

`agent_secret` знает только агент и relay. `access_token` вводится в приложении
и передаётся в заголовке `X-Relay-Token`. Это не токен LM Studio и не токен
плагина: они идут дальше в `Authorization` и проверяются конечными сервисами.

## Relay на VPS

1. Скопируйте `relay.example.json` в `relay.json`, вставьте секреты.
2. Ограничьте доступ: `chmod 600 relay.json`.
3. Запустите:

```bash
./relay -config relay.json
```

Или в Docker:

```bash
RELAY_UID=$(id -u) RELAY_GID=$(id -g) docker compose -f deploy/docker-compose.yml up -d --build
```

Relay слушает `127.0.0.1:8787`; наружу его публикует nginx.

## nginx и сертификат

```bash
certbot certonly --nginx -d lm.example.com
```

Скопируйте `deploy/nginx/lm-relay.conf` в `/etc/nginx/conf.d/`, замените
`lm.example.com`, выполните `nginx -t && systemctl reload nginx`.

Критичные директивы уже выставлены: `proxy_buffering off`,
`proxy_request_buffering off`, `proxy_read_timeout 1200s`, `gzip off`,
WebSocket upgrade для `/_tunnel`. Без них SSE обрывается через 60 секунд или
приходит рывками.

Если 443 занят, используйте отдельный порт (`listen 8443 ssl default_server`)
или поддомен.

### IP без домена

Публичный сертификат на IP Let's Encrypt не выдаёт. Вариант — самоподписанный
сертификат с IP SAN:

```bash
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout /etc/nginx/tls/relay.key \
  -out    /etc/nginx/tls/relay.crt \
  -subj "/CN=lm-relay" \
  -addext "subjectAltName=IP:203.0.113.5"
```

Приложение должно доверять этому сертификату (поле «CA/отпечаток»); одного
системного хранилища на Android недостаточно. В агенте укажите `ca_file`, если
он ходит на relay по самоподписанному сертификату.

## Агент рядом с LM Studio

1. Скопируйте `agent.example.json` в `~/.config/lm-computer/relay-agent.json`,
   вставьте тот же `agent_secret` и `device_id`.
2. `chmod 600 ~/.config/lm-computer/relay-agent.json`.
3. Установите бинарник и unit:

```bash
install -m 0755 agent ~/.local/bin/lm-relay-agent
mkdir -p ~/.config/systemd/user
cp deploy/systemd/lm-relay-agent.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now lm-relay-agent
```

На Windows агент запускается как обычный `agent.exe -config agent.json`;
для автозапуска используйте `sc create` или Планировщик заданий.

## Проверка

```bash
export RELAY=https://lm.example.com
export TOKEN=...access_token...

curl -sS -H "X-Relay-Token: $TOKEN" "$RELAY/d/home-pc/api/status"
curl -sS -H "X-Relay-Token: $TOKEN" "$RELAY/d/home-pc/health"
curl -sS -H "X-Relay-Token: $TOKEN" "$RELAY/d/home-pc/api/v1/models"
```

Чат:

```bash
curl -sS -N -H "X-Relay-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"...","messages":[{"role":"user","content":"hi"}]}' \
  "$RELAY/d/home-pc/v1/chat/completions"
```

Ожидаемые коды: без токена — `401`, неизвестное устройство — `404`, агент
офлайн — `503` с `Retry-After`.

## Конфигурация relay

| Поле | По умолчанию | Смысл |
|---|---|---|
| `listen` | `127.0.0.1:8787` | адрес HTTP-фронта |
| `max_body_bytes` | 16 МиБ | лимит тела запроса |
| `response_timeout` | `5m` | ожидание заголовков от агента |
| `max_streams` | 64 | параллельные потоки на устройство |
| `rate_per_second` / `rate_burst` | 20 / 40 | лимит запросов на устройство |
| `devices.<id>.agent_secret` | — | секрет агента, ≥16 байт |
| `devices.<id>.access_token` | — | токен приложения, ≥16 байт |
| `devices.<id>.services` | все | какие сервисы видны снаружи |

## Конфигурация агента

| Поле | Смысл |
|---|---|
| `relay_url` | `wss://…/_tunnel` |
| `device_id` | ключ из `devices` на relay |
| `agent_secret` | тот же секрет, что на relay |
| `services` | локальные базовые URL сервисов |
| `ca_file` | PEM корневого CA для самоподписанного relay |
| `allow_shutdown` | разрешить `POST /api/shutdown` (по умолчанию нет) |

Агент принимает только `GET`, `HEAD`, `POST`, `PUT`, `PATCH`, `DELETE`,
`OPTIONS`, отклоняет абсолютные URL и `..`, а `shutdown` требует ещё и
заголовок `X-Relay-Confirm: shutdown`.

## Безопасность

- Наружу открыты только 80/443 VPS. Домашняя сеть не слушает ничего нового.
- `access_token` в режиме полного доступа эквивалентен shell-доступу к машине:
  используйте 32+ байта и отдельное значение для каждого устройства.
- Relay не пишет пути, query, тела и токены: только устройство, сервис,
  статус, миллисекунды и размеры.
- TLS обязателен. E2E, при котором relay не видит содержимое, — следующий этап.
- `X-Relay-Token` никогда не пересылается агенту; `Authorization` и токен
  плагина остаются для конечных сервисов.

## Ограничения

- Приложение LM Chat пока не умеет режим relay: нужны правки в `ServerConfig`,
  `LmClient`, `PluginClient` и настройках.
- Нет E2E, статуса устройства и веб-интерфейса.
- Один relay может обслуживать несколько устройств; у каждого свои секреты.
