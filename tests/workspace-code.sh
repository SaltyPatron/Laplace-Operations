#!/bin/bash
# workspace-code.sh (Laplace-Engine#61): the checkout puts each repository at its main under one directory that stays,
# again and again, taking only what the repository keeps; the ingest makes no reading unless the deployed
# workspace-code source says supersede.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd); s=$(mktemp -d); trap 'rm -rf "$s"' EXIT
fail(){ echo "workspace-code: $*" >&2; exit 1; }
git init -q --bare "$s/remote/Laplace-Wiki.git"; git init -q "$s/w"; printf 'one\n' > "$s/w/page.md"
git -C "$s/w" -c user.email=t@t -c user.name=t commit -qm one --allow-empty && git -C "$s/w" add page.md && git -C "$s/w" -c user.email=t@t -c user.name=t commit -qm page
git -C "$s/w" push -q "$s/remote/Laplace-Wiki.git" HEAD:main
export WORKSPACE_CODE=$s/tree WORKSPACE_CODE_REMOTE=$s/remote WORKSPACE_CODE_REPOS=Laplace-Wiki
bash "$here/workspace-code.sh" checkout >/dev/null
[ "$(cat "$s/tree/Laplace-Wiki/page.md")" = one ] || fail "the first checkout is not main"
printf 'two\n' > "$s/w/page.md"; git -C "$s/w" -c user.email=t@t -c user.name=t commit -qam two; git -C "$s/w" push -q "$s/remote/Laplace-Wiki.git" HEAD:main
touch "$s/tree/Laplace-Wiki/stray.o"
bash "$here/workspace-code.sh" checkout >/dev/null
[ "$(cat "$s/tree/Laplace-Wiki/page.md")" = two ] || fail "a second checkout did not move to main"
[ ! -e "$s/tree/Laplace-Wiki/stray.o" ] || fail "something the repository does not keep stayed"
! git -C "$s/tree/Laplace-Wiki" remote | grep -q . || fail "a remote (and its token) was written down"
mkdir -p "$s/recipes/workspace-code"; printf 'name workspace-code\n' > "$s/recipes/workspace-code/source"
out=$(LAPLACE_RECIPES=$s/recipes bash "$here/workspace-code.sh" ingest) || fail "the guard failed: $out"
grep -q 'does not say supersede' <<<"$out" || fail "a reading was made without supersede: $out"
echo "workspace-code: checked out at main and again, only what the repository keeps; no reading without supersede"