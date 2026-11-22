#!/usr/bin/env python3
"""Read machine declarations as data; process values precede installation values."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex

_SALTY_MACHINE_ENV = Path(__file__).resolve().parents[1] / 'Salty-Suite/machine-env/machine_env.py'


def _load_salty_machine_env():
    if not _SALTY_MACHINE_ENV.is_file():
        return None
    spec = importlib.util.spec_from_file_location('salty_suite_machine_env', _SALTY_MACHINE_ENV)
    if spec is None or spec.loader is None:
        return None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def resolve(path, process, explicit=False):
    salty = _load_salty_machine_env()
    if salty is not None:
        try:
            return salty.resolve_env(
                Path(path),
                process,
                process_precedence=True,
                strict=explicit,
                source_key='LAPLACE_CONFIG_SOURCE',
            )
        except FileNotFoundError as exc:
            if explicit:
                raise ValueError('LAPLACE_MACHINE_ENV does not name an existing file') from exc
        except salty.ConfigError as exc:
            message = str(exc)
            if explicit and message.startswith('Configuration file does not exist:'):
                raise ValueError('LAPLACE_MACHINE_ENV does not name an existing file') from exc
            raise ValueError(message) from exc

    values = dict(process)
    declarations = {}
    try:
        content = path.read_text(encoding='utf-8-sig')
    except FileNotFoundError:
        if explicit:
            raise ValueError('LAPLACE_MACHINE_ENV does not name an existing file')
        return {'LAPLACE_CONFIG_SOURCE': 'defaults'}
    lexer = shlex.shlex(content, posix=True)
    lexer.whitespace = '\r\n'
    lexer.whitespace_split = True
    lexer.escape = ''  # Backslashes in paths are data.
    seen = set()
    for item in lexer:
        match = re.fullmatch(r'\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*', item, re.S)
        if not match:
            raise ValueError('Invalid machine configuration assignment')
        name, value = match.groups()
        if name.upper() in seen:
            raise ValueError('Duplicate machine configuration key: ' + name)
        seen.add(name.upper())
        if '\0' in value:
            raise ValueError('NUL in machine configuration key: ' + name)
        if not values.get(name):
            def expand(reference):
                key = next(part for part in reference.groups() if part is not None)
                if key not in values:
                    raise ValueError('Undefined configuration reference: ' + key)
                return values[key]
            value = re.sub(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)|%([A-Za-z_][A-Za-z0-9_]*)%', expand, value)
            values[name] = value
            declarations[name] = value
    declarations['LAPLACE_CONFIG_SOURCE'] = str(path.resolve())
    return declarations


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--format', choices=('shell', 'json'), default='shell')
    args = parser.parse_args()
    path = Path(os.environ.get('LAPLACE_MACHINE_ENV') or '/etc/laplace/machine.env')
    result = resolve(path, os.environ, bool(os.environ.get('LAPLACE_MACHINE_ENV')))
    if args.format == 'json':
        print(json.dumps(result))
    else:
        # Only validated names and shell-quoted literal values cross this boundary.
        print('\n'.join('export ' + name + '=' + shlex.quote(value) for name, value in result.items()))


if __name__ == '__main__':
    main()
