#!/usr/bin/env python3
"""Measure overlap between exact Bazel repository-cache entries."""

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import zipfile


def load_manifest(path):
    if not path.exists():
        return {}
    return json.loads(path.read_text())


def record_entry(args):
    cache_root = Path(args.cache_root)
    union_root = Path(args.union_root)
    manifest_path = Path(args.manifest)
    data = load_manifest(manifest_path)
    seen = 0
    for source in sorted(p for p in cache_root.rglob("*") if p.is_file()):
        rel = source.relative_to(cache_root).as_posix()
        target = union_root / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        size = source.stat().st_size
        record = data.setdefault(rel, {"bytes": size, "entries": []})
        if record["bytes"] != size:
            raise RuntimeError(f"same cache path has different sizes: {rel}")
        if args.entry not in record["entries"]:
            record["entries"].append(args.entry)
        if not target.exists():
            shutil.copy2(source, target)
        seen += 1
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(data, sort_keys=True))
    shutil.rmtree(cache_root, ignore_errors=True)
    cache_root.mkdir(parents=True, exist_ok=True)
    shutil.rmtree(Path.home() / ".cache" / "bazelisk", ignore_errors=True)
    print(f"{args.entry}: encountered {seen} repository-cache files")


def classify(path, file_type, members):
    text = (path.name + " " + file_type + " " + " ".join(members)).lower()
    if "libflutter" in text or "flutter_embedding" in text or "flutter-embedding" in text:
        return "Flutter engine artifacts"
    if "openjdk" in text or "jdk" in text or "java-runtime" in text:
        return "JDKs"
    if "kotlin-compiler" in text or "kotlin compiler" in text or "kotlinc/" in text:
        return "Kotlin compiler"
    if "cmake" in text:
        return "CMake"
    if "dart-sdk" in text or "dart sdk" in text:
        return "Dart SDK"
    if "flutter_linux" in text or "flutter_macos" in text or "flutter sdk" in text:
        return "Flutter SDK archive"
    return "other"


def archive_members(path):
    try:
        if zipfile.is_zipfile(path):
            with zipfile.ZipFile(path) as archive:
                return archive.namelist()[:2]
    except (OSError, zipfile.BadZipFile):
        pass
    try:
        with tarfile.open(path, "r:*") as archive:
            return [member.name for _, member in zip(range(2), archive)]
    except (OSError, tarfile.TarError):
        return []


def finalize(args):
    union_root = Path(args.union_root)
    data = load_manifest(Path(args.manifest))
    unique_bytes = sum(item["bytes"] for item in data.values())
    union_size = sum(p.stat().st_size for p in union_root.rglob("*") if p.is_file())
    if union_size != unique_bytes:
        raise RuntimeError(f"union size {union_size} != manifest size {unique_bytes}")
    if os.uname().sysname == "Linux":
        du = subprocess.check_output(["du", "-sb", str(union_root)], text=True).strip()
    else:
        # BSD du lacks -b; report exact file bytes alongside allocated-block du.
        du = subprocess.check_output(["du", "-sk", str(union_root)], text=True).strip()
    print(f"du result ({os.uname().sysname}): {du}")
    print(f"union content-addressable size (exact bytes): {union_size}")
    print(f"sum of entry sizes: {args.entry_sum}")
    print(f"deduplicated bytes: {args.entry_sum - union_size}")
    print(f"unique file count: {len(data)}")

    def sha256(path):
        digest = hashlib.sha256()
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()

    groups = {
        "Flutter engine artifacts": [],
        "JDKs": [],
        "Kotlin compiler": [],
        "CMake": [],
        "Dart SDK": [],
        "Flutter SDK archive": [],
        "other": [],
    }
    for rel, record in sorted(data.items()):
        if record["bytes"] < 20_000_000:
            continue
        path = union_root / rel
        file_type = subprocess.check_output(["file", "-b", str(path)], text=True).strip()
        members = archive_members(path)
        group = classify(Path(rel), file_type, members)
        record["sha256"] = sha256(path)
        groups[group].append((rel, record, file_type, members))

    summary = Path(os.environ["GITHUB_STEP_SUMMARY"])
    with summary.open("a") as output:
        output.write(f"\n## Cache overlap: {args.os_name}\n\n")
        output.write(f"- Exact content-addressable union: `{union_size}` bytes\n")
        output.write(f"- Sum of existing entry sizes: `{args.entry_sum}` bytes\n")
        output.write(f"- De-duplicated bytes: `{args.entry_sum - union_size}`\n")
        output.write(f"- `du`: `{du}`\n\n")
        output.write("| Group | SHA-256 | Bytes | Entries | File type | First archive members |\n")
        output.write("|---|---|---:|---|---|---|\n")
        for group, files in groups.items():
            if not files:
                output.write(f"| {group} | — | — | — | — | — |\n")
            for _, record, file_type, members in files:
                output.write(
                    f"| {group} | `{record['sha256']}` | {record['bytes']} | "
                    f"{', '.join(record['entries'])} | {file_type} | "
                    f"{'; '.join(members) if members else '—'} |\n"
                )
    for group, files in groups.items():
        print(f"{group}: {len(files)} large files")
        for _, record, file_type, members in files:
            print(
                f"  {record['sha256']}\t{record['bytes']}\t{','.join(record['entries'])}\t"
                f"{file_type}\t{'; '.join(members[:2])}"
            )


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    record = sub.add_parser("record")
    record.add_argument("--cache-root", required=True)
    record.add_argument("--union-root", required=True)
    record.add_argument("--manifest", required=True)
    record.add_argument("--entry", required=True)
    record.set_defaults(func=record_entry)
    finish = sub.add_parser("finalize")
    finish.add_argument("--union-root", required=True)
    finish.add_argument("--manifest", required=True)
    finish.add_argument("--entry-sum", required=True, type=int)
    finish.add_argument("--os-name", required=True)
    finish.set_defaults(func=finalize)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
