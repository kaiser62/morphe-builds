#!/usr/bin/env bash
# Build one app into dist/. Usage: build.sh <id> <package> <patches-repo[,fallback-repo...]> [extra patch args] [github-source] [arch|any]
# Reuses the APK from the previous release when app version + patches version are unchanged.
# Writes dist/<id>.apk-name and dist/<id>.json (metadata used for release notes and state).
set -euo pipefail
id=$1 pkg=$2 repos=$3 args=${4:-} src=${5:-} arch=${6:-arm64-v8a}
root=$PWD
mkdir -p "work/$id/in" dist && cd "work/$id"

reuse() { # $1 = version; succeed if previous release already has this exact build
  local key="$1|$repo|$ptag|$args"
  [ -f "$root/prev/state.json" ] || return 1
  [ "$(jq -r --arg i "$id" '.[$i].key // empty' "$root/prev/state.json")" = "$key" ] || return 1
  local file; file=$(jq -r --arg i "$id" '.[$i].file' "$root/prev/state.json")
  gh release download "$PREV_TAG" -p "$file" -D "$root/dist" --clobber || return 1
  jq --arg i "$id" '.[$i] + {changed:false}' "$root/prev/state.json" > "$root/dist/$id.json"
  echo "$id $1 unchanged, reusing $file from $PREV_TAG"
}

# Patch sources in preference order; fall through when none of a source's supported versions can be downloaded
for repo in ${repos//,/ }; do
ptag=$(gh release view -R "$repo" --json tagName -q .tagName)
gh release download "$ptag" -R "$repo" -p '*.mpp' -O patches.mpp --clobber

# Patch names + descriptions for this package (JSON array)
java -jar "$root/morphe.jar" list-patches --patches=patches.mpp -f "$pkg" 2>/dev/null \
  | awk '/^Name: /{n=substr($0,7)} /^Description: /{d=substr($0,14); if(d=="null")d=""; print n "\t" d}' \
  | jq -R -s 'split("\n") | map(select(length>0) | split("\t") | {name:.[0], desc:(.[1] // "")})' > all-patches.json

# App versions the patches support for this package, newest first (empty = any version)
vers=$(java -jar "$root/morphe.jar" list-patches --patches=patches.mpp -p -v -f "$pkg" 2>/dev/null \
  | awk -v p="$pkg" '/Package name:/ {cur=$3} /^\t\t[0-9]/ && cur==p {gsub(/[ \t]/,""); sub(/:.*/,""); print}' \
  | sort -urV)
echo "$id: patches $repo@$ptag, supported versions: ${vers:-any}"

# Try supported versions newest first until one downloads
ver=
for v in ${vers:-latest}; do
  [ "$v" != latest ] && reuse "$v" && exit 0
  [ "$v" = latest ] && a=$pkg || a=$pkg@$v
  # Optional official GitHub source "owner/repo:asset-glob", release tag = app version
  if [ -n "$src" ]; then
    [ "$v" = latest ] && t= || t=$v
    gh release download $t -R "${src%%:*}" -p "${src#*:}" -D in || true
  fi
  [ "$arch" = any ] || { ls in/* >/dev/null 2>&1 || "$root/apkeep" -a "$a" -d apk-pure -o "acknowledge_dangers=true,arch=$arch" in || true; }
  # Some apps ship one universal APK with no arch variant
  ls in/* >/dev/null 2>&1 || "$root/apkeep" -a "$a" -d apk-pure -o acknowledge_dangers=true in || true
  if ls in/* >/dev/null 2>&1; then ver=$v; break; fi
  echo "$a not available, trying older"
done
[ -n "$ver" ] && break
echo "$repo: no supported version downloadable, trying next patch source"
done
f=$(ls in/* 2>/dev/null | head -n1) || true
[ -n "$f" ] || { echo "No supported version of $pkg downloadable"; exit 1; }
if [ "$ver" = latest ]; then
  case $f in
    *@*) ver=$(basename "$f" | sed -E 's/^[^@]+@([^@]+)(@.*)?\.x?apk$/\1/') ;;
    *) ver=$(gh release view -R "${src%%:*}" --json tagName -q .tagName) ;;
  esac
  reuse "$ver" && exit 0
fi

name="$id-$ver.apk"
sign=(--keystore="$KEYSTORE" --keystore-password="$KEYSTORE_PASSWORD"
      --keystore-entry-alias=Morphe --keystore-entry-password="$KEYSTORE_PASSWORD")
patch() { # shellcheck disable=SC2086
  java -jar "$root/morphe.jar" patch --patches=patches.mpp --continue-on-error $args "${sign[@]}" -o "$name" "$1" 2>&1 | tee patch.log
  return "${PIPESTATUS[0]}"
}
if ! patch "$f"; then
  echo "Direct patch failed, merging splits"
  java -jar "$root/apkeditor.jar" m -i "$f" -o merged.apk
  patch merged.apk
fi

aapt2=$(ls "$ANDROID_HOME"/build-tools/*/aapt2 | tail -n1)
badging=$("$aapt2" dump badging "$name")
final_pkg=$(sed -nE "s/^package: name='([^']+)'.*/\1/p" <<<"$badging")
min_sdk=$(sed -nE "s/^minSdkVersion:'([0-9]+)'.*/\1/p" <<<"$badging")

grep -oP 'Applied: \K.*' patch.log | jq -R -s 'split("\n") | map(select(length>0))' > applied.json
failed=$(grep -c 'FAILED: ' patch.log || true)
if [ "$failed" -gt "$(jq length applied.json)" ]; then
  echo "::error::$id: $failed patches failed, only $(jq length applied.json) applied; not publishing"; exit 1
fi
mv "$name" "$root/dist/"
jq -n --arg id "$id" --arg pkg "$final_pkg" --arg ver "$ver" --arg repo "$repo" --arg ptag "$ptag" \
  --arg file "$name" --arg min "$min_sdk" --arg args "$args" --slurpfile all all-patches.json --slurpfile applied applied.json \
  '{id:$id, pkg:$pkg, ver:$ver, repo:$repo, ptag:$ptag, file:$file, minSdk:$min, changed:true,
    key:($ver+"|"+$repo+"|"+$ptag+"|"+$args),
    patches:[ $applied[0][] as $n | {name:$n, desc:(first($all[0][] | select(.name==$n) | .desc) // "")} ]}' \
  > "$root/dist/$id.json"
echo "$id $ver built with $(jq length applied.json) patches"
