"""Resolve one immutable component release, preserving a dispatch's exact commit."""
import json
import os
from pathlib import Path
import re
import urllib.request

COMPONENTS = {'native': 'Laplace-Native', 'postgres': 'Laplace-postgres', 'engine': 'Laplace-Engine', 'mcp': 'Laplace-MCP'}


def resolve(owner, event_name, event, request):
    if not re.fullmatch(r'[A-Za-z0-9-]+', owner):
        raise ValueError('Invalid repository owner')
    payload = event.get('client_payload', {}) if event_name == 'repository_dispatch' else {}
    repository, triggering_sha = payload.get('repository'), payload.get('sha')
    if event_name == 'repository_dispatch':
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
    repository = f'/repos/{owner}/Laplace-Native'
    runs = request(repository + f'/actions/runs?head_sha={revision}&per_page=100')['workflow_runs']
    required = {'native (icx-release)', 'native (gcc-release)', 'isa'}
    for run in runs:
        if (run.get('head_sha') != revision or run.get('head_branch') != 'main'
                or run.get('path') != '.github/workflows/laplace.yml'
                or run.get('event') not in ('push', 'workflow_dispatch')):
            continue
        jobs = request(repository + f'/actions/runs/{run["id"]}/jobs?per_page=100')['jobs']
        passed = {job['name'] for job in jobs if job.get('conclusion') == 'success'}
        if not required.issubset(passed):
            continue
        artifacts = request(repository + f'/actions/runs/{run["id"]}/artifacts?per_page=100')['artifacts']
        if any(a['name'] == 'native-prepared-inputs' and not a.get('expired', True) for a in artifacts):
            return run['id']
    raise ValueError('No verified Native cache artifact for revision ' + revision)


def main():
    token = os.environ['GH_TOKEN']
    def request(path):
        req = urllib.request.Request('https://api.github.com' + path, headers={
            'Authorization': 'Bearer ' + token, 'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28'})
        with urllib.request.urlopen(req, timeout=30) as response:
            return json.load(response)
    revisions = resolve(os.environ['GITHUB_REPOSITORY_OWNER'], os.environ['GITHUB_EVENT_NAME'],
        json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text()), request)
    revisions['native_run'] = verified_native_run(os.environ['GITHUB_REPOSITORY_OWNER'], revisions['native'], request)
    with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as output:
        for key, sha in revisions.items():
            output.write(f'{key}={sha}\n')
    print(json.dumps(revisions, indent=2))


if __name__ == '__main__':
    main()
