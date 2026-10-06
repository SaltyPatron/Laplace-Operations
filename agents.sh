#!/bin/bash
# The repositories' agents on this machine: one GitHub Actions runner per repository, all as $LAPLACE_AGENT_USER,
# separate from anyone's development environment. Declared in laplace.env; converged here; needs root for the user's
# directories, the services and the one right the Engine's runner has.
#
#   sudo ./agents.sh                    every repository of $LAPLACE_REPOS: directory, environment, runner, registration, service, rights
#   sudo ./agents.sh Laplace-postgres   one of them
#   sudo ./agents.sh status             each runner as this machine and as GitHub see it; and every repository of
#                                       $LAPLACE_GITHUB with a self-hosted workflow, so one without a runner here, or not
#                                       in LAPLACE_REPOS at all, is said loudly and the status fails
#   sudo ./agents.sh remove [REPO]      unregister and remove one, or all
#
# Each runner: $LAPLACE_AGENT_HOME/<repo>/{runner,work,build}. Its checkouts are its workflow's workspace under work/;
# its builds are under build/; the database, the dependencies and the data are the machine's, through the shared
# group setup.sh gives them. Registration needs a token from GitHub for each repository: gh, logged in as someone who
# administers them, fetches it; or LAPLACE_AGENT_TOKEN_<REPO with - as _>. Laplace-postgres, Laplace-Engine and
# Laplace-Operations check out the repositories they build beside themselves; a workflow's own token reads only its
# repository, so the operator's gh credential (or LAPLACE_CHECKOUT_TOKEN) is put in those as the secret
# LAPLACE_CHECKOUT. What was done is kept under $LAPLACE_WORK/logs/root.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); . "$here/laplace.env"
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
op=${SUDO_USER:-$(id -un)}; user=$LAPLACE_AGENT_USER; group=$LAPLACE_GROUP; home=$LAPLACE_AGENT_HOME; owner=$LAPLACE_GITHUB
mkdir -p "$LAPLACE_WORK/logs/root"; log=$LAPLACE_WORK/logs/root/agents-$(date -u +%Y%m%dT%H%M%SZ).log; exec > >(tee "$log") 2>&1
say(){ printf '  %-46s %s\n' "$1" "$2"; }
part(){ echo; echo "=== $1   $(date -u +%H:%M:%S)"; }
as_agent(){ su -s /bin/bash "$user" -c "$*" </dev/null; }
as_op(){ su -s /bin/bash "$op" -c "$*" </dev/null; }
gh_op(){ as_op "gh $*"; }

