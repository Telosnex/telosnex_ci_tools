#!/usr/bin/env bash
# The Gradle distributions of a checkout's Android apps, for
# actions/android-emulator and actions/android-test-apks.
#
#   gradle_distributions.sh list <pathspecs> <list file>
#     Writes "<distributionUrl> <distributionSha256Sum>" lines of the
#     gradle-wrapper.properties files that the Git pathspecs (one per line)
#     name, and prints key=<cache key> for GITHUB_OUTPUT if there are any.
#   gradle_distributions.sh download <list file>
#     Downloads and unpacks each distribution where the Gradle wrapper looks
#     for it, with retries.
#
# The Gradle wrapper downloads its distribution from GitHub releases with
# no retry: a 504 there failed flutter_local_notifications and
# receive_sharing_intent (2026-11-08).
set -euo pipefail

case "${1:-}" in
  list)
    specs=$2 list=$3
    : > "$list"
    pathspecs=()
    while IFS= read -r spec; do [[ -n "$spec" ]] && pathspecs+=("$spec"); done <<< "$specs"
    if (( ${#pathspecs[@]} )) && git rev-parse --git-dir > /dev/null 2>&1; then
      git ls-files -z -- "${pathspecs[@]}" | while IFS= read -r -d '' f; do
        # The last value of a key counts, as in Java properties.
        url=$(sed -nE 's/^distributionUrl=//p' "$f" | tail -1 | sed 's/\\:/:/g' | tr -d '\r')
        sha=$(sed -nE 's/^distributionSha256Sum=//p' "$f" | tail -1 | tr -d '\r')
        [[ -n "$url" ]] && echo "$url $sha" >> "$list"
      done
    fi
    sort -u -o "$list" "$list"
    if [[ -s "$list" ]]; then
      echo "key=gradle-dists-$RUNNER_OS-$(sha256sum "$list" | cut -c1-16)"
      { echo "Gradle distributions:"; sed 's/^/  /' "$list"; } >&2
    fi
    ;;
  download)
    list=$2
    dists="${GRADLE_USER_HOME:-$HOME/.gradle}/wrapper/dists"
    while read -r url sha; do
      zip=${url##*/}
      # The wrapper's folder: <zip name>/<MD5 of the URL in base 36>.
      hash=$(python3 -c 'import hashlib,sys
n=int(hashlib.md5(sys.argv[1].encode()).hexdigest(),16); s=""
while n: n,r=divmod(n,36); s="0123456789abcdefghijklmnopqrstuvwxyz"[r]+s
print(s)' "$url")
      dir="$dists/${zip%.zip}/$hash"
      if [[ -f "$dir/$zip.ok" ]]; then echo "$zip: cached"; continue; fi
      mkdir -p "$dir"
      if ! curl -fsSL --retry 6 --retry-all-errors --retry-delay 20 -o "$dir/$zip" "$url"; then
        echo "::warning::$url did not download; the Gradle wrapper tries again itself."
        rm -rf "$dir"; continue
      fi
      if [[ -n "$sha" && "$(sha256sum "$dir/$zip" | cut -d' ' -f1)" != "$sha" ]]; then
        echo "::warning::$zip does not have the SHA-256 of its gradle-wrapper.properties."
        rm -rf "$dir"; continue
      fi
      unzip -q "$dir/$zip" -d "$dir"
      touch "$dir/$zip.ok"
      echo "$zip: downloaded"
    done < "$list"
    ;;
  *)
    echo "usage: gradle_distributions.sh list <pathspecs> <list file> | download <list file>" >&2
    exit 64
    ;;
esac
