#!/usr/bin/env python3
"""Summarize Linux strace observations for declared action inputs."""

import argparse
import ast
import collections
import json
import os
import re
import sys
from pathlib import Path


READ_CALLS = {"read", "readv", "pread64", "preadv", "preadv2"}
MMAP_CALLS = {"mmap", "mmap2"}
METADATA_CALLS = {
    "access", "faccessat", "faccessat2", "newfstatat", "stat", "lstat",
    "fstat", "statx", "readlink", "readlinkat", "open", "openat",
    "openat2", "fopen", "opendir",
}
STRING = re.compile(r'"(?:\\.|[^"\\])*"')
TRACE_PREFIX = re.compile(r"^(?:\[pid\s+(\d+)\]\s+|(\d+)\s+)?(.*)$")
RESUMED = re.compile(r"^<\.\.\.\s*([A-Za-z0-9_]+)\s+resumed>(.*)$")
SYSCALL = re.compile(r"^([A-Za-z0-9_]+)\((.*)$", re.S)
RETURN = re.compile(r"\)\s*=\s*(-?\d+|0x[0-9a-fA-F]+)(?:\s|$)")
FD_ANNOTATION = re.compile(r"(?:^|[\s,])(-?\d+)<((?:\\.|[^>])*)>")


def return_value(match):
    return int(match.group(1), 0) if match else None


def c_strings(text):
    values = []
    for match in STRING.finditer(text):
        try:
            value = ast.literal_eval(match.group(0))
        except (SyntaxError, ValueError):
            continue
        if isinstance(value, str):
            values.append(value)
    return values


def split_arguments(text):
    parts, start, depth, quoted, escaped = [], 0, 0, False, False
    for i, char in enumerate(text):
        if quoted:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
        elif char == '"':
            quoted = True
        elif char in "([{":
            depth += 1
        elif char in ")]}" and depth:
            depth -= 1
        elif char == "," and depth == 0:
            parts.append(text[start:i].strip())
            start = i + 1
    parts.append(text[start:].strip())
    return parts


def load_inventory(path):
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"cannot read input inventory: {exc}") from exc
    if not isinstance(data, list):
        raise ValueError("input inventory must be a JSON list")
    records, exec_index, real_index = [], collections.defaultdict(list), collections.defaultdict(list)
    exec_parts_index = collections.defaultdict(list)
    for index, row in enumerate(data):
        if not isinstance(row, dict):
            raise ValueError(f"inventory item {index} must be an object")
        exec_path, real_path, size = row.get("exec_path"), row.get("real_path"), row.get("size")
        if not isinstance(exec_path, str) or not exec_path or not isinstance(real_path, str) or not real_path:
            raise ValueError(f"inventory item {index} requires non-empty exec_path and real_path strings")
        if size is not None and (not isinstance(size, int) or isinstance(size, bool) or size < 0):
            raise ValueError(f"inventory item {index} size must be a non-negative integer or null")
        record = {"exec_path": exec_path, "real_path": os.path.normpath(real_path), "size": size}
        records.append(record)
        exec_index[os.path.normpath(exec_path)].append(index)
        real_index[os.path.normpath(real_path)].append(index)
        exec_parts_index[tuple(Path(os.path.normpath(exec_path)).parts)].append(index)
    return records, exec_index, real_index, exec_parts_index


def path_matches(path, records, exec_index, real_index, exec_parts_index, execroot):
    """Return declared inventory indexes; stage-path suffixes must be unique."""
    if not path:
        return [], "unresolved"
    path = os.path.normpath(path)
    matches = set(real_index.get(path, ()))
    if path in exec_index:
        matches.update(exec_index[path])
    root = os.path.normpath(execroot)
    try:
        relative = os.path.relpath(path, root)
        if relative != os.pardir and not relative.startswith(os.pardir + os.sep):
            matches.update(exec_index.get(os.path.normpath(relative), ()))
    except ValueError:
        pass
    if matches:
        return sorted(matches), "exact"
    parts = Path(path).parts
    suffix_matches = set()
    for length in range(1, len(parts) + 1):
        suffix_matches.update(exec_parts_index.get(tuple(parts[-length:]), ()))
    if len(suffix_matches) == 1:
        return list(suffix_matches), "stage_suffix"
    if len(suffix_matches) > 1:
        return [], "ambiguous_stage_suffix"
    return [], "external"


def normalize_path(path, cwd):
    if not path or path.endswith(" (deleted)"):
        path = path[:-10] if path and path.endswith(" (deleted)") else path
    if not path:
        return None
    if not os.path.isabs(path):
        if not cwd or not os.path.isabs(cwd):
            return None
        path = os.path.join(cwd, path)
    return os.path.normpath(path)


