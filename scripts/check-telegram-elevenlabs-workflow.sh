#!/usr/bin/env bash

set -euo pipefail

WORKFLOW_PATH="${1:-${WORKFLOW_PATH:-n8n/workflows/telegram-elevenlabs-bot.json}}"

if [[ ! -f "$WORKFLOW_PATH" ]]; then
  echo "Workflow file not found: $WORKFLOW_PATH" >&2
  exit 1
fi

jq -e '.id == "tgElevenLabsBot01"' "$WORKFLOW_PATH" >/dev/null
jq -e '.name == "Telegram ElevenLabs Bot"' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Telegram Trigger") | .parameters.updates | index("message")' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Telegram Trigger") | .parameters.updates | index("callback_query")' "$WORKFLOW_PATH" >/dev/null

required_nodes=(
  "Normalize Telegram Update"
  "Ensure Bot DB Schema"
  "Load User Context"
  "Route Telegram Event"
  "Route Switch"
  "Register User"
  "Refresh User Context"
  "Set Dialog State"
  "Create ElevenLabs Agent"
  "Save Created Agent"
  "Get ElevenLabs Agent"
  "Create Knowledge Document"
  "Build ElevenLabs Patch"
  "Patch ElevenLabs Agent"
  "Save Agent Update"
  "Delete Old Knowledge Document"
  "Log Bot Event"
  "Answer Callback Query"
  "Reply in Telegram"
)

for node_name in "${required_nodes[@]}"; do
  jq -e --arg node_name "$node_name" '.nodes[] | select(.name == $node_name)' "$WORKFLOW_PATH" >/dev/null
done

jq -e '[.nodes[] | select(.type == "n8n-nodes-base.postgres")] | length >= 6' "$WORKFLOW_PATH" >/dev/null
jq -e '[.nodes[] | select(.type == "n8n-nodes-base.httpRequest")] | length >= 5' "$WORKFLOW_PATH" >/dev/null
jq -e '[.nodes[] | select(.type == "n8n-nodes-base.code")] | length >= 3' "$WORKFLOW_PATH" >/dev/null

if grep -E 'xi-api-key"[[:space:]]*:[[:space:]]*"[^=]' "$WORKFLOW_PATH" >/dev/null; then
  echo "Workflow appears to contain a literal ElevenLabs API key header." >&2
  exit 1
fi

if jq -e '.. | objects | select(.name? == "xi-api-key" and has("value") and ((.value | type) != "string" or (.value | startswith("={{") | not)))' "$WORKFLOW_PATH" >/dev/null; then
  echo "Workflow appears to contain a literal ElevenLabs API key header." >&2
  exit 1
fi

if grep -E 'BOT_ACCESS_PASSWORD[[:space:]]*=' "$WORKFLOW_PATH" >/dev/null; then
  echo "Workflow appears to contain a literal access password assignment." >&2
  exit 1
fi

if jq -e '.. | objects | select(.name? == "BOT_ACCESS_PASSWORD" and has("value") and ((.value | type) != "string" or (.value | startswith("={{") | not)))' "$WORKFLOW_PATH" >/dev/null; then
  echo "Workflow appears to contain a literal access password value." >&2
  exit 1
fi

echo "Telegram ElevenLabs workflow validation passed."
