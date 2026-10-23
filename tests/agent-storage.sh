#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:?build scratch required}/agent-storage.XXXXXX")
trap 'rm -rf "$work"' EXIT
source <(sed -n '/^agent_move_storage() {/,/^}/p' "$root/agents.sh")
mkdir -p "$work/old/work/source" "$work/old/build/output"
printf 'source content\n' > "$work/old/work/source/input"
printf 'build content\n' > "$work/old/build/output/result"
before=$(sha256sum "$work/old/work/source/input" | cut -d' ' -f1)
agent_move_storage "$work/old/work" "$work/declared-work/agents/Laplace"
agent_move_storage "$work/old/build" "$work/declared-build/agents/Laplace"
[[ -L "$work/old/work" && -L "$work/old/build" ]]
[[ $(sha256sum "$work/declared-work/agents/Laplace/source/input" | cut -d' ' -f1) == "$before" ]]
cmp "$work/old/build/output/result" "$work/declared-build/agents/Laplace/output/result"
agent_move_storage "$work/old/work" "$work/declared-work/agents/Laplace"
echo 'PASS data relocates to declared roots, old cache paths resolve, repeat does not duplicate data'
mkdir -p "$work/collision/old" "$work/collision/new"
printf 'original\n' > "$work/collision/old/input"
printf 'other\n' > "$work/collision/new/input"
if agent_move_storage "$work/collision/old" "$work/collision/new"; then echo 'merged conflicting storage trees'; exit 1; fi
[[ $(cat "$work/collision/old/input") == original && $(cat "$work/collision/new/input") == other ]]
echo 'PASS conflicting storage trees are refused without overwriting either'
