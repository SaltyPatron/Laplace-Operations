#!/bin/bash
# workspace-code after a deployment (.github/workflows/workspace-code.yml, Laplace-Engine#61).
#   workspace-code.sh checkout   each repository the workspace-code source reads, at its main, under $WORKSPACE_CODE
#   workspace-code.sh ingest     workspace-code read from there by the deployed program and recipes (ingest.sh)
# WORKSPACE_CODE_REPOS: the repositories, when not the ones workspace-code reads (tests).
# WORKSPACE_CODE: where the repositories are kept, the same directory every run (a file's pathname is part of what is
# read); default $GITHUB_WORKSPACE/workspace-code. The deployment's checkouts beside this repository are left alone:
# the recipes, Native and firmware read are theirs, as the deployment left them.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
deployed=$(cd "$here/.." && pwd)                                   # what the deployment checked out: Laplace-Engine, ...
tree=${WORKSPACE_CODE:-${GITHUB_WORKSPACE:-$deployed}/workspace-code}
repos="Laplace Laplace-Native Laplace-postgres Laplace-Engine Laplace-MCP Laplace-UCI Laplace-Operations Laplace-Wiki Laplace-Conventional"
case ${1:-} in
  checkout)
    # WORKSPACE_CODE_REMOTE: where the repositories are fetched from, REMOTE/NAME.git (tests: local repositories)
    if [ -z "${WORKSPACE_CODE_REMOTE:-}" ]; then : "${GH_TOKEN:?the checkout token}" "${OWNER:?the owner of the repositories}"; fi
    remote=${WORKSPACE_CODE_REMOTE:-https://x-access-token:${GH_TOKEN:-}@github.com/${OWNER:-}}
    mkdir -p "$tree"
    for r in ${WORKSPACE_CODE_REPOS:-$repos}; do
      d=$tree/$r; url="$remote/$r.git"
      [ -d "$d/.git" ] || git init -q "$d"                       # no remote kept: the token is given to each fetch, never written down
      git -C "$d" -c credential.helper= fetch -q --depth 1 "$url" main
      git -C "$d" checkout -q --detach --force FETCH_HEAD
      git -C "$d" clean -q -ffdx                                   # only what the repository keeps: this tree is the runner's, never edited
      echo "$r $(git -C "$d" rev-parse --short HEAD)"
    done ;;
  ingest)
    [ -d "$tree" ] || { echo "no workspace at $tree: workspace-code.sh checkout first" >&2; exit 1; }
    # the deployment's program, recipes, Native and firmware; only the workspace the source reads is this tree
    export LAPLACE_RECIPES=${LAPLACE_RECIPES:-$deployed/Laplace-Engine/recipes}
    export LAPLACE_FIRMWARE=${LAPLACE_FIRMWARE:-$deployed/Laplace-Engine/firmware/program.firmware}
    export LAPLACE_NATIVE=${LAPLACE_NATIVE:-$deployed/Laplace-Native} LAPLACE_DEPSRC=${LAPLACE_DEPSRC:-${LAPLACE_SRC:-/repos/src}}
    if ! grep -qx 'supersede' "$LAPLACE_RECIPES/workspace-code/source"; then
      echo "the deployed workspace-code source does not say supersede: a reading would be kept beside the ones before it, so none is made"
      exit 0
    fi
    LAPLACE_SRC=$tree exec "$here/ingest.sh" workspace-code ;;
  *) echo "usage: workspace-code.sh checkout|ingest" >&2; exit 2 ;;
esac