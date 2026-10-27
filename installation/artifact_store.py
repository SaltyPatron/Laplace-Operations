"""Immutable local component files shared by Windows application and modular delivery."""
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile


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


def atomic(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix='.receipt-')
    try:
        with os.fdopen(descriptor, 'w', encoding='utf-8') as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write('\n')
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
