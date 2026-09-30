#!/usr/bin/env python3
"""Shows that the cache never serves an ActionResult whose output Tree holds a zero-byte file.

  probe.py bazel EXEC_LOG_1 EXEC_LOG_2   Bazel builds //... twice (upload, then after
                                         `clean --expunge`) and looks up each action.
  probe.py grpclog GRPC_LOG...           Prints the cache calls Bazel itself recorded
                                         (--remote_grpc_log) for the diag actions.
  probe.py raw                           Same check through raw REAPI calls, no Bazel.

Env: CACHE_HOST (host[:port]), CACHE_INSTANCE, CACHE_TOKEN, PROTO_ROOTS (colon-separated
import paths holding build/bazel/remote/execution/v2 and google/{api,longrunning,rpc}).
Every case is expected to be served; each one that is not becomes a GitHub error annotation,
and the exit status is 1.
"""

import base64
import hashlib
import json
import os
import subprocess
import sys
import time

HOST = os.environ["CACHE_HOST"].removeprefix("grpcs://")
HOST = HOST if ":" in HOST else HOST + ":443"
INSTANCE = os.environ["CACHE_INSTANCE"]
TOKEN = os.environ["CACHE_TOKEN"]
PROTO = [a for root in os.environ["PROTO_ROOTS"].split(":") for a in ("-import-path", root)]
PROTO += ["-proto", "build/bazel/remote/execution/v2/remote_execution.proto"]
V2 = "build.bazel.remote.execution.v2."
EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()

failures = []


def call(method, request):
    """Returns (ok, text) for one unary REAPI call."""
    r = subprocess.run(
        ["grpcurl", "-H", f"Authorization: Bearer {TOKEN}", *PROTO, "-d", "@", HOST, V2 + method],
        input=json.dumps(request),
        capture_output=True,
        text=True,
    )
    return r.returncode == 0, " ".join((r.stdout + r.stderr).replace(TOKEN, "***").split())


def lookup(digest):
    ok, text = call("ActionCache/GetActionResult", {"instance_name": INSTANCE, "action_digest": digest})
    return ("found" if ok else "NOT FOUND"), text


def fail(message):
    failures.append(message)
    print(f"::error::{message}")


# --- Bazel ---------------------------------------------------------------------------------


def spawns(path):
    decoder, text, i, out = json.JSONDecoder(), open(path).read(), 0, {}
    while True:
        while i < len(text) and text[i].isspace():
            i += 1
        if i == len(text):
            return out
        spawn, i = decoder.raw_decode(text, i)
        if spawn.get("mnemonic", "").startswith("Diag"):
            out[spawn["targetLabel"]] = spawn


def bazel(log1, log2):
    first, second = spawns(log1), spawns(log2)
    print(f"{'target':<18} {'output file sizes':<18} {'build 1':<9} {'build 2':<9} GetActionResult  action digest")
    for label, spawn in sorted(first.items()):
        sizes = ",".join(o["digest"].get("sizeBytes", "0") for o in spawn["actualOutputs"])
        hit2 = second[label]["cacheHit"]
        digest = {"hash": spawn["digest"]["hash"], "size_bytes": spawn["digest"]["sizeBytes"]}
        status, _ = lookup(digest)
        print(
            f"{label:<18} {sizes:<18} {'hit' if spawn['cacheHit'] else 'executed':<9} "
            + f"{'hit' if hit2 else 'executed':<9} {status:<16} {digest['hash']}/{digest['size_bytes']}",
        )
        if not hit2 or status != "found":
            fail(
                f"{label}: build 1 executed and uploaded it, yet after `bazel clean --expunge` build 2 "
                + f"executed it again and GetActionResult says {status} (outputs of sizes {sizes}).",
            )


# Status codes from google/rpc/code.proto that this repro can meet.
CODES = {0: "OK", 5: "NOT_FOUND", 9: "FAILED_PRECONDITION", 3: "INVALID_ARGUMENT", 8: "RESOURCE_EXHAUSTED"}


def _read_varint(data, i):
    n = shift = 0
    while True:
        byte = data[i]
        i += 1
        n |= (byte & 0x7F) << shift
        shift += 7
        if byte < 0x80:
            return n, i


def _fields(data):
    """First occurrence of each field number in a serialized message; nested ones stay bytes."""
    i, out = 0, {}
    while i < len(data):
        key, i = _read_varint(data, i)
        wire = key & 7
        if wire == 0:
            value, i = _read_varint(data, i)
        elif wire == 2:
            size, i = _read_varint(data, i)
            value, i = data[i:i + size], i + size
        else:  # fixed64 / fixed32
            size = 8 if wire == 1 else 4
            value, i = data[i:i + size], i + size
        out.setdefault(key >> 3, value)
    return out


