"""Resolve one immutable component release, preserving a dispatch's exact commit."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

COMPONENTS = {'native': 'Laplace-Native', 'postgres': 'Laplace-postgres', 'engine': 'Laplace-Engine', 'mcp': 'Laplace-MCP'}


def resolve(owner, event_name, event, request):
    if not re.fullmatch(r'[A-Za-z0-9-]+', owner):
        raise ValueError('Invalid repository owner')
    payload = event.get('client_payload', {}) if event_name == 'repository_dispatch' else {}
    repository, triggering_sha = payload.get('repository'), payload.get('sha')
    pinned_engine = event.get('inputs', {}).get('engine_revision') if event_name == 'workflow_dispatch' else None
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
        main = request(f'/repos/{repo}/commits/main')['sha']
        if not re.fullmatch(r'[0-9a-f]{40}', main):
            raise ValueError('GitHub returned an invalid main revision')
        if repo == repository:
            comparison = request(f'/repos/{repo}/compare/{triggering_sha}...{main}')
            if comparison['status'] not in ('ahead', 'identical'):
                raise ValueError('Triggering revision is not in the component main history')
            revisions[key] = triggering_sha
        else:
            revisions[key] = main
    return revisions


def verified_native_run(owner, revision, request):
    return int(subprocess.check_output(['bash', Path(__file__).resolve().parents[2] / 'native-inputs.sh',
                                       'resolve', owner, revision], text=True).strip())


def qualify_engine(owner, revision, request, mutate, sleep=time.sleep, attempts=180):
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
            if (engine and engine.get('status') == 'completed') or run.get('status') == 'completed':
                raise ValueError('Engine build/test qualification failed: ' + run['html_url'])
        elif not dispatched:
            if request(repository + '/commits/main')['sha'] != revision:
                raise ValueError('Selected Engine revision has no CI run and is no longer main: ' + revision)
            mutate(workflow + '/dispatches', 'POST', {'ref': 'main'})
            print(f'Dispatched required Engine build/tests for {revision}', flush=True)
            dispatched = True
        sleep(10)
    raise TimeoutError('Timed out waiting for Engine build/tests: ' + revision)


def main():
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
        qualify_engine(os.environ['GITHUB_REPOSITORY_OWNER'], sys.argv[2], request, request)
        return
    revisions = resolve(os.environ['GITHUB_REPOSITORY_OWNER'], os.environ['GITHUB_EVENT_NAME'],
        json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text()), request)
    revisions['native_run'] = verified_native_run(os.environ['GITHUB_REPOSITORY_OWNER'], revisions['native'], request)
    with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as output:
        for key, sha in revisions.items():
            output.write(f'{key}={sha}\n')
    print(json.dumps(revisions, indent=2))


if __name__ == '__main__':
    main()
