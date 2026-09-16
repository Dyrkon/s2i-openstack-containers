"""Installed into site-packages as sitecustomize.py.

Loads /source-built-packages.txt into TOBIKO_GIT_* so pytest (including
xdist workers) can populate report metadata without a git checkout.
"""
import os


def _export_tobiko_git_metadata() -> None:
    manifest = '/source-built-packages.txt'
    if not os.path.isfile(manifest):
        return
    with open(manifest, encoding='utf-8') as handle:
        for line in handle:
            if not line.startswith('tobiko,'):
                continue
            _, commit, release = line.strip().split(',', 2)
            if commit and commit != 'unknown':
                os.environ.setdefault('TOBIKO_GIT_COMMIT', commit)
            if release and release != 'unknown':
                os.environ.setdefault('TOBIKO_GIT_RELEASE', release)
            break


_export_tobiko_git_metadata()