def grpclog(*paths):
    """Decodes Bazel's --remote_grpc_log: varint-delimited LogEntry messages
    (src/main/protobuf/remote_execution_log.proto: metadata=1, status=2, method_name=3),
    RequestMetadata (action_id=2, action_mnemonic=5, target_id=6), google.rpc.Status (code=1)."""
    print(f"{'build':<6} {'target':<18} {'call':<20} {'status':<10} action digest")
    for build, path in enumerate(paths, 1):
        data, i = open(path, "rb").read(), 0
        while i < len(data):
            size, i = _read_varint(data, i)
            entry, i = _fields(data[i:i + size]), i + size
            metadata, status = _fields(entry.get(1, b"")), _fields(entry.get(2, b""))
            if not metadata.get(5, b"").startswith(b"Diag"):
                continue
            code = status.get(1, 0)
            print(
                f"{build:<6} {metadata[6].decode():<18} {entry[3].decode().rsplit('/', 1)[-1]:<20} "
                + f"{CODES.get(code, code):<10} {metadata.get(2, b'').decode()}",
            )



# --- Raw REAPI -----------------------------------------------------------------------------


def field(number, payload):
    """A length-delimited protobuf field."""
    return _varint(number << 3 | 2) + _varint(len(payload)) + payload


def _varint(n):
    out = b""
    while n > 0x7F:
        out += bytes([n & 0x7F | 0x80])
        n >>= 7
    return out + bytes([n])


def digest_of(blob):
    return {"hash": hashlib.sha256(blob).hexdigest(), "size_bytes": str(len(blob))}


def digest_proto(blob):
    d = digest_of(blob)
    proto = field(1, d["hash"].encode())
    return proto + (_varint(2 << 3) + _varint(len(blob)) if blob else b"")  # size_bytes, omitted when 0


def tree_with_files(files):
    """Serialized Tree whose root Directory holds `files` ({name: content}, sorted by name)."""
    directory = b"".join(field(1, field(1, name.encode()) + field(2, digest_proto(content))) for name, content in sorted(files.items()))
    return field(1, directory)


def raw():
    stamp = f"{os.environ.get('GITHUB_RUN_ID', 'local')}-{time.time_ns()}"
    ok, text = call("ContentAddressableStorage/FindMissingBlobs", {"instance_name": INSTANCE, "blob_digests": [digest_of(b"")]})
    print(f"FindMissingBlobs([{EMPTY_SHA256}/0]) -> {text}  (empty = the server has it)\n")
    cases = [
        ("Tree: one 1-byte file", {"payload": b"x"}, False),
        ("Tree: one 0-byte file", {"payload": b""}, False),
        ("Tree: 1-byte and 0-byte file", {"a": b"x", "b": b""}, False),
        ("Tree: one 0-byte file, empty blob uploaded first", {"payload": b""}, True),
        ("output_files: one 0-byte file", None, False),
    ]
    print(f"{'ActionResult':<50} {'UpdateActionResult':<19} GetActionResult")
    for name, files, upload_empty in cases:
        # A made-up action digest: no real build computes this key.
        action = f"rules_flutter empty-tree diag {stamp} {name}".encode()
        blobs = [c for c in (files or {}).values() if c or upload_empty]
        result = {"exit_code": 0}
        if files is None:
            result["output_files"] = [{"path": "out/payload", "digest": digest_of(b"")}]
        else:
            tree = tree_with_files(files)
            blobs.append(tree)
            result["output_directories"] = [{"path": "out/dir", "tree_digest": digest_of(tree), "is_topologically_sorted": True}]
        requests = [{"digest": digest_of(b), "data": base64.b64encode(b).decode()} for b in blobs]
        if requests:
            ok, text = call("ContentAddressableStorage/BatchUpdateBlobs", {"instance_name": INSTANCE, "requests": requests})
            if not ok:
                sys.exit(f"BatchUpdateBlobs failed: {text}")
        ok, text = call("ActionCache/UpdateActionResult", {"instance_name": INSTANCE, "action_digest": digest_of(action), "action_result": result})
        update = "OK" if ok else "error: " + text
        time.sleep(1)
        status, text = lookup(digest_of(action))
        print(f"{name:<50} {update:<19} {status}")
        if status != "found":
            fail(f"{name}: UpdateActionResult returned {update}, then GetActionResult returned {text}")


if __name__ == "__main__":
    {"bazel": lambda: bazel(*sys.argv[2:4]), "grpclog": lambda: grpclog(*sys.argv[2:]), "raw": raw}[sys.argv[1]]()
    sys.exit(1 if failures else 0)