def process_kind(command):
    value = (command or "").lower()
    base = os.path.basename(value.split()[0]) if value else ""
    if "tar" in base:
        return "tar"
    if "dart" in base or "flutter" in base:
        return "dart_flutter"
    if "python" in base:
        return "python"
    if base:
        return "helper"
    return "other"


def parse_trace(trace_path, records, exec_index, real_index, exec_parts_index, execroot):
    try:
        lines = Path(trace_path).read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as exc:
        raise ValueError(f"cannot read trace: {exc}") from exc
    read_totals = {"calls": 0, "bytes": 0}
    cwd_by_pid, pending, parent, commands = {}, {}, {}, {}
    accesses = [collections.Counter() for _ in records]
    process_observations = collections.defaultdict(collections.Counter)
    unresolved = collections.Counter()
    unresolved_examples = collections.defaultdict(list)
    malformed = collections.Counter()
    recognized = collections.Counter()
    all_pids = set()

    def add_unresolved(kind, detail):
        unresolved[kind] += 1
        if len(unresolved_examples[kind]) < 12 and detail not in unresolved_examples[kind]:
            unresolved_examples[kind].append(detail[:300])

    def resolve(pid, rawpath, method):
        path = normalize_path(rawpath, cwd_by_pid.get(pid))
        if path is None:
            add_unresolved("relative_path_without_cwd", rawpath or "<no path>")
            return [], None, "unknown"
        indexes, match_kind = path_matches(path, records, exec_index, real_index, exec_parts_index, execroot)
        if indexes:
            return indexes, path, match_kind
        if match_kind == "ambiguous_stage_suffix":
            add_unresolved(match_kind, path)
        elif match_kind == "external":
            add_unresolved("external_path", path)
        return [], path, match_kind

    def record(pid, call, args, ret, rawline):
        recognized[call] += 1
        argv = split_arguments(args)
        # Only syscall descriptor arguments can identify file descriptors; never scan payload buffers.
        fd_argument_indexes = (
            (0,) if call in READ_CALLS or call in {"fstat", "fchdir"}
            else (4,) if call in MMAP_CALLS
            else ()
        )
        fd_paths = []
        for argument_index in fd_argument_indexes:
            if argument_index < len(argv):
                for match in FD_ANNOTATION.finditer(argv[argument_index]):
                    fd_paths.append(match.group(2).replace(r"\>", ">"))
        paths = []
        path_argument = {
            "open": 0, "openat": 1, "openat2": 1, "access": 0, "faccessat": 1,
            "faccessat2": 1, "stat": 0, "lstat": 0, "newfstatat": 1,
            "statx": 1, "readlink": 0, "readlinkat": 1, "execve": 0,
        }.get(call)
        if path_argument is not None and len(argv) > path_argument:
            paths = c_strings(argv[path_argument])
        path_values = paths + fd_paths
        if call in READ_CALLS:
            if ret is None:
                malformed["read_without_return"] += 1
                add_unresolved("read_without_return", rawline)
                return
            if ret >= 0:
                recognized["useful_read"] += 1
                if ret > 0:
                    read_totals["calls"] += 1
                    read_totals["bytes"] += ret
                event = "positive_read_bytes" if ret > 0 else "zero_read_attempt"
                target_paths = fd_paths
                if not target_paths and argv:
                    # A numeric fd without -yy cannot safely be mapped to an inventory path.
                    add_unresolved("read_fd_without_path_annotation", rawline)
                for rawpath in target_paths:
                    indexes, resolved, _ = resolve(pid, rawpath, call)
                    for index in indexes:
                        accesses[index][event] += ret if ret > 0 else 1
                        accesses[index]["read_calls"] += 1
                        process_observations[index][process_kind(commands.get(pid))] += ret
            return
        if call in MMAP_CALLS:
            if ret is not None and ret >= 0:
                recognized["successful_mmap"] += 1
                for rawpath in fd_paths:
                    indexes, resolved, _ = resolve(pid, rawpath, call)
                    for index in indexes:
                        accesses[index]["mmap_calls"] += 1
            return
        if call in METADATA_CALLS:
            if ret is not None and ret >= 0:
                for rawpath in path_values:
                    indexes, resolved, _ = resolve(pid, rawpath, call)
                    for index in indexes:
                        accesses[index]["metadata_operations"] += 1
            return
        if call == "execve" and ret == 0:
            values = c_strings(args)
            if values:
                commands[pid] = values[0]
                if len(argv) > 1:
                    arg_values = c_strings(argv[1])
                    if arg_values:
                        commands[pid] = " ".join(arg_values)

    def dispatch(pid, call, args, ret, rawline):
        if call == "chdir" and ret == 0:
            values = c_strings(args)
            if values:
                cwd_by_pid[pid] = normalize_path(values[0], cwd_by_pid.get(pid))
        elif call == "fchdir" and ret == 0:
            arguments = split_arguments(args)
            if arguments:
                values = [match.group(2) for match in FD_ANNOTATION.finditer(arguments[0])]
                if values:
                    cwd_by_pid[pid] = normalize_path(values[0], cwd_by_pid.get(pid))
        if call in {"clone", "clone3", "fork", "vfork"} and ret is not None and ret > 0:
            parent[ret] = pid
            if pid in cwd_by_pid:
                cwd_by_pid[ret] = cwd_by_pid[pid]
            if pid in commands:
                commands[ret] = commands[pid]
        record(pid, call, args, ret, rawline)

    for line_number, rawline in enumerate(lines, 1):
        match = TRACE_PREFIX.match(rawline)
        if not match:
            malformed["unrecognized_line"] += 1
            continue
        pid = int(match.group(1) or match.group(2) or 0)
        text = match.group(3)
        if pid:
            all_pids.add(pid)
        if pid == 0:
            # strace may emit non-syscall diagnostics; keep bounded accounting.
            if text and not text.startswith("strace:"):
                malformed["unrecognized_line"] += 1
            continue
        resumed = RESUMED.match(text)
        if resumed:
            call = resumed.group(1)
            suffix = resumed.group(2)
            prior = pending.pop(pid, None)
            if prior is None:
                malformed["orphan_resumed"] += 1
                add_unresolved("orphan_resumed", rawline)
                continue
            if prior[0] != call:
                malformed["resumed_call_mismatch"] += 1
                add_unresolved("resumed_call_mismatch", rawline)
                continue
            complete = call + "(" + prior[1] + suffix
            syscall_match = SYSCALL.match(complete)
            if not syscall_match:
                malformed["malformed_resumed"] += 1
                add_unresolved("malformed_resumed", rawline)
                continue
            result = RETURN.search(complete)
            syscall_args = complete[len(call) + 1:result.start()] + ")" if result else syscall_match.group(2)
            dispatch(pid, call, syscall_args, return_value(result), rawline)
            continue
        if "<unfinished ...>" in text:
            sm = SYSCALL.match(text)
            if not sm:
                malformed["malformed_unfinished"] += 1
                continue
            if pid in pending:
                malformed["unfinished_replaced_before_resume"] += 1
                add_unresolved("unfinished_replaced_before_resume", rawline)
            pending[pid] = (sm.group(1), sm.group(2).split("<unfinished ...>", 1)[0].rstrip())
            continue
        sm = SYSCALL.match(text)
        if not sm:
            if text.startswith("+++ exited") or text.startswith("--- ") or text.startswith("+++ killed"):
                continue
            malformed["unrecognized_line"] += 1
            continue
        call, remainder = sm.group(1), sm.group(2)
        result = RETURN.search(remainder)
        ret = return_value(result)
        args = remainder[:result.start()] + ")" if result else remainder
        dispatch(pid, call, args, ret, rawline)
    if pending:
        malformed["unfinished_at_eof"] += len(pending)
        for pid, (call, args) in pending.items():
            add_unresolved("unfinished_at_eof", f"pid={pid} {call}({args} <unfinished ...>")
    if recognized["useful_read"] == 0 and recognized["successful_mmap"] == 0:
        raise ValueError("trace contains no completed read or successful mmap observations")


    output_records = []
    unread = []
    for index, source in enumerate(records):
        counts = accesses[index]
        if counts["positive_read_bytes"]:
            category = "positive_bytes_read"
        elif counts["zero_read_attempt"]:
            category = "zero_read_attempt"
        elif counts["mmap_calls"]:
            category = "mapped_only"
        elif counts["metadata_operations"]:
            category = "metadata_only"
        else:
            category = "not_observed"
            unread.append(source["exec_path"])
        proc = process_observations[index]
        output_records.append({
            **source,
            "classification": category,
            "observed_positive_read_bytes": counts["positive_read_bytes"],
            "zero_read_attempts": counts["zero_read_attempt"],
            "read_calls": counts["read_calls"],
            "mmap_calls": counts["mmap_calls"],
            "metadata_operations": counts["metadata_operations"],
            "read_bytes_by_process_category": dict(sorted(proc.items())),
            "mapping_observation_is_not_page_read_proof": bool(counts["mmap_calls"]),
        })
    classes = collections.Counter(row["classification"] for row in output_records)
    canonical_groups = collections.defaultdict(list)
    for i, row in enumerate(records):
        canonical_groups[os.path.normcase(os.path.realpath(row["real_path"]))].append(i)
    canonical_counts = collections.Counter()
    for indexes in canonical_groups.values():
        categories = {output_records[i]["classification"] for i in indexes}
        if "positive_bytes_read" in categories:
            canonical_counts["positive_bytes_read"] += 1
        elif "zero_read_attempt" in categories:
            canonical_counts["zero_read_attempt"] += 1
        elif "mapped_only" in categories:
            canonical_counts["mapped_only"] += 1
        elif "metadata_only" in categories:
            canonical_counts["metadata_only"] += 1
        else:
            canonical_counts["not_observed"] += 1
    grouped = collections.defaultdict(collections.Counter)
    for row in output_records:
        components = Path(row["exec_path"]).parts
        if "android" in components:
            group = "android"
        elif "example" in components and "examples" not in components:
            group = "example"
        else:
            group = "other"
        grouped[group][row["classification"]] += 1
    by_kind = collections.Counter(process_kind(value) for value in commands.values())
    summary = {
        "declared_input_paths": len(records),
        "unique_canonical_paths": len(canonical_groups),
        "path_classification_counts": dict(sorted(classes.items())),
        "canonical_classification_counts": dict(sorted(canonical_counts.items())),
        "groups": {name: dict(sorted(counts.items())) for name, counts in sorted(grouped.items())},
        "trace": {
            "lines": len(lines), "pids": len(all_pids), "completed_read_syscalls": recognized["useful_read"],
            "positive_bytes_read_syscalls": read_totals["calls"],
            "positive_bytes_read_total": read_totals["bytes"],
            "inherited_child_processes": len(parent),
            "parent_process_categorization": "children inherit known command and cwd at clone/fork; execve replaces command identity",
            "mmap_syscalls": recognized["mmap"],
            "successful_mmap_syscalls": recognized["successful_mmap"],
            "malformed_or_incomplete": dict(sorted(malformed.items())),
            "pending_unfinished_at_eof": len(pending),
            "unresolved_counts": dict(sorted(unresolved.items())),
            "unresolved_examples": dict(sorted(unresolved_examples.items())),
        },
        "processes": {
            "identified_execve_commands": len(commands),
            "identified_process_categories": dict(sorted(by_kind.items())),
            "inheritance": "fork/clone children inherit the parent's known command and cwd; execve replaces command identity; process phase attribution is best-effort",
        },
        "unread_candidate_count": len(unread),
        "unread_candidate_paths": unread,
        "interpretation": "not_observed means no matching traced read, mmap, or metadata operation; it is not a safely-unused claim. mmap does not prove mapped pages were read.",
    }
    return summary, output_records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inputs", required=True)
    parser.add_argument("--trace", required=True)
    parser.add_argument("--execroot", required=True)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()
    try:
        records, exec_index, real_index, exec_parts_index = load_inventory(args.inputs)
        summary, classified = parse_trace(args.trace, records, exec_index, real_index, exec_parts_index, args.execroot)
        out = Path(args.output_dir)
        out.mkdir(parents=True, exist_ok=True)
        (out / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        (out / "input-classification.json").write_text(json.dumps(classified, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        counts = summary["path_classification_counts"]
        trace = summary["trace"]
        lines = [
            "# Asset input read observations", "",
            f"- Declared paths: {summary['declared_input_paths']} ({summary['unique_canonical_paths']} unique canonical paths)",
            "- Classifications: " + ", ".join(f"{key}={value}" for key, value in sorted(counts.items())),
            f"- Completed read syscalls: {trace['completed_read_syscalls']}; mmap syscalls: {trace['mmap_syscalls']}",
            f"- Unresolved observations: {sum(trace['unresolved_counts'].values())}; malformed/incomplete counters: {sum(trace['malformed_or_incomplete'].values())}",
            f"- Unread candidates: {summary['unread_candidate_count']} (not a safely-unused determination)",
            "- mmap records indicate a mapping, not that any mapped page was read.", "",
        ]
        (out / "summary.md").write_text("\n".join(lines), encoding="utf-8")
    except (ValueError, OSError) as exc:
        print(f"asset read trace: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
