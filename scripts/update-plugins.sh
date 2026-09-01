#!/usr/bin/env bash
set -e

REPOS=(
  "jellyfish-p/cpa-plugin-antigravity-coding-filter|antigravity-coding-filter|zip"
  "ygq-future/antigravity-priority|antigravity-priority|zip"
  "Cody292/quota-activation|quota-activation|zip"
  "rheodev/cpa-plugin-privacyfilter|privacyfilter|zip"
  "zhangziming1124/cpa-apply-patch|cpa-apply-patch|so"
  "1296018244/grok-manager|grok-manager|so"
)

echo "{" > plugins.json
first=true

for entry in "${REPOS[@]}"; do
  IFS='|' read -r REPO NAME FORMAT <<< "$entry"
  echo "Fetching latest release for $REPO..."
  
  # Fetch latest release info
  API_URL="https://api.github.com/repos/$REPO/releases/latest"
  ASSETS=$(curl -s "$API_URL" | jq -c '.assets[]')
  
  if [ -z "$ASSETS" ] || [ "$ASSETS" = "null" ]; then
    echo "Failed to find assets for $REPO"
    continue
  fi
  
  if [ "$FORMAT" = "zip" ]; then
    # Find asset ending in _linux_amd64.zip
    URL=$(echo "$ASSETS" | jq -r '.browser_download_url' | grep "_linux_amd64.zip" | head -n 1)
    if [ -z "$URL" ]; then
      URL=$(echo "$ASSETS" | jq -r '.browser_download_url' | grep ".zip" | head -n 1)
    fi
    echo "  URL: $URL"
    # Download temporarily to compute sri hash (NAR format)
    HASH=$(nix run nixpkgs#nix-prefetch -- fetchzip --url "$URL" 2>/dev/null)
  else
    # Find asset ending in .so
    URL=$(echo "$ASSETS" | jq -r '.browser_download_url' | grep "\.so$" | head -n 1)
    echo "  URL: $URL"
    HASH=$(nix run nixpkgs#nix-prefetch -- fetchurl --url "$URL" 2>/dev/null)
  fi
  
  if [ "$first" = true ]; then
    first=false
  else
    echo "," >> plugins.json
  fi
  
  cat << JSON >> plugins.json
  "$NAME": {
    "url": "$URL",
    "hash": "$HASH",
    "format": "$FORMAT"
  }
JSON

done

echo "}" >> plugins.json
echo "Done! Updated plugins.json."
