#!/usr/bin/env bash
# Extract the Java RCS distribution (/opt/openicf) from the official public
# image into rcs/openicf/ (gitignored — Ping-licensed software, never
# committed; see NOTICE.md). No Docker needed: talks to the registry API
# directly. The files under /opt/openicf are architecture-neutral (jars,
# scripts, config); the image's own JDK is not extracted — the host JDK 21
# runs it.
#
# Usage: rcs/fetch-rcs.sh [tag]      (default tag below; re-run replaces rcs/openicf/)
set -euo pipefail
cd "$(dirname "$0")"

TAG="${1:-1.5.20.36}"
REPO="forgerock-io/rcs"
REG="https://gcr.io"
ACCEPT='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'

token=$(curl -fsS "$REG/v2/token?scope=repository:$REPO:pull" | jq -r .token)
get() { curl -fsSL -H "Authorization: Bearer $token" -H "Accept: $ACCEPT" "$@"; }

manifest=$(get "$REG/v2/$REPO/manifests/$TAG")
# Multi-arch index → pick the linux/amd64 image manifest (the file tree is identical per arch).
if [[ $(jq -r '.manifests // empty | length' <<<"$manifest") != "" ]]; then
  digest=$(jq -r '.manifests[] | select(.platform.os=="linux" and .platform.architecture=="amd64") | .digest' <<<"$manifest")
  manifest=$(get "$REG/v2/$REPO/manifests/$digest")
fi

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/root"
for layer in $(jq -r '.layers[].digest' <<<"$manifest"); do
  get "$REG/v2/$REPO/blobs/$layer" -o "$work/layer.tgz"
  # Only opt/openicf is wanted; layers without it are skipped quietly.
  tar -xzf "$work/layer.tgz" -C "$work/root" opt/openicf 2>/dev/null || true
done
[[ -d "$work/root/opt/openicf/connectors" ]] || { echo "opt/openicf not found in $REPO:$TAG" >&2; exit 1; }

rm -rf openicf
mv "$work/root/opt/openicf" openicf
echo "rcs/openicf <- gcr.io/$REPO:$TAG ($(ls openicf/connectors | grep -c jar) connector jars)"
