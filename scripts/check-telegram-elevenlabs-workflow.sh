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

if jq -e '.. | objects | select(has("xi-api-key") and ((.["xi-api-key"] | type) != "string" or (.["xi-api-key"] | startswith("={{") | not)))' "$WORKFLOW_PATH" >/dev/null; then
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

if grep -E 'https://api\.telegram\.org/bot[0-9]{6,}:[A-Za-z0-9_-]{20,}' "$WORKFLOW_PATH" >/dev/null; then
  echo "Workflow appears to contain a literal Telegram bot token URL." >&2
  exit 1
fi

if jq -e '.. | objects | select(.name? == "BOT_ACCESS_PASSWORD" and has("value") and ((.value | type) != "string" or (.value | startswith("={{") | not)))' "$WORKFLOW_PATH" >/dev/null; then
  echo "Workflow appears to contain a literal access password value." >&2
  exit 1
fi

required_nodes=(
  "Normalize Telegram Update"
  "Ensure Bot DB Schema"
  "Load User Context"
  "Route Telegram Event"
  "Route Switch"
  "Filter Callback Answer"
  "Register User"
  "Refresh User Context"
  "Set Dialog State"
  "Build Telegram Plain Reply"
  "Build Telegram Keyboard Request"
  "Send Telegram Keyboard Message"
  "Pending ElevenLabs Action Reply"
  "Build ElevenLabs Agent Payload"
  "Reserve Agent Slot"
  "Build Agent Limit Reply"
  "Prepare Reserved Agent Create"
  "Create ElevenLabs Agent"
  "Save Created Agent"
  "Refresh User Context After Agent Create"
  "Build Created Agent Reply"
  "Validate Agent Update Ownership"
  "Build Agent Ownership Error Reply"
  "Restore Validated Agent Update Context"
  "Get ElevenLabs Agent"
  "Create Knowledge Document"
  "Build ElevenLabs Patch"
  "Patch ElevenLabs Agent"
  "Save Agent Update"
  "Build Agent Update Reply"
  "Delete Old Knowledge Document"
  "Log Bot Event"
  "Answer Callback Query"
  "Reply in Telegram"
)

for node_name in "${required_nodes[@]}"; do
  if ! jq -e --arg node_name "$node_name" '.nodes[] | select(.name == $node_name)' "$WORKFLOW_PATH" >/dev/null; then
    echo "Workflow is missing required node: $node_name" >&2
    exit 1
  fi
done

jq -e '[.nodes[] | select(.type == "n8n-nodes-base.postgres")] | length >= 6' "$WORKFLOW_PATH" >/dev/null
jq -e '[.nodes[] | select(.type == "n8n-nodes-base.httpRequest")] | length >= 5' "$WORKFLOW_PATH" >/dev/null
jq -e '[.nodes[] | select(.type == "n8n-nodes-base.code")] | length >= 3' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Create ElevenLabs Agent") | .parameters.method == "POST"' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Create ElevenLabs Agent") | .parameters.url == "https://api.elevenlabs.io/v1/convai/agents/create"' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Create ElevenLabs Agent") | .parameters.authentication == "genericCredentialType" and .parameters.genericAuthType == "httpHeaderAuth"' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Create ElevenLabs Agent") | .credentials.httpHeaderAuth.name == "ElevenLabs API Key"' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Reserve Agent Slot") | .parameters.query | contains("FOR UPDATE")' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Reserve Agent Slot") | .parameters.query | contains("interval '"'"'15 minutes'"'"'")' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Get ElevenLabs Agent") | .parameters.method == "GET" and .parameters.authentication == "genericCredentialType"' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Patch ElevenLabs Agent") | .parameters.method == "PATCH" and .parameters.authentication == "genericCredentialType"' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Save Agent Update") | .parameters.query | contains("user_id = (SELECT id FROM bot_user)")' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Validate Agent Update Ownership") | .parameters.query | contains("FOR UPDATE")' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Validate Agent Update Ownership") | .parameters.query | contains("validated_agent")' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Patch ElevenLabs Agent") | .parameters.genericAuthType == "httpHeaderAuth" and .credentials.httpHeaderAuth.name == "ElevenLabs API Key"' "$WORKFLOW_PATH" >/dev/null

echo "Telegram ElevenLabs workflow validation passed."
