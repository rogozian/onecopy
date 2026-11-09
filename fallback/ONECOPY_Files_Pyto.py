#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ONECOPY Files / Pyto 0.1

Free iPhone workaround: scans user-authorized folders recursively and verifies
exact duplicates. Runs inside the App Store app Pyto (no sideload, profiles, or Mac).
This script NEVER deletes, renames, or uploads any file.

Source: https://github.com/rogozian/onecopy
"""
from __future__ import annotations

import csv
import hashlib
import os
import stat
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Iterable

BLOCK = 1024 * 1024
MAX_FOLDERS = 30


def stable_stat(path: str):
    """Refuse symbolic links; avoid scanning files mutated during read."""
    info = os.lstat(path)
    if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise ValueError('Not a regular file')
    return (info.st_size, info.st_mtime_ns, info.st_ino, info.st_dev)


def hash_file(path: str, expected: tuple) -> str:
    if stable_stat(path) != expected:
        raise OSError('File changed since discovery')
    digest = hashlib.sha256()
    with open(path, 'rb') as stream:
        while True:
            chunk = stream.read(BLOCK)
            if not chunk:
                break
            digest.update(chunk)
    if stable_stat(path) != expected:
        raise OSError('File changed while hashing')
    return digest.hexdigest()


def equal_file_bytes(a: str, b: str, sa: tuple, sb: tuple) -> bool:
    if sa[0] != sb[0] or stable_stat(a) != sa or stable_stat(b) != sb:
        return False
    with open(a, 'rb') as fa, open(b, 'rb') as fb:
        while True:
            block_a = fa.read(BLOCK)
            block_b = fb.read(BLOCK)
            if block_a != block_b:
                return False
            if not block_a:
                break
    if stable_stat(a) != sa or stable_stat(b) != sb:
        raise OSError('File changed during confirmation')
    return True


def scan(roots: Iterable[str], progress: Callable[[str], None] | None = None):
    """Returns confirmed duplicate groups and scan statistics. Read-only."""
    report = progress or (lambda msg: None)
    by_size = defaultdict(list)
    errors = []
    visited = set()
    checked = 0
    scanned_bytes = 0
    for root in roots:
        root = os.path.abspath(os.path.expanduser(str(root)))
        if not os.path.isdir(root):
            errors.append((root, 'Folder is unavailable'))
            continue
        report('Проверяю папку: ' + root)
        def record_error(exc):
            errors.append((getattr(exc, 'filename', root), str(exc)))
        for directory, subdirs, filenames in os.walk(root, followlinks=False, onerror=record_error):
            subdirs[:] = [name for name in subdirs if not os.path.islink(os.path.join(directory, name))]
            for name in filenames:
                path = os.path.join(directory, name)
                try:
                    if path in visited:
                        continue
                    visited.add(path)
                    info = stable_stat(path)
                    checked += 1
                    scanned_bytes += info[0]
                    if info[0] > 0:
                        by_size[info[0]].append((path, info))
                    if checked % 250 == 0:
                        report('Список файлов: {}'.format(checked))
                except (OSError, ValueError) as exc:
                    errors.append((path, str(exc)))

    candidates = [item for same_size in by_size.values() if len(same_size) > 1 for item in same_size]
    report('Файлов: {}; кандидатов по размеру: {}'.format(checked, len(candidates)))
    by_digest = defaultdict(list)
    for index, (path, info) in enumerate(candidates, start=1):
        try:
            digest = hash_file(path, info)
            by_digest[(info[0], digest)].append((path, info))
        except (OSError, ValueError) as exc:
            errors.append((path, str(exc)))
        if index % 30 == 0:
            report('Проверено по SHA-256: {} / {}'.format(index, len(candidates)))

    groups = []
    for files in by_digest.values():
        if len(files) < 2:
            continue
        confirmed = []
        for path, info in sorted(files, key=lambda pair: (len(pair[0]), pair[0].lower())):
            matched = False
            for group in confirmed:
                base, base_info = group[0]
                try:
                    if equal_file_bytes(base, path, base_info, info):
                        group.append((path, info))
                        matched = True
                        break
                except (OSError, ValueError) as exc:
                    errors.append((path, str(exc)))
                    matched = True
                    break
            if not matched:
                confirmed.append([(path, info)])
        groups.extend(group for group in confirmed if len(group) > 1)

    groups.sort(key=lambda group: (-(len(group) - 1) * group[0][1][0], group[0][0]))
    return {
        'groups': groups,
        'files_seen': checked,
        'candidate_files': len(candidates),
        'bytes_scanned': scanned_bytes,
        'bytes_repeated': sum((len(group) - 1) * group[0][1][0] for group in groups),
        'errors': errors,
        'timestamp': datetime.now(timezone.utc).isoformat(),
    }


def export_csv(result: dict, destination: str) -> str:
    """Write a report, not a deletion list executed on the phone."""
    os.makedirs(os.path.dirname(os.path.abspath(destination)), exist_ok=True)
    with open(destination, 'w', encoding='utf-8-sig', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(['group', 'status', 'bytes', 'path'])
        for group_number, group in enumerate(result['groups'], start=1):
            for index, (path, info) in enumerate(group):
                writer.writerow([group_number, 'KEEP (suggested)' if index == 0 else 'COPY (review)', info[0], path])
        if result['errors']:
            writer.writerow([])
            writer.writerow(['WARNING', 'unavailable paths below; not scanned'])
            for path, message in result['errors']:
                writer.writerow(['SKIPPED', message, '', path])
    return destination


def report_console(result: dict):
    groups = result['groups']
    print('\n' + '=' * 45)
    print('ONECOPY — РЕЗУЛЬТАТ ФАЙЛОВОГО СКАНЕРА')
    print('Проверено файлов:', result['files_seen'])
    print('Групп точных дубликатов:', len(groups))
    print('Количество лишних копий:', sum(len(g) - 1 for g in groups))
    print('Размер повторов: {:.2f} МБ'.format(result['bytes_repeated'] / 1048576))
    print('Не прочитано/пропущено:', len(result['errors']))
    print('Файлы НЕ удалены. Осторожно с облаком и синхронизацией.')
    print('=' * 45)
    for number, group in enumerate(groups[:40], start=1):
        print('\nГРУППА {} ({} копий, по {:.2f} МБ):'.format(number, len(group) - 1, group[0][1][0] / 1048576))
        for i, (path, _) in enumerate(group):
            print('  {} {}'.format('СОХРАНИТЬ?' if i == 0 else 'КОПИЯ', path))
    if len(groups) > 40:
        print('И ещё {} групп в CSV-отчёте.'.format(len(groups) - 40))


def choose_roots_in_pyto():
    try:
        import file_system as fs
    except ImportError as exc:
        raise RuntimeError('Запустите этот скрипт внутри бесплатного приложения Pyto из App Store.') from exc
    print('ONECOPY Files / Pyto — без компьютера и профилей')
    print('Выбирайте одну или несколько папок. Будут проверены ВСЕ вложенные файлы.')
    print('Скрипт ничего не удаляет, никуда не загружает и не меняет.')
    roots = []
    for _ in range(MAX_FOLDERS):
        try:
            root = fs.pick_directory()
        except Exception as exc:
            if roots:
                print('Выбор папки завершён:', exc)
                break
            print('Выбор первой папки отменён:', exc)
            return roots
        if not root:
            break
        root = os.path.realpath(str(root))
        if root not in roots:
            roots.append(root)
            print('Добавлена папка {}: {}'.format(len(roots), root))
        choice = input('Ещё папку? Введите + и Enter. Или просто Enter — начать: ').strip()
        if choice != '+':
            break
    return roots


def main():
    if len(sys.argv) > 1:
        roots = sys.argv[1:]
    else:
        roots = choose_roots_in_pyto()
    if not roots:
        print('Папки не выбраны.')
        return 0
    result = scan(roots, progress=print)
    report_console(result)
    timestamp = datetime.now().strftime('%Y%m%d-%H%M%S')
    destination = os.path.join(os.path.expanduser('~'), 'Documents', 'ONECOPY-duplicates-' + timestamp + '.csv')
    try:
        export_csv(result, destination)
        print('\nОтчёт сохранён:', destination)
        try:
            import file_system as fs
            if input('Показать системное меню «Поделиться» для отчёта? + и Enter: ').strip() == '+':
                fs.share_files([destination])
        except (ImportError, Exception) as exc:
            print('CSV сохранён, но меню «Поделиться» не открылось:', exc)
    except (OSError, ValueError) as exc:
        print('Не удалось сохранить CSV, но результаты выше доступны:', exc)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
