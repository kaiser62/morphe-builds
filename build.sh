#!/usr/bin/env bash
# Build one app. Usage: build.sh <id> <package> <patches-repo> [extra patch args]
# Skips if a release for the same app version + patches version already exists.
set -euo pipefail
id=$1 pkg=$2 repo=$3 args=${4:-}
mkdir -p "work/$id" out && cd "work/$id"

ptag=$(gh release view -R "$repo" --json tagName -q .tagName)
gh release download "$ptag" -R "$repo" -p '*.mpp' -O patches.mpp --clobber

# Newest app version the patches support (empty = any version)
ver=$(java -jar ../../morphe.jar list-patches --patches=patches.mpp -p -v -f "$pkg" 2>/dev/null \
  | grep -oE '^\s+[0-9]+(\.[0-9]+)+' | tr -d ' \t' | sort -uV | tail -n1 || true)
echo "$id: patches $repo@$ptag, app version ${ver:-latest}"

dl=(-d apk-pure -o 'acknowledge_dangers=true,arch=arm64-v8a')
../../apkeep -a "$pkg${ver:+@$ver}" "${dl[@]}" in
f=$(ls in/* | head -n1)
[ -n "$ver" ] || ver=$(basename "$f" | sed -E 's/.*@([^@]+)@.*/\1/; s/.*@([^@]+)\.(x?apk)$/\1/')

tag="$id-v$ver-${repo%%/*}-$ptag"
if gh release view "$tag" >/dev/null 2>&1; then echo "$tag exists, skipping"; exit 0; fi

name="$id-$ver-morphe.apk"
# shellcheck disable=SC2086
if ! java -jar ../../morphe.jar patch --patches=patches.mpp $args -o "$name" "$f"; then
  echo "Direct patch failed, merging splits"
  java -jar ../../apkeditor.jar m -i "$f" -o merged.apk
  # shellcheck disable=SC2086
  java -jar ../../morphe.jar patch --patches=patches.mpp $args -o "$name" merged.apk
fi

aapt2=$(ls "$ANDROID_HOME"/build-tools/*/aapt2 | tail -n1)
info=$("$aapt2" dump badging "$name" | grep -iE "^package:|sdkVersion:|native-code" || true)

gh release create "$tag" "$name" --title "$id $ver ($repo $ptag)" \
  --notes "$(printf 'Patches: %s %s\n\n```\n%s\n```' "$repo" "$ptag" "$info")"
