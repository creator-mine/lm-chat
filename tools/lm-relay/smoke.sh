#!/usr/bin/env bash
# End-to-end smoke test through nginx/relay.
#
#   RELAY=https://lm.example.com TOKEN=... DEVICE=home-pc ./smoke.sh
#
# Optional: MODEL=openai/gpt-oss-20b runs one streaming chat request.
set -euo pipefail

: "${RELAY:?Set RELAY, e.g. https://lm.example.com}"
: "${TOKEN:?Set TOKEN to the relay access_token}"
DEVICE="${DEVICE:-home-pc}"
BASE="${RELAY%/}/d/${DEVICE}"

request() {
  curl --fail --silent --show-error --max-time "${2:-30}" \
    -H "X-Relay-Token: ${TOKEN}" "$1"
}

echo "1/4 relay status"
request "${BASE}/_relay/status"
echo

echo "2/4 bridge health"
request "${BASE}/health"
echo

echo "3/4 plugin status"
request "${BASE}/api/status"
echo

echo "4/4 LM Studio models"
request "${BASE}/api/v1/models" | head -c 400
echo

if [[ -n "${MODEL:-}" ]]; then
  echo "5/5 streaming chat (${MODEL})"
  curl --fail --silent --show-error --max-time 120 \
    -H "X-Relay-Token: ${TOKEN}" \
    -H 'Content-Type: application/json' \
    -H 'Accept: text/event-stream' \
    -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":8,\"stream\":true}" \
    "${BASE}/v1/chat/completions" | head -n 8
fi

echo "OK"
