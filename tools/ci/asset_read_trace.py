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
OPEN_CALLS = {"open", "openat", "openat2"}
AT_PATH_CALLS = {"openat", "openat2", "newfstatat", "statx", "faccessat", "faccessat2", "readlinkat"}
STAGING_HELPERS = {"tar", "chmod", "cp", "mkdir", "rm"}
STRING = re.compile(r'"(?:\\.|[^"\\])*"')
TRACE_PREFIX = re.compile(r"^(?:\[pid\s+(\d+)\]\s+|(\d+)\s+)?(.*)$")
RESUMED = re.compile(r"^<\.\.\.\s*([A-Za-z0-9_]+)\s+resumed>(.*)$")
SYSCALL = re.compile(r"^([A-Za-z0-9_]+)\((.*)$", re.S)
RETURN = re.compile(r"\)\s*=\s*(-?\d+|0x[0-9a-fA-F]+)(?:<([^>]*)>)?(?:\s|$)")
FD_ANNOTATION = re.compile(r"(?:^|[\s,])(-?\d+)<((?:\\.|[^>])*)>")
AT_FDCWD_ANNOTATION = re.compile(r"^AT_FDCWD<((?:\\.|[^>])*)>$")
def return_path(match):
    return match.group(2) if match and match.group(2) else None
FLUTTER_STAGE_ROOT = re.compile(r"^/tmp/flutter_assets\.[A-Za-z0-9]{6}/(.*)$")
SANDBOX_EXECROOT_ROOT = re.compile(r"/sandbox/[A-Za-z0-9_-]+-sandbox/\d+/execroot/_main/(.*)$")


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
    if not isinstance(data, list) or not data:
        raise ValueError("input inventory must be a non-empty JSON list")
    records, exec_index, real_index = [], collections.defaultdict(list), collections.defaultdict(list)
    for index, row in enumerate(data):
        if not isinstance(row, dict):
            raise ValueError(f"inventory item {index} must be an object")
        exec_path, real_path, size = row.get("exec_path"), row.get("real_path"), row.get("size")
        if not isinstance(exec_path, str) or not exec_path or not isinstance(real_path, str) or not os.path.isabs(real_path):
            raise ValueError(f"inventory item {index} requires an execroot-relative exec_path and absolute real_path")
        normalized_exec_path = os.path.normpath(exec_path)
        if os.path.isabs(exec_path) or normalized_exec_path == os.pardir or normalized_exec_path.startswith(os.pardir + os.sep):
            raise ValueError(f"inventory item {index} exec_path must not escape the execroot")
        if size is not None and (not isinstance(size, int) or isinstance(size, bool) or size < 0):
            raise ValueError(f"inventory item {index} size must be a non-negative integer or null")
        record = {"exec_path": exec_path, "real_path": os.path.normpath(real_path), "size": size}
        records.append(record)
        exec_index[normalized_exec_path].append(index)
        real_index[record["real_path"]].append(index)
    return records, exec_index, real_index
def path_matches(path, exec_index, real_index, execroot):
    """Map only exact canonical, execroot-relative, or known stage-root-relative paths."""
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
    rooted_matches = []
    match = FLUTTER_STAGE_ROOT.match(path)
    if match:
        remainder = os.path.normpath(match.group(1))
        candidates = exec_index.get(remainder, ())
        if candidates:
            rooted_matches.append((len(Path(remainder).parts), list(candidates)))
    for match in SANDBOX_EXECROOT_ROOT.finditer(path):
        remainder = os.path.normpath(match.group(1))
        candidates = exec_index.get(remainder, ())
        if candidates:
            rooted_matches.append((len(Path(remainder).parts), list(candidates)))
    if rooted_matches:
        longest = max(length for length, _ in rooted_matches)
        matches = {index for length, candidates in rooted_matches if length == longest for index in candidates}
        return sorted(matches), "stage_root_relative"
    return [], "external"
def normalize_path(path, cwd, base=None):
    if not path or path.endswith(" (deleted)"):
        path = path[:-10] if path and path.endswith(" (deleted)") else path
    if not path:
        return None
    if not os.path.isabs(path):
        anchor = base if base and os.path.isabs(base) else cwd
        if not anchor or not os.path.isabs(anchor):
            return None
        path = os.path.join(anchor, path)
    return os.path.normpath(path)




def process_name(command):
    value = (command or "").lower()
    return os.path.basename(value.split()[0]) if value else "unknown"


