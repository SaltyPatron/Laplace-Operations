"""Resolve one immutable component release from the version lock, preserving a dispatch's exact commit.

components.lock.tsv holds the revisions staging last deployed and verified. A deployment takes every component from
it; a component's main-merged dispatch replaces only that component's row (never moving it backwards); an operator's
dispatch with advance=true takes every component's main. After the deployment's tests pass, `write-lock` records the
verified set in the lock (laplace.yml commits it)."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

COMPONENTS = {'native': 'Laplace-Native', 'postgres': 'Laplace-postgres', 'engine': 'Laplace-Engine', 'mcp': 'Laplace-MCP', 'salty_suite': 'Salty-Suite'}
LOCK = Path(__file__).resolve().parents[2] / 'components.lock.tsv'


def read_lock(path=LOCK):
    revisions = {}
    for line in Path(path).read_text().splitlines():
        if not line.strip() or line.startswith('#'):
            continue
        fields = line.split('\t')
        if (len(fields) != 3 or fields[0] not in COMPONENTS or COMPONENTS[fields[0]] != fields[1]
                or fields[0] in revisions or not re.fullmatch(r'[0-9a-f]{40}', fields[2])):
            raise ValueError('Invalid version lock row: ' + line)
        revisions[fields[0]] = fields[2]
    if set(revisions) != set(COMPONENTS):
        raise ValueError('The version lock must name every component once: ' + ', '.join(sorted(COMPONENTS)))
    return revisions


def write_lock(revisions, path=LOCK):
    """Rewrite the lock's rows with revisions, keeping its header; True when anything changed."""
    if set(revisions) != set(COMPONENTS) or not all(re.fullmatch(r'[0-9a-f]{40}', v) for v in revisions.values()):
        raise ValueError('A lock names every component by a full commit')
    text = Path(path).read_text()
    header = [line for line in text.splitlines() if line.startswith('#')]
    rows = [f'{key}\t{name}\t{revisions[key]}' for key, name in COMPONENTS.items()]
    updated = '\n'.join(header + rows) + '\n'
    if updated == text:
        return False
    Path(path).write_text(updated)
    return True


def resolve(owner, event_name, event, request, lock):
    if not re.fullmatch(r'[A-Za-z0-9-]+', owner):
        raise ValueError('Invalid repository owner')
    payload = event.get('client_payload', {}) if event_name == 'repository_dispatch' else {}
    repository, triggering_sha = payload.get('repository'), payload.get('sha')
    inputs = event.get('inputs', {}) if event_name == 'workflow_dispatch' else {}
    pinned_engine = inputs.get('engine_revision')
    advance = str(inputs.get('advance', '')).lower() == 'true'
    if pinned_engine:
        repository, triggering_sha = f'{owner}/Laplace-Engine', pinned_engine
    if event_name == 'repository_dispatch' or pinned_engine:
        if repository not in [f'{owner}/{name}' for name in COMPONENTS.values()]:
            raise ValueError('Dispatch must name a declared component repository')
        if not isinstance(triggering_sha, str) or not re.fullmatch(r'[0-9a-f]{40}', triggering_sha):
            raise ValueError('Dispatch must identify a full commit SHA')
    revisions = {}
    for key, name in COMPONENTS.items():
        repo = f'{owner}/{name}'
        if repo == repository or advance:
            main = request(f'/repos/{repo}/commits/main')['sha']
            if not re.fullmatch(r'[0-9a-f]{40}', main):
                raise ValueError('GitHub returned an invalid main revision')
        if repo == repository:
            comparison = request(f'/repos/{repo}/compare/{triggering_sha}...{main}')
            if comparison['status'] not in ('ahead', 'identical'):
                raise ValueError('Triggering revision is not in the component main history')
            # A dispatch delivered after a later revision of the same component was verified does not move it back.
            behind = request(f'/repos/{repo}/compare/{lock[key]}...{triggering_sha}')['status'] == 'behind'
            revisions[key] = lock[key] if behind else triggering_sha
        elif advance:
            revisions[key] = main
        else:
            revisions[key] = lock[key]
    return revisions


def verified_native_run(owner, revision, request):
    return int(subprocess.check_output(['bash', Path(__file__).resolve().parents[2] / 'native-inputs.sh',
                                       'resolve', owner, revision], text=True).strip())


