"""Preserve existing Entra callbacks and add the declared environment origins."""
import argparse
import json
import os
import shutil
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configuration', type=Path, default=Path(__file__).with_name('environments.json'))
    parser.add_argument('--azure-config', type=Path, required=True,
                        help='App-owner CLI login; separate from the application workload login')
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.output and args.output.exists():
        parser.error('refusing to overwrite a receipt')
    config = json.loads(args.configuration.read_text())
    provider = config['providers']['microsoft']
    environment = dict(os.environ, AZURE_CONFIG_DIR=str(args.azure_config))
    executable = shutil.which('az')
    if not executable:
        raise SystemExit('Azure CLI is not on PATH.')
    command = [executable]
    if os.name == 'nt' and executable.lower().endswith('.cmd'):
        # Invoke the installed CLI's Python directly so callback strings never
        # pass through CMD expansion, including pre-existing URLs with queries.
        python = Path(executable).parent.parent / 'python.exe'
        if not python.is_file():
            raise SystemExit('Cannot locate the installed Azure CLI Python runtime.')
        command = [str(python), '-IBm', 'azure.cli']
    def az(*arguments):
        result = subprocess.run([*command, *arguments, '-o', 'json'], env=environment, capture_output=True, text=True)
        if result.returncode:
            raise SystemExit('Entra registration access failed. Use an app-owner login in the selected Azure CLI configuration.')
        return json.loads(result.stdout) if result.stdout.strip() else None
    account = az('account', 'show')
    if account['tenantId'] != provider['tenant_id']:
        raise SystemExit('The selected provider-management identity must belong to the declared tenant.')
    application = az('ad', 'app', 'show', '--id', provider['client_id'])
    before = application.get('web', {}).get('redirectUris', [])
    wanted = [e['browser_origin'] + provider['callback_path'] for e in config['environments']]
    combined = sorted(set(before + wanted))
    if args.apply and combined != sorted(before):
        az('ad', 'app', 'update', '--id', application['id'], '--web-redirect-uris', *combined)
    observed = az('ad', 'app', 'show', '--id', provider['client_id'])['web']['redirectUris']
    verified = set(combined).issubset(observed)
    receipt = json.dumps(dict(application_id=provider['client_id'], existing=before, required=wanted,
                              observed=observed, applied=args.apply, verified=verified), indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(receipt + '\n')
    print(receipt)
    if args.apply and not verified:
        raise SystemExit('Entra did not retain all existing and required callbacks.')


if __name__ == '__main__':
    main()
