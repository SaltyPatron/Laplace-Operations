#!/usr/bin/env bash
# PowerShell for a job on this repository's own Linux runner, which has none installed and no root.
# The pinned upstream archive is verified and unpacked once into the runner's tool cache; later jobs reuse it.
set -euo pipefail
version=7.7.0
sha256=c89d9c682d2c403dfe726f3df948e359675235a5bd6fab535776de69729ca0cb
: "${RUNNER_TOOL_CACHE:?}" "${RUNNER_TEMP:?}" "${GITHUB_PATH:?}"
[[ $(uname -s)-$(uname -m) == Linux-x86_64 ]] || { echo 'provide-pwsh.sh supports Linux x86_64 runners only' >&2; exit 2; }
home="$RUNNER_TOOL_CACHE/pwsh/$version/x64"
if [[ ! -x "$home/pwsh" || $(cat "$home/.archive-sha256" 2>/dev/null) != "$sha256" ]]; then
  archive=$(mktemp "$RUNNER_TEMP/powershell.XXXXXXXX")
  next=$(mktemp -d "$RUNNER_TEMP/pwsh.XXXXXXXX")
  trap 'rm -rf -- "$archive" "$next"' EXIT
  curl --fail --silent --show-error --location --retry 3 -o "$archive" \
    "https://github.com/PowerShell/PowerShell/releases/download/v$version/powershell-$version-linux-x64.tar.gz"
  printf '%s  %s\n' "$sha256" "$archive" | sha256sum --check --status
  tar -xzf "$archive" -C "$next"
  chmod +x "$next/pwsh"
  printf '%s\n' "$sha256" > "$next/.archive-sha256"
  rm -rf -- "$home"
  mkdir -p "$(dirname "$home")"
  mv -T -- "$next" "$home"
fi
"$home/pwsh" -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
echo "$home" >> "$GITHUB_PATH"