# the runner's release, once per run
runner_version(){ [ -n "${RUNNER_VERSION:-}" ] || RUNNER_VERSION=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p'); echo "$RUNNER_VERSION"; }

# ---------------------------------------------------------------------------------------------- one repository
agent(){ repo=$1; part "$repo"
  id "$user" >/dev/null 2>&1 || { echo "no user $user: sudo ./setup.sh packages first"; exit 1; }
  gh_op "api repos/$owner/$repo --jq .name" >/dev/null 2>&1 || { say "$owner/$repo" "NOT ON GITHUB: gh repo create $owner/$repo --private --source $LAPLACE_SRC/$repo --push, then again"; return; }
  d=$home/$repo; r=$d/runner
  # the directories: the agent's, the shared group's, group-writable, so the operator reads its logs and builds
  install -d -o "$user" -g "$group" -m 2775 "$home" "$d" "$r" "$d/work" "$d/build"
  # the environment every job on this runner gets (the runner reads .env at its root): its own builds and work, the
  # machine's dependencies and data; its checkouts are the workspace, which the workflow names as LAPLACE_SRC.
  # Not the database: that is laplace.env's alone, so a job reads the one name every operator reads
  cat > "$r/.env" <<EOF
LAPLACE_BUILD=$d/build
LAPLACE_WORK=$d/work
LAPLACE_DEPSRC=$LAPLACE_DEPSRC
LAPLACE_BLAKE3_DIR=$LAPLACE_BLAKE3_DIR
LAPLACE_COREMATH=$LAPLACE_COREMATH
LAPLACE_TREESITTER=$LAPLACE_TREESITTER
LAPLACE_DEPS=$LAPLACE_DEPS
LAPLACE_ICU_DIR=$LAPLACE_ICU_DIR
LAPLACE_DATA=$LAPLACE_DATA
LAPLACE_PG_DIR=$LAPLACE_PG_DIR
LAPLACE_TIER0=$LAPLACE_WORK/tier0/tier0.bin
LAPLACE_GRAMMARS=$LAPLACE_BUILD/grammars
EOF
  chown "$user:$group" "$r/.env"; say "environment" "$r/.env"
  # the runner's release
  if [ ! -x "$r/config.sh" ]; then
    v=$(runner_version)
    curl -fsSL -o "$r/runner.tgz" "https://github.com/actions/runner/releases/download/v$v/actions-runner-linux-x64-$v.tar.gz"
    chown "$user:$group" "$r/runner.tgz"; as_agent "tar xzf $r/runner.tgz -C $r"; rm -f "$r/runner.tgz"
    "$r/bin/installdependencies.sh" >/dev/null 2>&1 || true
    say "runner" "$v unpacked"
  else say "runner" "$(cat "$r/bin/Runner.Listener.deps.json" 2>/dev/null | sed -n 's/.*"Runner.Listener\/\([0-9.]*\)".*/\1/p' | head -1) present"; fi
  # registered with its repository, named for this machine, labelled with the repository
  name=$(hostname)-$repo
  if [ ! -f "$r/.runner" ]; then
    var=LAPLACE_AGENT_TOKEN_$(echo "$repo" | tr - _); token=${!var:-}
    [ -n "$token" ] || token=$(gh_op "api -X POST repos/$owner/$repo/actions/runners/registration-token --jq .token" 2>/dev/null || true)
    if [ -z "$token" ]; then say "registration" "NO TOKEN: gh auth login as an administrator of $owner/$repo, or $var=..., and run again"; return; fi
    as_agent "cd $r && ./config.sh --unattended --url https://github.com/$owner/$repo --token $token --name $name --labels $LAPLACE_AGENT_LABELS,$repo --work $d/work --replace" >/dev/null
    say "registration" "$name on $owner/$repo, labels $LAPLACE_AGENT_LABELS,$repo"
  else say "registration" "$(sed -n 's/.*"agentName": *"\([^"]*\)".*/\1/p' "$r/.runner") on $owner/$repo"; fi
  # its service
  ( cd "$r"; [ -f .service ] || ./svc.sh install "$user" >/dev/null; ./svc.sh status 2>/dev/null | grep -q "active (running)" || ./svc.sh start >/dev/null )
  say "service" "$(cat "$r/.service" 2>/dev/null)   $(cd "$r" && ./svc.sh status 2>/dev/null | grep -o 'active ([a-z]*)' | head -1)"
  # its rights: none. An agent never has root: what needs root is setup.sh, run by a person (setup.sh rights says so for
  # every agent, and removes what said otherwise). Its unit is root's and read-only, so no member of the group edits it.
  unit=$(cat "$r/.service" 2>/dev/null); [ -n "$unit" ] && [ -f "/etc/systemd/system/$unit" ] && { chown root:root "/etc/systemd/system/$unit"; chmod 644 "/etc/systemd/system/$unit"; }
  rm -f /etc/sudoers.d/laplace-agent
  say "rights" "none: root is setup.sh's, run by a person; unit root's, 644"
  # the secret that reads the private repositories it checks out beside itself
  # (Laplace-Native too: it checks out Laplace-Operations, and every code repository's main sends Laplace-Operations the
  # repository_dispatch that deploys this machine with it)
  case $repo in Laplace-Native|Laplace-postgres|Laplace-Engine|Laplace-Operations)
    if gh_op "secret list -R $owner/$repo" 2>/dev/null | grep -q "^LAPLACE_CHECKOUT"; then say "secret LAPLACE_CHECKOUT" "set"
    else tok=${LAPLACE_CHECKOUT_TOKEN:-$(gh_op "auth token" 2>/dev/null || true)}              # the operator's own gh credential reads them
      if [ -n "$tok" ]; then as_op "gh secret set LAPLACE_CHECKOUT -R $owner/$repo -b '$tok'" >/dev/null && say "secret LAPLACE_CHECKOUT" "set from the operator's gh login"
      else say "secret LAPLACE_CHECKOUT" "NOT SET: gh auth login, and run again"; fi; unset tok; fi ;;
  esac
}
status(){ part status; local missing=0 r repo local_state remote wf
  for repo in $LAPLACE_REPOS; do r=$home/$repo/runner
    local_state=$( [ -f "$r/.runner" ] && (cd "$r" && ./svc.sh status 2>/dev/null | grep -o 'active ([a-z]*)' | head -1) || echo "not registered")
    remote=$(gh_op "api repos/$owner/$repo/actions/runners --jq '.runners[] | select(.name == \"$(hostname)-$repo\") | .status + \", busy \" + (.busy|tostring)'" 2>/dev/null || echo "not seen")
    say "$repo" "here: ${local_state:-stopped}   GitHub: ${remote:-not registered}"
    case "$local_state $remote" in *"active (running)"*online*) ;; *) [ -z "$(selfhosted "$repo")" ] || { missing=1; say "  MISSING" "$repo has self-hosted workflows ($(selfhosted "$repo" | tr '
' ' ')) and no runner online here: sudo ./agents.sh $repo"; } ;; esac
  done
  # every repository of the owner with a self-hosted workflow must be declared: one that is not has no runner anywhere
  for repo in $(gh_op "repo list $owner --limit 200 --no-archived --json name --jq '.[].name'" 2>/dev/null); do
    echo " $LAPLACE_REPOS " | grep -q " $repo " && continue
    wf=$(selfhosted "$repo"); [ -n "$wf" ] || continue
    if echo " ${LAPLACE_REPOS_RETIRED:-} " | grep -q " $repo "; then say "  retired" "$owner/$repo has self-hosted workflows ($(echo "$wf" | tr '
' ' ')); LAPLACE_REPOS_RETIRED: no runner"; continue; fi
    missing=1; say "  NOT DECLARED" "$owner/$repo has self-hosted workflows ($(echo "$wf" | tr '
' ' ')): add it to LAPLACE_REPOS (laplace.env), then sudo ./agents.sh $repo"
  done
  [ "$missing" = 0 ] && say "every repository" "with a self-hosted workflow has its runner" || say "RUNNERS MISSING" "see above"
  return $missing
}
# the workflows of a repository whose jobs run on a self-hosted runner (their file names), from GitHub
selfhosted(){ local f c
  for f in $(gh_op "api repos/$owner/$1/contents/.github/workflows --jq '.[].path'" 2>/dev/null); do
    c=$(gh_op "api repos/$owner/$1/contents/$f --jq .content" 2>/dev/null | base64 -d 2>/dev/null) || true
    if grep -q 'runs-on:.*self-hosted' <<<"$c"; then basename "$f"; fi; done; }
remove(){ repo=$1; part "remove $repo"; r=$home/$repo/runner
  [ -d "$r" ] || { say "$repo" "nothing here"; return; }
  ( cd "$r"; [ -f .service ] && { ./svc.sh stop >/dev/null 2>&1 || true; ./svc.sh uninstall >/dev/null 2>&1 || true; } )
  if [ -f "$r/.runner" ]; then
    token=$(gh_op "api -X POST repos/$owner/$repo/actions/runners/remove-token --jq .token" 2>/dev/null || true)
    [ -n "$token" ] && as_agent "cd $r && ./config.sh remove --token $token" >/dev/null && say "registration" "removed from $owner/$repo" || say "registration" "could not unregister: remove $(hostname)-$repo on GitHub"
  fi
  rm -rf "${home:?}/${repo:?}"; say "$repo" "removed"
}

case ${1:-all} in
  all)     for repo in $LAPLACE_REPOS; do agent "$repo"; done; rc=0; status || rc=$? ;;
  status)  rc=0; status || rc=$? ;;
  remove)  shift; for repo in ${*:-$LAPLACE_REPOS}; do remove "$repo"; done ;;
  *)       for repo in "$@"; do echo " $LAPLACE_REPOS " | grep -q " $repo " || { echo "$repo is not in LAPLACE_REPOS"; exit 2; }; agent "$repo"; done; rc=0; status || rc=$? ;;
esac
echo; echo "=== done   $(date -u +%H:%M:%S)   $log"
exit ${rc:-0}
