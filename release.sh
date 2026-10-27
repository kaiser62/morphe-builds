#!/usr/bin/env bash
# Combine dist/*.json into state.json + release notes; publish one release with every APK if anything changed.
set -euo pipefail
cd dist
# Carry forward apps whose build failed this run, so the release always has every app
if [ -n "${PREV_TAG:-}" ] && gh release download "$PREV_TAG" -p state.json -O prev-state.json 2>/dev/null; then
  for i in $(jq -r --slurpfile a ../apps.json 'keys[] | select(. as $k | $a[0] | map(.id) | index($k))' prev-state.json); do
    [ -f "$i.json" ] && continue
    echo "$i failed this run, carrying forward from $PREV_TAG"
    jq --arg i "$i" '.[$i] + {changed:false}' prev-state.json > "$i.json"
    gh release download "$PREV_TAG" -p "$(jq -r .file "$i.json")" --clobber
  done
  rm prev-state.json
fi
jq -s 'map({(.id): .}) | add' ./*.json > state.json
changed=$(jq -r '[.[] | select(.changed) | .id] | join(", ")' state.json)
if [ -z "$changed" ] && [ "${FORCE:-false}" != true ]; then
  echo "Nothing changed, no release"; exit 0
fi

tag="builds-$(date -u +%Y.%m.%d-%H%M)"
{
  echo "Updated: **${changed:-none (forced)}**"
  echo
  echo "| App | Version | Package | Min Android SDK | Patches |"
  echo "|---|---|---|---|---|"
  jq -r 'to_entries[] | .value | "| \(.id)\(if .changed then " 🆕" else "" end) | \(.ver) | `\(.pkg)` | \(.minSdk) | [\(.repo) \(.ptag)](https://github.com/\(.repo)/releases/tag/\(.ptag)) |"' state.json
  echo
  echo "All APKs are arm64-v8a and signed with the same key, so they update in place."
  echo
  jq -r 'to_entries[] | .value |
    "<details><summary><b>\(.id) \(.ver)</b> — \(.patches | length) patches applied</summary>\n\n" +
    ([.patches[] | "- **\(.name)**" + (if .desc != "" then ": \(.desc)" else "" end)] | join("\n")) +
    "\n\n</details>\n"' state.json
} > notes.md

files=$(jq -r '.[].file' state.json)
# shellcheck disable=SC2086
gh release create "$tag" $files state.json --title "Morphe builds $(date -u +%Y-%m-%d)" --notes-file notes.md --latest
echo "Released $tag"