def qualify_engine(owner, revision, request, mutate, sleep=time.sleep, attempts=480):
    if not re.fullmatch(r'[A-Za-z0-9-]+', owner) or not re.fullmatch(r'[0-9a-f]{40}', revision):
        raise ValueError('Invalid Engine repository or revision')
    repository = f'/repos/{owner}/Laplace-Engine'
    workflow = repository + '/actions/workflows/laplace.yml'
    state = request(workflow)['state']
    print(f'Engine workflow state: {state}', flush=True)
    if state in ('disabled_manually', 'disabled_inactivity'):
        mutate(workflow + '/enable', 'PUT', None)
    elif state != 'active':
        raise ValueError('Engine workflow cannot run: ' + state)
    dispatched = False
    rerun_of = None  # (run id, attempt) whose failed jobs were run again once
    for _ in range(attempts):
        runs = request(repository + f'/actions/runs?head_sha={revision}&per_page=100')['workflow_runs']
        runs = [run for run in runs if run.get('head_sha') == revision
                and run.get('head_branch') == 'main' and run.get('path') == '.github/workflows/laplace.yml'
                and run.get('event') in ('push', 'workflow_dispatch')]
        if runs:
            run = max(runs, key=lambda item: item['id'])
            jobs = request(repository + f'/actions/runs/{run["id"]}/jobs?per_page=100')['jobs']
            engine = next((job for job in jobs if job['name'] == 'engine'), None)
            if engine and engine.get('conclusion') == 'success':
                print(f'Engine {revision} qualified: {run["html_url"]}', flush=True)
                return run['id']
            finished = (engine and engine.get('status') == 'completed') or run.get('status') == 'completed'
            # Engine cancels a run when a later push supersedes it: a cancelled run tested nothing, so it neither
            # qualifies the revision nor fails it. The revision is run again while it is still main.
            cancelled = 'cancelled' in ((engine or {}).get('conclusion'), run.get('conclusion'))
            attempt = run.get('run_attempt', 1)
            if rerun_of and rerun_of[0] == run['id'] and attempt <= rerun_of[1]:
                sleep(10)  # the rerun requested below has not started yet
                continue
            if finished and not cancelled:
                # A failure can be transient (a sibling's run not finished, a host lock): run the failed jobs once more.
                if rerun_of is None:
                    mutate(repository + f'/actions/runs/{run["id"]}/rerun-failed-jobs', 'POST', None)
                    print(f'Engine {revision} failed attempt {attempt} ({run["html_url"]}); running its failed jobs again',
                          flush=True)
                    rerun_of = (run['id'], attempt)
                    sleep(10)
                    continue
                raise ValueError(f'Engine build/test qualification failed (attempt {attempt}, after one rerun): '
                                 + run['html_url'])
            if cancelled and not dispatched:
                runs = []
        if not runs and not dispatched:
            if request(repository + '/commits/main')['sha'] != revision:
                # A later push superseded it (its run cancelled or never started): that push's own deployment
                # follows; this one has nothing to deploy.
                print(f'Engine {revision} is superseded on main and has no run of its own; this deployment yields',
                      flush=True)
                return None
            mutate(workflow + '/dispatches', 'POST', {'ref': 'main'})
            print(f'Dispatched required Engine build/tests for {revision}', flush=True)
            dispatched = True
        sleep(10)
    raise TimeoutError('Timed out waiting for Engine build/tests: ' + revision)


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == 'write-lock':
        # write-lock native=SHA postgres=SHA engine=SHA mcp=SHA: the set this deployment verified
        changed = write_lock(dict(argument.split('=', 1) for argument in sys.argv[2:]))
        print('version lock ' + ('advanced' if changed else 'unchanged'))
        return
    token = os.environ['GH_TOKEN']
    def request(path, method='GET', body=None):
        req = urllib.request.Request('https://api.github.com' + path, method=method,
            data=json.dumps(body).encode() if body is not None else None, headers={
            'Authorization': 'Bearer ' + token, 'Accept': 'application/vnd.github+json',
            'Content-Type': 'application/json', 'X-GitHub-Api-Version': '2022-11-28'})
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                return json.load(response) if response.status != 204 else {}
        except urllib.error.HTTPError as error:
            raise RuntimeError(f'GitHub {method} {path}: HTTP {error.code}: '
                               + error.read().decode(errors='replace')[:2000]) from error
    if len(sys.argv) == 3 and sys.argv[1] == 'qualify-engine':
        qualified = qualify_engine(os.environ['GITHUB_REPOSITORY_OWNER'], sys.argv[2], request, request)
        if os.environ.get('GITHUB_OUTPUT'):
            with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as output:
                output.write(f'superseded={"true" if qualified is None else "false"}\n')
        return
    revisions = resolve(os.environ['GITHUB_REPOSITORY_OWNER'], os.environ['GITHUB_EVENT_NAME'],
        json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text()), request, read_lock())
    revisions['native_run'] = verified_native_run(os.environ['GITHUB_REPOSITORY_OWNER'], revisions['native'], request)
    with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as output:
        for key, sha in revisions.items():
            output.write(f'{key}={sha}\n')
    print(json.dumps(revisions, indent=2))


if __name__ == '__main__':
    main()
