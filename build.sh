#!/usr/bin/env bash
# Build one app. Usage: build.sh <id> <package> <patches-repo> [extra patch args]
# Skips if a release for the same app version + patches version already exists.
set -euo pipefail
id=$1 pkg=$2 repo=$3 args=${4:-}
mkdir -p "work/$id/in" && cd "work/$id"

ptag=$(gh release view -R "$repo" --json tagName -q .tagName)
gh release download "$ptag" -R "$repo" -p '*.mpp' -O patches.mpp --clobber

# App versions the patches support for this package, newest first (empty = any version)
vers=$(java -jar ../../morphe.jar list-patches --patches=patches.mpp -p -v -f "$pkg" 2>/dev/null \
  | awk -v p="$pkg" '/Package name:/ {cur=$3} /^\t\t[0-9]/ && cur==p {gsub(/[ \t]/,""); sub(/:.*/,""); print}' \
  | sort -urV)
echo "$id: patches $repo@$ptag, supported versions: ${vers:-any}"

# Try supported versions newest first until APKPure has one
dl=(-d apk-pure -o 'acknowledge_dangers=true,arch=arm64-v8a')
ver=
for v in ${vers:-latest}; do
  [ "$v" = latest ] && a=$pkg || a=$pkg@$v
  ../../apkeep -a "$a" "${dl[@]}" in || true
  # Some apps ship one universal APK with no arch variant
  ls in/* >/dev/null 2>&1 || ../../apkeep -a "$a" -d apk-pure -o acknowledge_dangers=true in || true
  if ls in/* >/dev/null 2>&1; then ver=$v; break; fi
  echo "$a not available, trying older"
done
f=$(ls in/* 2>/dev/null | head -n1) || true
[ -n "$f" ] || { echo "No supported version of $pkg downloadable"; exit 1; }
[ "$ver" != latest ] || ver=$(basename "$f" | sed -E 's/^[^@]+@([^@]+)(@.*)?\.x?apk$/\1/')

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
