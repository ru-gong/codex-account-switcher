#!/usr/bin/env python3
"""Fail before publishing likely credentials, private paths, or unreviewed files.
Reports rule names and filenames only, never matched values.
"""
import argparse
import io
import json
import pathlib
import re
import zipfile

IGNORED = {'.git', '.build', 'dist', 'evidence', '__pycache__', '.DS_Store'}
ROOT_FILES = {'Package.swift', 'README.md', 'README.en.md', 'NOTICE.md', '.gitignore', '开始备份与重启对照.command'}
ROOT_DIRS = {'Sources', 'Tests', 'scripts', 'docs'}
PATTERNS = {
    'private_home_path': rb'/Users/(?!test(?:/|[\x00\s]))[A-Za-z0-9_.-]+',
    'private_key': rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
    'github_token': rb'gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}',
    'openai_key': rb'sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{24,}',
    'jwt_literal': rb'eyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}',
}
EMAIL = re.compile(rb'[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}')
FORBIDDEN_FILES = {'auth.json', 'accounts.json', '.env', '.DS_Store'}
FORBIDDEN_SUFFIXES = {'.sqlite', '.sqlite3', '.db', '.keychain', '.keychain-db', '.p12', '.pfx', '.pem', '.dmg', '.sparseimage'}


def check_bytes(data, name, extra_denials=()):
    issues = []
    for rule, pattern in PATTERNS.items():
        if re.search(pattern, data): issues.append({'file': name, 'rule': rule})
    for email in EMAIL.findall(data):
        if not (email.endswith(b'@example.invalid') or email == b'contributors@users.noreply.github.com'):
            issues.append({'file': name, 'rule': 'non_synthetic_email'})
            break
    lower = data.lower()
    if any(value and value.lower() in lower for value in extra_denials):
        issues.append({'file': name, 'rule': 'private_identifier'})
    return issues


def audit(root, extra_denials=()):
    root = pathlib.Path(root)
    issues = []
    count = 0
    if root.is_file() and zipfile.is_zipfile(root):
        with zipfile.ZipFile(root) as archive:
            for member in archive.infolist():
                if member.is_dir(): continue
                path = pathlib.PurePosixPath(member.filename)
                if path.is_absolute() or '..' in path.parts or '__MACOSX' in path.parts:
                    issues.append({'file': member.filename, 'rule': 'archive_path_or_metadata'})
                if path.name in FORBIDDEN_FILES or path.suffix in FORBIDDEN_SUFFIXES:
                    issues.append({'file': member.filename, 'rule': 'private_artifact_type'})
                issues += check_bytes(archive.read(member), member.filename, extra_denials)
                count += 1
    elif root.is_file():
        issues += check_bytes(root.read_bytes(), root.name, extra_denials); count = 1
    else:
        for path in sorted(root.rglob('*')):
            relative = path.relative_to(root)
            if any(part in IGNORED for part in relative.parts): continue
            if path.is_symlink():
                issues.append({'file': str(relative), 'rule': 'source_symlink'}); continue
            if not path.is_file(): continue
            if relative.parts[0] not in ROOT_DIRS and str(relative) not in ROOT_FILES:
                issues.append({'file': str(relative), 'rule': 'unreviewed_source_path'})
            if path.name in FORBIDDEN_FILES or path.suffix in FORBIDDEN_SUFFIXES:
                issues.append({'file': str(relative), 'rule': 'private_artifact_type'})
            issues += check_bytes(path.read_bytes(), str(relative), extra_denials)
            count += 1
    return {'files_checked': count, 'status': 'PASS' if not issues else 'FAIL', 'findings': issues}


def require_clean(root):
    result = audit(root)
    if result['status'] != 'PASS':
        raise ValueError('Privacy audit failed: ' + json.dumps(result['findings'], ensure_ascii=False))
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('paths', nargs='+', type=pathlib.Path)
    parser.add_argument('--extra-deny-file', type=pathlib.Path, help='Private JSON list kept outside the publish checkout')
    args = parser.parse_args()
    extra = [str(value).encode() for value in json.loads(args.extra_deny_file.read_text())] if args.extra_deny_file else []
    results = [{'target': p.name, **audit(p, extra)} for p in args.paths]
    print(json.dumps(results, ensure_ascii=False, indent=2))
    raise SystemExit(0 if all(r['status'] == 'PASS' for r in results) else 1)
