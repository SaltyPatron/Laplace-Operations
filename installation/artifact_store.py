"""Immutable local component files shared by Windows application and modular delivery."""
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
import subprocess
import sys


def cleanup(store, installation=None):
    """Standalone publishers share the operator's collector, after releasing locks.

    A containing PowerShell operation collects in its outer finally block.
    This is a bounded local build cache, not a historical package repository.
    """
    if os.name != 'nt' or os.environ.get('LAPLACE_STORAGE_OWNER_PID'):
        return
    environment = os.environ.copy()
    environment['LAPLACE_WORK'] = str(Path(store).resolve().parents[1])
    arguments = ['pwsh', '-NoProfile', '-File', str(Path(__file__).resolve().parents[1] / 'laplace.ps1'), 'clean']
    if installation is not None:
        arguments += ['-Installation', str(installation)]
    subprocess.run(arguments, check=True, env=environment, stdout=sys.stderr)


def digest(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def files(root):
    root = Path(root)
    result = {}
    for path in (root, *root.rglob('*')):
        if path.is_symlink() or (hasattr(path, 'is_junction') and path.is_junction()):
            raise ValueError('Artifact may not redirect through a link: ' + str(path))
        if path != root and path.is_file():
            result[path.relative_to(root).as_posix()] = digest(path)
    return result


def inherit_access(path):
    """Give a new, unshared staging object its destination parent's Windows ACL."""
    if os.name != 'nt':
        return
    path = Path(path)
    if path.is_symlink() or (hasattr(path, 'is_junction') and path.is_junction()):
        raise ValueError('Staging access must not follow a link: ' + str(path))
    result = subprocess.run(['icacls.exe', str(path), '/reset', '/Q'],
                            capture_output=True, text=True)
    if result.returncode:
        raise PermissionError('Cannot inherit artifact-store access for ' + str(path) + ': ' +
                              (result.stderr or result.stdout).strip())


def staging_directory(store, prefix):
    directory = Path(tempfile.mkdtemp(prefix=prefix, dir=store))
    try:
        inherit_access(directory)
    except BaseException:
        directory.rmdir()
        raise
    return directory


def atomic(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix='.receipt-')
    try:
        with os.fdopen(descriptor, 'w', encoding='utf-8') as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write('\n')
        inherit_access(temporary)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


@contextmanager
def store_lock(store):
    store = Path(store)
    if any(path.is_symlink() or (hasattr(path, 'is_junction') and path.is_junction()) for path in (store, *store.parents)):
        raise ValueError('Artifact store must be a real directory: ' + str(store))
    store.mkdir(parents=True, exist_ok=True)
    path = store / '.build.lock'
    with path.open('a+b') as stream:
        stream.write(b'0')
        stream.flush()
        stream.seek(0)
        if os.name == 'nt':
            import msvcrt
            try:
                msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
            except OSError as error:
                raise ValueError('Another component build owns ' + str(store)) from error
        else:
            import fcntl
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            yield
        finally:
            if os.name == 'nt':
                stream.seek(0)
                msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)


def link_file(source, target):
    source, target = Path(source), Path(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        if digest(source) == digest(target):
            return
        target.unlink()  # never overwrite a previous artifact's shared inode
    try:
        os.link(source, target)
    except OSError:
        shutil.copy2(source, target)


def materialize_file(source, target, store, expected=None):
    source, target, store = Path(source), Path(target), Path(store)
    expected = expected or digest(source)
    blob = store / 'blobs' / expected[:2] / expected
    blob.parent.mkdir(parents=True, exist_ok=True)
    if not blob.is_file() or digest(blob) != expected:
        descriptor, temporary = tempfile.mkstemp(dir=blob.parent, prefix='.blob-')
        os.close(descriptor)
        try:
            shutil.copy2(source, temporary)
            if digest(temporary) != expected:
                raise ValueError('Component output changed while packaging: ' + str(source))
            inherit_access(temporary)
            os.replace(temporary, blob)
        finally:
            Path(temporary).unlink(missing_ok=True)
    link_file(blob, target)
    return expected


def materialize(source, target, store):
    source, target = Path(source), Path(target)
    inventory = files(source)
    if not inventory:
        raise ValueError('Empty component output: ' + str(source))
    for relative, expected in inventory.items():
        materialize_file(source / relative, target / relative, store, expected)
    return inventory


def grammar_inputs(prepared, compiled=None):
    prepared = Path(prepared)
    if not prepared.is_dir():
        raise ValueError('Prepared grammar input directory is absent: ' + str(prepared))
    selected = {path.name: path for path in sorted(prepared.glob('*.so'))}
    if compiled is not None:
        owned = list(Path(compiled).glob('*.so'))
        if not owned:
            raise ValueError('The selected Engine produced no recipe grammars')
        selected.update((path.name, path) for path in owned)
    if not selected:
        raise ValueError('No compiled grammars at the declared input roots')
    return selected


def snapshot_grammars(prepared, compiled, target):
    """Freeze prepared code grammars plus this Engine's packaging grammars."""
    selected = grammar_inputs(prepared, compiled)
    target = Path(target)
    if not target.is_absolute() or target.exists() or any(path.is_symlink() for path in (target, *target.parents)):
        raise ValueError('Grammar snapshot needs a new absolute, unlinked output directory')
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.grammars-', dir=target.parent) as temporary:
        stage = Path(temporary) / 'runtime'
        stage.mkdir()
        for name, source in selected.items():
            expected = digest(source)
            shutil.copy2(source, stage / name)
            if digest(stage / name) != expected:
                raise ValueError('Grammar input changed during snapshot: ' + str(source))
        stage.rename(target)
    return {'grammars': len(selected), 'prepared': str(prepared), 'compiled': str(compiled), 'runtime': str(target)}


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description='Freeze a qualification run\'s complete compiled grammar closure')
    parser.add_argument('--prepared', required=True)
    parser.add_argument('--compiled', required=True)
    parser.add_argument('--output', required=True)
    arguments = parser.parse_args()
    print(json.dumps(snapshot_grammars(arguments.prepared, arguments.compiled, arguments.output)))
