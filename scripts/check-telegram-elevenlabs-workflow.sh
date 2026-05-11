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

if grep -F 'process.env' "$WORKFLOW_PATH" >/dev/null; then
  echo "Workflow Code nodes must not use process.env; n8n v2 task runners do not expose process." >&2
  exit 1
fi

if grep -F '$env.' "$WORKFLOW_PATH" >/dev/null; then
  echo "Workflow must not depend on n8n environment-variable expressions for bot settings." >&2
  exit 1
fi

if grep -E '__[A-Z0-9_]+CREDENTIAL_ID__' "$WORKFLOW_PATH" >/dev/null; then
  echo "Workflow must not contain placeholder credential IDs; attach credentials after import." >&2
  exit 1
fi

if grep -F '.item.json' "$WORKFLOW_PATH" >/dev/null; then
  echo "Workflow must not use .item.json node lookups; use first().json to avoid paired-item failures in n8n task runners." >&2
  exit 1
fi

if jq -e '.. | objects | select(.name? == "BOT_ACCESS_PASSWORD" and has("value") and ((.value | type) != "string" or (.value | startswith("={{") | not)))' "$WORKFLOW_PATH" >/dev/null; then
  echo "Workflow appears to contain a literal access password value." >&2
  exit 1
fi

required_nodes=(
  "Normalize Telegram Update"
  "Ensure Bot DB Schema"
  "Load Bot Settings"
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
  "Filter Create Agent Success"
  "Filter Create Agent Failure"
  "Create ElevenLabs Agent"
  "Filter Save Created Agent Success"
  "Save Created Agent"
  "Filter Save Created Agent Failure"
  "Refresh User Context After Agent Create"
  "Build Created Agent Reply"
  "Validate Agent Update Ownership"
  "Build Agent Ownership Error Reply"
  "Restore Validated Agent Update Context"
  "Get ElevenLabs Agent"
  "Filter Direct Agent Patch"
  "Build Knowledge Document Request"
  "Create Knowledge Document"
  "Filter Create Knowledge Success"
  "Filter Create Knowledge Failure"
  "Build ElevenLabs Patch"
  "Patch ElevenLabs Agent"
  "Filter Patch Agent Success"
  "Filter Patch Agent Failure"
  "Save Agent Update"
  "Filter Save Agent Update Success"
  "Filter Save Agent Update Failure"
  "Reset Dialog State After Failure"
  "Build Agent Update Reply"
  "Prepare Old Knowledge Deletion"
  "Delete Old Knowledge Document"
  "Build Cleanup Failure Event Log"
  "Build Bot Event Log"
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
jq -e '.nodes[] | select(.name == "Ensure Bot DB Schema") | .parameters.query | contains("CREATE TABLE IF NOT EXISTS bot_settings") and contains("INSERT INTO bot_settings (id)") and contains("SELECT true AS schema_ready")' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Load Bot Settings") | .parameters.query | contains("access_password_configured") and contains("access_password_matched") and contains("telegram_bot_api_base_url") and contains("FROM bot_settings")' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Normalize Telegram Update") | .parameters.jsCode | contains("botSettings") and contains("access_password_matched") and contains("telegram_bot_api_base_url")' "$WORKFLOW_PATH" >/dev/null
jq -e '.connections["Telegram Trigger"].main[0] | map(.node) | index("Ensure Bot DB Schema")' "$WORKFLOW_PATH" >/dev/null
jq -e '.connections["Ensure Bot DB Schema"].main[0] | map(.node) | index("Load Bot Settings")' "$WORKFLOW_PATH" >/dev/null
jq -e '.connections["Load Bot Settings"].main[0] | map(.node) | index("Normalize Telegram Update")' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Send Telegram Keyboard Message") | .parameters.url | contains("settings.telegramBotApiBaseUrl")' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Create ElevenLabs Agent") | .parameters.method == "POST"' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Create ElevenLabs Agent") | .parameters.url == "https://api.elevenlabs.io/v1/convai/agents/create"' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Create ElevenLabs Agent") | .parameters.authentication == "genericCredentialType" and .parameters.genericAuthType == "httpHeaderAuth"' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Reserve Agent Slot") | .parameters.query | contains("FOR UPDATE")' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Reserve Agent Slot") | .parameters.query | contains("interval '"'"'15 minutes'"'"'")' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Get ElevenLabs Agent") | .parameters.method == "GET" and .parameters.authentication == "genericCredentialType"' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Patch ElevenLabs Agent") | .parameters.method == "PATCH" and .parameters.authentication == "genericCredentialType"' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Save Agent Update") | .parameters.query | contains("user_id = (SELECT id FROM bot_user)")' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Validate Agent Update Ownership") | .parameters.query | contains("FOR UPDATE")' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Validate Agent Update Ownership") | .parameters.query | contains("validated_agent")' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Patch ElevenLabs Agent") | .parameters.genericAuthType == "httpHeaderAuth"' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Create Knowledge Document") | .parameters.method == "POST" and .parameters.url == "https://api.elevenlabs.io/v1/convai/knowledge-base/text"' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Create Knowledge Document") | .parameters.genericAuthType == "httpHeaderAuth"' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Build ElevenLabs Patch") | .parameters.jsCode | contains("knowledge_base") and contains("usage_mode")' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Save Agent Update") | .parameters.query | contains("knowledge_document_id")' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Delete Old Knowledge Document") | .parameters.method == "DELETE"' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Delete Old Knowledge Document") | .parameters.options.response.response.neverError == true' "$WORKFLOW_PATH" >/dev/null
if jq -e '.nodes[] | select(.name == "Delete Old Knowledge Document") | .parameters.url | contains("force=true")' "$WORKFLOW_PATH" >/dev/null; then
  echo "Old knowledge document cleanup must not force-delete shared documents." >&2
  exit 1
fi
jq -e '.nodes[] | select(.name == "Log Bot Event") | .parameters.query | contains("INSERT INTO bot_events")' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Log Bot Event") | .continueOnFail == true' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Create ElevenLabs Agent") | .continueOnFail == true' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Patch ElevenLabs Agent") | .continueOnFail == true' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Create Knowledge Document") | .continueOnFail == true' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Save Agent Update") | .continueOnFail == true' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Delete Old Knowledge Document") | .continueOnFail == true' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Filter Patch Agent Success") | .parameters.jsCode | contains("$json.error")' "$WORKFLOW_PATH" >/dev/null
jq -e '.connections["Patch ElevenLabs Agent"].main[0] | map(.node) | index("Save Agent Update") | not' "$WORKFLOW_PATH" >/dev/null
jq -e '.connections["Save Agent Update"].main[0] | map(.node) | index("Prepare Old Knowledge Deletion") | not' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Filter Create Agent Success") | .parameters.jsCode | contains("agent_id")' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Filter Save Agent Update Success") | .parameters.jsCode | contains("telegramUserId")' "$WORKFLOW_PATH" >/dev/null
jq -e '.connections["Filter Patch Agent Failure"].main[0] | map(.node) | index("Set Dialog State") | not' "$WORKFLOW_PATH" >/dev/null
jq -e '.connections["Filter Patch Agent Failure"].main[0] | map(.node) | index("Build Telegram Plain Reply")' "$WORKFLOW_PATH" >/dev/null
jq -e '.nodes[] | select(.name == "Filter Save Agent Update Failure") | .parameters.jsCode | contains("missingExpectedRow")' "$WORKFLOW_PATH" >/dev/null

echo "Telegram ElevenLabs workflow validation passed."