def process_kind(command):
    base = process_name(command)
    if base == "tar":
        return "tar"
    if base.startswith("dart") or base == "flutter":
        return "dart_flutter"
    if base.startswith("python"):
        return "python"
    if base != "unknown":
        return "helper"
    return "other"


def open_access(call, arguments):
    flag_index = {"open": 1, "openat": 2, "openat2": 2}.get(call)
    if flag_index is None or flag_index >= len(arguments):
        return False, False, False
    flags = arguments[flag_index]
    if call == "openat2":
        match = re.search(r"\bflags=([^,}]+)", flags)
        flags = match.group(1) if match else ""
    read = "O_PATH" not in flags and ("O_RDWR" in flags or "O_WRONLY" not in flags)
    write = "O_RDWR" in flags or "O_WRONLY" in flags
    create = "O_CREAT" in flags
    return read, write, create


def parse_trace(trace_path, records, exec_index, real_index, execroot):
    try:
        lines = Path(trace_path).read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as exc:
        raise ValueError(f"cannot read trace: {exc}") from exc
    cwd_by_pid, pending, parent, commands = {}, {}, {}, {}
    read_totals = collections.Counter()
    accesses = [collections.Counter() for _ in records]
    process_observations = [collections.defaultdict(collections.Counter) for _ in records]
    process_totals = collections.defaultdict(collections.Counter)
    staging_process_totals = collections.defaultdict(collections.Counter)
    unresolved = collections.Counter()
    unresolved_examples = collections.defaultdict(list)
    malformed = collections.Counter()
    recognized = collections.Counter()
    all_pids = set()

    def add_unresolved(kind, detail):
        unresolved[kind] += 1
        if len(unresolved_examples[kind]) < 12 and detail not in unresolved_examples[kind]:
            unresolved_examples[kind].append(detail[:300])

    def process_category(pid):
        return process_kind(commands.get(pid))

    def add_process_event(pid, event, amount=1):
        name = process_name(commands.get(pid))
        kind = process_category(pid)
        process_totals[kind][event] += amount
        if name in STAGING_HELPERS:
            staging_process_totals[name][event] += amount
        return name, kind

    def add_input_event(index, pid, event, amount=1):
        name = process_name(commands.get(pid))
        process_observations[index][name][event] += amount

    def dirfd_base(pid, call, arguments):
        if call not in AT_PATH_CALLS or not arguments:
            return None
        first = arguments[0]
        at_cwd = AT_FDCWD_ANNOTATION.match(first)
        if at_cwd:
            return normalize_path(at_cwd.group(1), cwd_by_pid.get(pid))
        descriptor = FD_ANNOTATION.search(first)
        if descriptor:
            return normalize_path(descriptor.group(2), cwd_by_pid.get(pid))
        if first == "AT_FDCWD":
            return cwd_by_pid.get(pid)
        return None

    def resolve(pid, rawpath, method, base=None):
        path = normalize_path(rawpath, cwd_by_pid.get(pid), base)
        if path is None:
            add_unresolved("relative_path_without_cwd", rawpath or "<no path>")
            return [], None, "unknown"
        indexes, match_kind = path_matches(path, exec_index, real_index, execroot)
        if indexes:
            return indexes, path, match_kind
        if match_kind == "external":
            add_unresolved("external_path", path)
        return [], path, match_kind

    def record(pid, call, args, ret, ret_path, rawline):
        recognized[call] += 1
        argv = split_arguments(args)
        fd_argument_indexes = (
            (0,) if call in READ_CALLS or call in {"fstat", "fchdir"}
            else (4,) if call in MMAP_CALLS
            else ()
        )
        fd_paths = []
        for argument_index in fd_argument_indexes:
            if argument_index < len(argv):
                fd_paths.extend(match.group(2).replace(r"\>", ">") for match in FD_ANNOTATION.finditer(argv[argument_index]))
        path_argument = {
            "open": 0, "openat": 1, "openat2": 1, "access": 0, "faccessat": 1,
            "faccessat2": 1, "stat": 0, "lstat": 0, "newfstatat": 1,
            "statx": 1, "readlink": 0, "readlinkat": 1, "execve": 0,
        }.get(call)
        paths = c_strings(argv[path_argument]) if path_argument is not None and len(argv) > path_argument else []
        if call in OPEN_CALLS and ret_path:
            paths = [ret_path]
        base = dirfd_base(pid, call, argv)
        read_open, write_open, creating_open = open_access(call, argv)

        if call in READ_CALLS:
            if ret is None:
                malformed["read_without_return"] += 1
                add_unresolved("read_without_return", rawline)
                return
            if ret >= 0:
                recognized["useful_read"] += 1
                add_process_event(pid, "read_calls")
                if ret > 0:
                    read_totals["calls"] += 1
                    read_totals["bytes"] += ret
                    add_process_event(pid, "positive_read_syscalls")
                    add_process_event(pid, "positive_read_bytes", ret)
                    event = "positive_read_bytes"
                    amount = ret
                else:
                    add_process_event(pid, "zero_read_attempts")
                    event = "zero_read_attempts"
                    amount = 1
                if not fd_paths and argv:
                    add_unresolved("read_fd_without_path_annotation", rawline)
                for rawpath in fd_paths:
                    indexes, _, _ = resolve(pid, rawpath, call)
                    for index in indexes:
                        accesses[index][event] += amount
                        accesses[index]["read_calls"] += 1
                        add_input_event(index, pid, event, amount)
            return

        if call in MMAP_CALLS:
            if ret is not None and ret >= 0:
                recognized["successful_mmap"] += 1
                add_process_event(pid, "mmap_calls")
                for rawpath in fd_paths:
                    indexes, _, _ = resolve(pid, rawpath, call)
                    for index in indexes:
                        accesses[index]["mmap_calls"] += 1
                        add_input_event(index, pid, "mmap_calls")
            return

        if call in OPEN_CALLS and ret is not None and ret >= 0:
            if read_open:
                add_process_event(pid, "read_open_syscalls")
            if write_open:
                add_process_event(pid, "write_open_syscalls")
            if creating_open:
                add_process_event(pid, "create_open_syscalls")
            for rawpath in paths:
                indexes, _, _ = resolve(pid, rawpath, call, base)
                for index in indexes:
                    if write_open:
                        accesses[index]["write_open_calls"] += 1
                        add_input_event(index, pid, "write_open_calls")
                    if creating_open:
                        accesses[index]["create_open_calls"] += 1
                        add_input_event(index, pid, "create_open_calls")
        metadata_access = call not in OPEN_CALLS or read_open
        if call in METADATA_CALLS and ret is not None and ret >= 0 and metadata_access:
            add_process_event(pid, "metadata_operations")
            for rawpath in paths:
                indexes, _, _ = resolve(pid, rawpath, call, base)
                for index in indexes:
                    accesses[index]["metadata_operations"] += 1
                    add_input_event(index, pid, "metadata_operations")
                    if call in OPEN_CALLS and read_open:
                        accesses[index]["read_open_calls"] += 1
                        add_input_event(index, pid, "read_open_calls")
            for rawpath in fd_paths:
                indexes, _, _ = resolve(pid, rawpath, call)
                for index in indexes:
                    accesses[index]["metadata_operations"] += 1
                    add_input_event(index, pid, "metadata_operations")
            return

        if call == "execve" and ret == 0:
            values = c_strings(args)
            if values:
                commands[pid] = values[0]
                if len(argv) > 1:
                    arg_values = c_strings(argv[1])
                    if arg_values:
                        commands[pid] = " ".join(arg_values)

    def dispatch(pid, call, args, ret, ret_path, rawline):
        arguments = split_arguments(args)
        if call in AT_PATH_CALLS and arguments:
            at_cwd = AT_FDCWD_ANNOTATION.match(arguments[0])
            if at_cwd:
                cwd_by_pid[pid] = normalize_path(at_cwd.group(1), cwd_by_pid.get(pid))
        if call == "chdir" and ret == 0:
            values = c_strings(args)
            if values:
                cwd_by_pid[pid] = normalize_path(values[0], cwd_by_pid.get(pid))
        elif call == "getcwd" and ret is not None and ret >= 0:
            values = c_strings(args)
            if values:
                cwd_by_pid[pid] = normalize_path(values[0], cwd_by_pid.get(pid))
        elif call == "fchdir" and ret == 0 and arguments:
            values = [match.group(2) for match in FD_ANNOTATION.finditer(arguments[0])]
            if values:
                cwd_by_pid[pid] = normalize_path(values[0], cwd_by_pid.get(pid))
        if call in {"clone", "clone3", "fork", "vfork"} and ret is not None and ret > 0:
            parent[ret] = pid
            if pid in cwd_by_pid:
                cwd_by_pid.setdefault(ret, cwd_by_pid[pid])
            if pid in commands:
                commands.setdefault(ret, commands[pid])
        record(pid, call, args, ret, ret_path, rawline)

    clone_pending = {}
    for candidate in lines:
        prefix = TRACE_PREFIX.match(candidate)
        if not prefix:
            continue
        source_pid = int(prefix.group(1) or prefix.group(2) or 0)
        text = prefix.group(3)
        if not source_pid:
            continue
        resumed_match = RESUMED.match(text)
        if resumed_match:
            call = resumed_match.group(1)
            prior = clone_pending.pop(source_pid, None)
            if prior and prior[0] == call:
                complete = call + "(" + prior[1] + resumed_match.group(2)
                results = list(RETURN.finditer(complete))
                result = results[-1] if results else None
                child_pid = return_value(result)
                if call in {"clone", "clone3", "fork", "vfork"} and child_pid and child_pid > 0:
                    parent[child_pid] = source_pid
            continue
        syscall_match = SYSCALL.match(text)
        if not syscall_match:
            continue
        call, remainder = syscall_match.group(1), syscall_match.group(2)
        if "<unfinished ...>" in remainder:
            clone_pending[source_pid] = (call, remainder.split("<unfinished ...>", 1)[0].rstrip())
            continue
        results = list(RETURN.finditer(remainder))
        result = results[-1] if results else None
        child_pid = return_value(result)
        if call in {"clone", "clone3", "fork", "vfork"} and child_pid and child_pid > 0:
            parent[child_pid] = source_pid

    def inherit_identity(pid):
        ancestor = parent.get(pid)
        if ancestor is None:
            return
        if ancestor in parent:
            inherit_identity(ancestor)
        if ancestor in commands:
            commands.setdefault(pid, commands[ancestor])
        if ancestor in cwd_by_pid:
            cwd_by_pid.setdefault(pid, cwd_by_pid[ancestor])

    for line_number, rawline in enumerate(lines, 1):
        match = TRACE_PREFIX.match(rawline)
        if not match:
            malformed["unrecognized_line"] += 1
            continue
        pid = int(match.group(1) or match.group(2) or 0)
        inherit_identity(pid)
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
            return_matches = list(RETURN.finditer(complete))
            result = return_matches[-1] if return_matches else None
            syscall_args = complete[len(call) + 1:result.start()] + ")" if result else syscall_match.group(2)
            dispatch(pid, call, syscall_args, return_value(result), return_path(result), rawline)
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
        return_matches = list(RETURN.finditer(remainder))
        result = return_matches[-1] if return_matches else None
        ret = return_value(result)
        args = remainder[:result.start()] + ")" if result else remainder
        dispatch(pid, call, args, ret, return_path(result), rawline)
    if pending:
        malformed["unfinished_at_eof"] += len(pending)
        for pid, (call, args) in pending.items():
            add_unresolved("unfinished_at_eof", f"pid={pid} {call}({args} <unfinished ...>")
    if recognized["useful_read"] == 0 and recognized["successful_mmap"] == 0:
        raise ValueError("trace contains no completed read or successful mmap observations")


    def classify(counts):
        if counts["positive_read_bytes"]:
            return "positive_bytes_read"
        if counts["zero_read_attempts"]:
            return "zero_read_attempt"
        if counts["mmap_calls"]:
            return "mapped_only"
        if counts["metadata_operations"]:
            return "metadata_only"
        return "not_observed"

    output_records = []
    unread = []
    for index, source in enumerate(records):
        counts = accesses[index]
        category = classify(counts)
        if category == "not_observed":
            unread.append(source["exec_path"])
        process_observations_by_name = process_observations[index]
        non_staging = collections.Counter()
        by_category = collections.defaultdict(collections.Counter)
        for name, events in process_observations_by_name.items():
            kind = process_kind(name)
            for event, amount in events.items():
                by_category[kind][event] += amount
                if name not in STAGING_HELPERS:
                    non_staging[event] += amount
        semantic_counts = collections.Counter({
            "positive_read_bytes": non_staging["positive_read_bytes"],
            "zero_read_attempts": non_staging["zero_read_attempts"],
            "mmap_calls": non_staging["mmap_calls"],
            "metadata_operations": non_staging["metadata_operations"],
        })
        semantic_classification = classify(semantic_counts)
        process_details = {
            name: {"process_category": process_kind(name), **dict(sorted(events.items()))}
            for name, events in sorted(process_observations_by_name.items())
        }
        output_records.append({
            **source,
            "classification": category,
            "non_staging_classification": semantic_classification,
            "observed_positive_read_bytes": counts["positive_read_bytes"],
            "zero_read_attempts": counts["zero_read_attempts"],
            "read_calls": counts["read_calls"],
            "read_open_calls": counts["read_open_calls"],
            "write_open_calls": counts["write_open_calls"],
            "create_open_calls": counts["create_open_calls"],
            "mmap_calls": counts["mmap_calls"],
            "metadata_operations": counts["metadata_operations"],
            "process_observations": process_details,
            "read_bytes_by_process_category": {kind: stats["positive_read_bytes"] for kind, stats in sorted(by_category.items()) if stats["positive_read_bytes"]},
            "metadata_operations_by_process_category": {kind: stats["metadata_operations"] for kind, stats in sorted(by_category.items()) if stats["metadata_operations"]},
            "mmap_by_process_category": {kind: stats["mmap_calls"] for kind, stats in sorted(by_category.items()) if stats["mmap_calls"]},
            "mapping_observation_is_not_page_read_proof": bool(counts["mmap_calls"]),
        })
    classes = collections.Counter(row["classification"] for row in output_records)
    non_staging_classes = collections.Counter(row["non_staging_classification"] for row in output_records)
    canonical_groups = collections.defaultdict(list)
    for i, row in enumerate(records):
        canonical_groups[os.path.normcase(os.path.normpath(row["real_path"]))].append(i)
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
        elif "example" in components and not (
            "examples" in components and components.index("example") < components.index("examples")
        ):
            group = "example"
        else:
            group = "other"
        grouped[group][row["classification"]] += 1
    by_kind = collections.Counter(process_kind(value) for value in commands.values())
    activity_by_category = {kind: dict(sorted(values.items())) for kind, values in sorted(process_totals.items())}
    staging_activity = {name: dict(sorted(values.items())) for name, values in sorted(staging_process_totals.items())}
    summary = {
        "declared_input_paths": len(records),
        "unique_canonical_paths": len(canonical_groups),
        "path_classification_counts": dict(sorted(classes.items())),
        "non_staging_path_classification_counts": dict(sorted(non_staging_classes.items())),
        "canonical_classification_counts": dict(sorted(canonical_counts.items())),
        "groups": {name: dict(sorted(counts.items())) for name, counts in sorted(grouped.items())},
        "process_activity_by_category": activity_by_category,
        "staging_process_activity": staging_activity,
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
            "processes_with_known_command": len(commands),
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
        records, exec_index, real_index = load_inventory(args.inputs)
        summary, classified = parse_trace(args.trace, records, exec_index, real_index, args.execroot)
        out = Path(args.output_dir)
        out.mkdir(parents=True, exist_ok=True)
        (out / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        (out / "input-classification.json").write_text(json.dumps(classified, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        counts = summary["path_classification_counts"]
        semantic_counts = summary["non_staging_path_classification_counts"]
        trace = summary["trace"]
        lines = [
            "# Asset input read observations", "",
            f"- Declared paths: {summary['declared_input_paths']} ({summary['unique_canonical_paths']} unique canonical paths)",
            "- Whole-action classifications: " + ", ".join(f"{key}={value}" for key, value in sorted(counts.items())),
            "- Excluding staging-helper processes: " + ", ".join(f"{key}={value}" for key, value in sorted(semantic_counts.items())),
            f"- Completed read syscalls: {trace['completed_read_syscalls']}; positive-byte read syscalls: {trace['positive_bytes_read_syscalls']}; bytes: {trace['positive_bytes_read_total']}",
            f"- mmap syscalls: {trace['mmap_syscalls']} (mapping is not proof that mapped pages were read)",
            f"- Unresolved observations: {sum(trace['unresolved_counts'].values())}; malformed/incomplete counters: {sum(trace['malformed_or_incomplete'].values())}",
            "- Process activity by category: " + json.dumps(summary["process_activity_by_category"], sort_keys=True, separators=(",", ":")),
            f"- Unread candidates: {summary['unread_candidate_count']} (not a safely-unused determination)", "",
        ]
        (out / "summary.md").write_text("\n".join(lines), encoding="utf-8")
    except (ValueError, OSError) as exc:
        print(f"asset read trace: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
