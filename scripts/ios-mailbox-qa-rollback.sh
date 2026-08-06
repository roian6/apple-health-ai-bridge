#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${HEALTH_BRIDGE_PRODUCTION_SEAL:?set the caller-private production seal}"
: "${HEALTH_BRIDGE_PRODUCTION_SEAL_ANCHOR_SHA256:?set the private seal public-key anchor}"
: "${HEALTH_BRIDGE_QA_DEVICE_IDENTIFIER:?set the explicit QA device identifier}"
: "${HEALTH_BRIDGE_QA_BUNDLE_IDENTIFIER:?set the exact QA bundle identifier}"
: "${HEALTH_BRIDGE_QA_ICLOUD_CONTAINER_IDENTIFIER:?set the exact QA iCloud container}"
: "${HEALTH_BRIDGE_QA_KEYCHAIN_SERVICE:?set the exact QA Keychain service}"
: "${HEALTH_BRIDGE_QA_KEYCHAIN_ACCESS_GROUP:?set the exact QA Keychain access group}"
: "${HEALTH_BRIDGE_QA_OUTBOX_ROOT:?set the exact QA outbox root}"
: "${HEALTH_BRIDGE_QA_DISPLAY_IDENTITY:?set the exact QA display identity}"
: "${HEALTH_BRIDGE_QA_RECEIVER_PORT:?set the isolated QA receiver port}"
: "${HEALTH_BRIDGE_QA_RUNTIME_ROOT:?set the caller-private QA runtime root}"
: "${HEALTH_BRIDGE_QA_DATABASE_NAMESPACE:?set the QA DB namespace}"
: "${HEALTH_BRIDGE_QA_APP_PATH:?set the signed QA app path}"
: "${HEALTH_BRIDGE_QA_CLEANUP_OUTPUT:?set the copied QA cleanup output}"

rollback_tmp="$(mktemp -d)"
chmod 700 "$rollback_tmp"
trap 'rm -rf "$rollback_tmp"' EXIT
before="$rollback_tmp/apps-before.json"
after="$rollback_tmp/apps-after.json"
xcrun devicectl device info apps \
  --device "$HEALTH_BRIDGE_QA_DEVICE_IDENTIFIER" \
  --json-output "$before" >/dev/null
uv run python "$root_dir/scripts/production-identity-seal.py" confirm-install \
  --seal "$HEALTH_BRIDGE_PRODUCTION_SEAL" \
  --anchor-sha256 "$HEALTH_BRIDGE_PRODUCTION_SEAL_ANCHOR_SHA256" \
  --bundle-identifier "$HEALTH_BRIDGE_QA_BUNDLE_IDENTIFIER" \
  --container-identifier "$HEALTH_BRIDGE_QA_ICLOUD_CONTAINER_IDENTIFIER" \
  --url-scheme "healthbridgeqa" \
  --keychain-service "$HEALTH_BRIDGE_QA_KEYCHAIN_SERVICE" \
  --keychain-access-group "$HEALTH_BRIDGE_QA_KEYCHAIN_ACCESS_GROUP" \
  --outbox-root "$HEALTH_BRIDGE_QA_OUTBOX_ROOT" \
  --display-identity "$HEALTH_BRIDGE_QA_DISPLAY_IDENTITY" \
  --receiver-port "$HEALTH_BRIDGE_QA_RECEIVER_PORT" \
  --runtime-root "$HEALTH_BRIDGE_QA_RUNTIME_ROOT" \
  --database-namespace "$HEALTH_BRIDGE_QA_DATABASE_NAMESPACE" \
  --app-path "$HEALTH_BRIDGE_QA_APP_PATH" \
  --inventory "$before" >/dev/null
xcrun devicectl help device uninstall app >/dev/null
xcrun devicectl device uninstall app \
  --device "$HEALTH_BRIDGE_QA_DEVICE_IDENTIFIER" \
  "$HEALTH_BRIDGE_QA_BUNDLE_IDENTIFIER"
xcrun devicectl device info apps \
  --device "$HEALTH_BRIDGE_QA_DEVICE_IDENTIFIER" \
  --json-output "$after" >/dev/null
uv run python "$root_dir/scripts/production-identity-seal.py" confirm-rollback \
  --seal "$HEALTH_BRIDGE_PRODUCTION_SEAL" \
  --anchor-sha256 "$HEALTH_BRIDGE_PRODUCTION_SEAL_ANCHOR_SHA256" \
  --bundle-identifier "$HEALTH_BRIDGE_QA_BUNDLE_IDENTIFIER" \
  --container-identifier "$HEALTH_BRIDGE_QA_ICLOUD_CONTAINER_IDENTIFIER" \
  --url-scheme "healthbridgeqa" \
  --keychain-service "$HEALTH_BRIDGE_QA_KEYCHAIN_SERVICE" \
  --keychain-access-group "$HEALTH_BRIDGE_QA_KEYCHAIN_ACCESS_GROUP" \
  --outbox-root "$HEALTH_BRIDGE_QA_OUTBOX_ROOT" \
  --display-identity "$HEALTH_BRIDGE_QA_DISPLAY_IDENTITY" \
  --receiver-port "$HEALTH_BRIDGE_QA_RECEIVER_PORT" \
  --runtime-root "$HEALTH_BRIDGE_QA_RUNTIME_ROOT" \
  --database-namespace "$HEALTH_BRIDGE_QA_DATABASE_NAMESPACE" \
  --app-path "$HEALTH_BRIDGE_QA_APP_PATH" \
  --inventory "$after" \
  --cleanup-output "$HEALTH_BRIDGE_QA_CLEANUP_OUTPUT" >/dev/null
