#!/usr/bin/env python3
"""Compare declared Flutter asset inputs and trace reads by the bundle action."""
from __future__ import annotations
import argparse, difflib, gzip, hashlib, json, os, shutil, subprocess, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
BASELINE = "42c9011"
TARGET = "//:app_assets"
TRACE_SYSCALLS = "open,openat,openat2,creat,stat,lstat,fstat,newfstatat,statx,access,faccessat,faccessat2,readlink,readlinkat,read,readv,pread64,preadv,preadv2,copy_file_range,sendfile,sendfile64,splice,ioctl,mmap,mmap2,close,dup,dup2,dup3,fcntl,execve,clone,clone3,fork,vfork,chdir,fchdir,getcwd"

def capture(out, name, argv, cwd, env):
    out.mkdir(parents=True, exist_ok=True)
    (out / f"{name}.command.txt").write_text(json.dumps({"cwd":str(cwd),"env":{k:env[k] for k in ("BAZEL_OUTPUT_BASE","FLUTTER_ROOT") if k in env},"argv":argv},indent=2)+"\n")
    with (out/f"{name}.stdout.txt").open("wb") as stdout, (out/f"{name}.stderr.txt").open("wb") as stderr:
        result=subprocess.run(argv,cwd=cwd,env=env,stdout=stdout,stderr=stderr,check=False)
    (out/f"{name}.exit.txt").write_text(f"{result.returncode}\n")
    return result

def run(out,name,argv,cwd,env):
    p=capture(out,name,argv,cwd,env)
    if p.returncode: raise RuntimeError(f"{name} failed with exit {p.returncode}")
    return (out/f"{name}.stdout.txt").read_bytes()

def artifact_path(doc, artifact_id):
    artifacts={int(x["id"]):x for x in doc.get("artifacts",[])}
    fragments={int(x["id"]):x for x in doc.get("pathFragments",[])}
    node=int(artifacts[artifact_id]["pathFragmentId"]); parts=[]
    while node:
        item=fragments[node]; parts.append(item["label"]); node=int(item.get("parentId",0))
    return "/".join(reversed(parts))

def action(doc):
    found=[a for a in doc.get("actions",[]) if a.get("mnemonic")=="FlutterAssets"]
    if len(found)!=1: raise RuntimeError(f"expected one FlutterAssets action, found {len(found)}")
    return found[0]

def input_paths(doc):
    sets={int(x["id"]):x for x in doc.get("depSetOfFiles",[])}; ids=set(); seen=set()
    def visit(idx):
        if idx in seen:return
        seen.add(idx); item=sets[idx]; ids.update(int(x) for x in item.get("directArtifactIds",[]))
        for child in item.get("transitiveDepSetIds",[]):visit(int(child))
    for idx in action(doc).get("inputDepSetIds",[]):visit(int(idx))
    return sorted(artifact_path(doc,i) for i in ids)

def manifest(directory):
    result={}
    for path in sorted(directory.rglob("*")):
        if path.is_file():
            data=path.read_bytes(); result[path.relative_to(directory).as_posix()]={"size":len(data),"sha256":hashlib.sha256(data).hexdigest()}
    return result

def instrument(path,evidence):
    original=path.read_bytes(); text=original.decode()
    load='load("@bazel_skylib//lib:shell.bzl", "shell")\n'
    anchor='load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")\n'
    start=text.index("def _flutter_assets_impl(ctx):"); end=text.index("\nflutter_assets = rule(",start); body=text[start:end]
    action_anchor='    )\n\n    ctx.actions.run_shell(\n        command = cmd,'
    if text.count(anchor)!=1 or body.count(action_anchor)!=1:raise RuntimeError("cannot uniquely instrument FlutterAssets action")
    text=text.replace(anchor,anchor+load); start=text.index("def _flutter_assets_impl(ctx):"); end=text.index("\nflutter_assets = rule(",start); body=text[start:end]
    wrapper='''    )
    trace = ctx.actions.declare_file(ctx.label.name + ".read-trace")
    cmd = "strace -f -yy -s 128 -e trace=__TRACE_SYSCALLS__ -o {} /bin/bash -c {}".format(shell.quote(trace.path), shell.quote(cmd))

    ctx.actions.run_shell(
        command = cmd,'''
    wrapper = wrapper.replace("__TRACE_SYSCALLS__", TRACE_SYSCALLS)
    body=body.replace(action_anchor,wrapper,1)
    if body.count("outputs = [out],")!=1 or body.count("return [DefaultInfo(files = depset([out]))]")!=1:raise RuntimeError("unexpected FlutterAssets output structure")
    body=body.replace("outputs = [out],","outputs = [out, trace],",1)
    body=body.replace("return [DefaultInfo(files = depset([out]))]","return [DefaultInfo(files = depset([out])), OutputGroupInfo(asset_read_trace = depset([trace]))]",1)
    text=text[:start]+body+text[end:]; path.write_text(text)
    (evidence/"instrumentation.patch").write_text("".join(difflib.unified_diff(original.decode().splitlines(True),text.splitlines(True),fromfile="rules.bzl.before",tofile="rules.bzl.instrumented")))
    (evidence/"instrumented-rules.sha256").write_text(hashlib.sha256(path.read_bytes()).hexdigest()+"\n")
    return original

def parser_control(evidence,env):
    control=evidence/"parser-control"; control.mkdir(exist_ok=True)
    (control/"read file").write_text("abc"); (control/"zero").write_bytes(b""); (control/"metadata").write_text("x"); (control/"unobserved").write_text("x")
    inputs=[{"exec_path":f"control/{name}","real_path":str(control/name),"size":size} for name,size in (("read file",3),("zero",0),("metadata",1),("unobserved",1))]
    (control/"inputs.json").write_text(json.dumps(inputs))
    path=str(control/"read file")
    (control/"trace.log").write_text(f'1 openat(AT_FDCWD, "{path}", O_RDONLY) = 3<{path}>\n1 read(3<{path}>, "abc", 3 <unfinished ...>\n1 <... read resumed>) = 3\n1 read(4<{control / "zero"}>, "", 1) = 0\n1 newfstatat(AT_FDCWD, "{control / "metadata"}", {{}}, 0) = 0\n')
    argv=[sys.executable,str(ROOT/"tools/ci/asset_read_trace.py"),"--inputs",str(control/"inputs.json"),"--trace",str(control/"trace.log"),"--execroot",str(control),"--output-dir",str(control/"parsed")]
    run(control,"parser-control",argv,ROOT,env)
    rows=json.loads((control/"parsed/input-classification.json").read_text())
    expected=["positive_source_bytes","zero_read_attempt","metadata_only","not_observed"]
    if [x["classification"] for x in rows]!=expected:raise RuntimeError("parser control classifications differ")
    # Exercise the installed tracer before spending resources on either build.
    actual_trace = control / "actual.trace"
    control_code = "import pathlib,sys; p=pathlib.Path(sys.argv[1]); (p/'read file').read_bytes(); (p/'zero').read_bytes(); (p/'metadata').stat()"
    run(control, "actual-strace", ["strace", "-f", "-yy", "-s", "128", "-e", "trace=" + TRACE_SYSCALLS, "-o", str(actual_trace), sys.executable, "-c", control_code, str(control)], ROOT, env)
    actual_argv = list(argv)
    actual_argv[actual_argv.index("--trace") + 1] = str(actual_trace)
    actual_argv[actual_argv.index("--output-dir") + 1] = str(control / "actual-parsed")
    run(control, "actual-parse", actual_argv, ROOT, env)
    actual_rows = json.loads((control / "actual-parsed/input-classification.json").read_text())
    if [row["classification"] for row in actual_rows] != expected:
        raise RuntimeError("actual strace control classifications differ")
    copy_trace = control / "copy.trace"
    run(control, "actual-copy", ["strace", "-f", "-yy", "-s", "128", "-e", "trace=" + TRACE_SYSCALLS, "-o", str(copy_trace), "/bin/cp", "--reflink=never", str(control / "read file"), str(control / "copied file")], ROOT, env)
    copy_argv = list(argv)
    copy_inputs = inputs + [{"exec_path": "control/copied file", "real_path": str(control / "copied file"), "size": 3}]
    (control / "copy-inputs.json").write_text(json.dumps(copy_inputs))
    copy_argv[copy_argv.index("--inputs") + 1] = str(control / "copy-inputs.json")
    copy_argv[copy_argv.index("--trace") + 1] = str(copy_trace)
    copy_argv[copy_argv.index("--output-dir") + 1] = str(control / "copy-parsed")
    run(control, "actual-copy-parse", copy_argv, ROOT, env)
    copy_rows = json.loads((control / "copy-parsed/input-classification.json").read_text())
    if copy_rows[0]["observed_positive_source_bytes"] != 3 or copy_rows[-1]["classification"] == "positive_source_bytes" or (control / "copied file").read_bytes() != b"abc":
        raise RuntimeError("actual copy control source-byte observation failed")

def disk(out,name):
    capture(out,name,["df","-h",str(ROOT)],ROOT,dict(os.environ))

def main():
    p=argparse.ArgumentParser();p.add_argument("--evidence-dir",type=Path,required=True);args=p.parse_args()
    evidence=args.evidence_dir.resolve();evidence.mkdir(parents=True,exist_ok=True);temp=Path(os.environ["RUNNER_TEMP"]);bazel=str(temp/"bazel")
    disk(evidence,"before"); env0=dict(os.environ)
    if shutil.which("strace") is None:
        for name,argv in (("strace-update",["sudo","apt-get","update"]),("strace-install",["sudo","apt-get","install","-y","strace"])):
            if capture(evidence,name,argv,ROOT,env0).returncode:raise RuntimeError(f"{name} failed")
    baseline=temp/"asset-input-baseline-worktree"
    if capture(evidence,"baseline-worktree",["git","worktree","add","--detach",str(baseline),BASELINE],ROOT,env0).returncode:raise RuntimeError("baseline unavailable; checkout must fetch history")
    bases=[]; original_rules=None; instrumented_path=None; results={}
    try:
        parser_control(evidence,env0)
        for arm,tree in (("baseline",baseline),("instrumented",ROOT)):
            out=evidence/arm;out.mkdir(parents=True,exist_ok=True);disk(out,"before-phase")
            module=tree/"rules_flutter_core";cwd=tree/"examples/pub_plugins";ob=temp/f"asset-input-{arm}-output-base";bases.append((ob,cwd))
            env=dict(os.environ,BAZEL_OUTPUT_BASE=str(ob));start=[bazel,f"--output_base={ob}","--host_jvm_args=-XX:ActiveProcessorCount=4"]
            if arm=="instrumented":instrumented_path=module/"flutter/private/rules.bzl";original_rules=instrument(instrumented_path,out)
            run(out,"bazel-version",[bazel,"--version"],cwd,env);run(out,"flutter-version",["flutter","--version"],cwd,env)
            context={"flutter_version":(out/"flutter-version.stdout.txt").read_text()}
            version_file=Path(env.get("FLUTTER_ROOT",""))/"bin/cache/flutter.version.json"
            context["flutter_version_file"]=str(version_file)
            if version_file.is_file():context["flutter_version_json"]=json.loads(version_file.read_text())
            config_files=[tree/".bazelrc",module/".bazelrc",module/".bazelversion",cwd/".bazelrc"]
            context["bazel_config_files"]={str(x.relative_to(tree)):hashlib.sha256(x.read_bytes()).hexdigest() for x in config_files if x.is_file()}
            (out/"runtime-context.json").write_text(json.dumps(context,indent=2)+"\n")
            execroot=Path(run(out,"execution-root",start+["info","execution_root"],cwd,env).decode().strip())
            run(out,"build",start+["build","--jobs=1","--lockfile_mode=error","--disk_cache=","--remote_cache=","--noshow_progress",TARGET],cwd,env)
            aq=run(out,"aquery",start+["aquery","--lockfile_mode=error","--noshow_progress","--output=jsonproto",f'mnemonic("FlutterAssets", deps({TARGET}))'],cwd,env)
            (out/"aquery.json").write_bytes(aq);doc=json.loads(aq);act=action(doc);inputs=input_paths(doc)
            (out/"declared-inputs.json").write_text(json.dumps(inputs,indent=2)+"\n");outputs=[artifact_path(doc,int(i)) for i in act.get("outputIds",[])]
            (out/"action-outputs.json").write_text(json.dumps(outputs,indent=2)+"\n")
            (out/"action-metadata.json").write_text(json.dumps({"action_key":act.get("actionKey"),"mnemonic":act.get("mnemonic"),"argv":act.get("arguments"),"environment":act.get("environmentVariables")},indent=2)+"\n")
            cq=run(out,"cquery",start+["cquery","--lockfile_mode=error","--noshow_progress","--output=files",TARGET],cwd,env).decode().splitlines();(out/"cquery-outputs.txt").write_text("\n".join(cq)+"\n")
            assets=next((execroot/x for x in cq if x.endswith("/flutter_assets")),None)
            if not assets or not assets.is_dir():raise RuntimeError(f"could not resolve actual asset directory from cquery: {cq}")
            treehash=manifest(assets);(out/"asset-tree.sha256.json").write_text(json.dumps(treehash,indent=2)+"\n")
            if arm=="instrumented":
                trace_rel=next((x for x in outputs if x.endswith(".read-trace")),None)
                if not trace_rel:raise RuntimeError("aquery omitted diagnostic trace output")
                trace=execroot/trace_rel
                if not trace.is_file():raise RuntimeError(f"trace output missing: {trace}")
                with trace.open("rb") as src,gzip.open(evidence/"trace.log.gz","wb") as dst:shutil.copyfileobj(src,dst)
                inventory=[{"exec_path":x,"real_path":str((execroot/x).resolve()),"size":((execroot/x).stat().st_size if (execroot/x).is_file() else None)} for x in inputs]
                (evidence/"inputs.json").write_text(json.dumps(inventory,indent=2)+"\n")
                with gzip.open(evidence/"trace.log.gz","rb") as src,(evidence/"trace.log").open("wb") as dst:shutil.copyfileobj(src,dst)
                parser_cmd=[sys.executable,str(ROOT/"tools/ci/asset_read_trace.py"),"--inputs",str(evidence/"inputs.json"),"--trace",str(evidence/"trace.log"),"--execroot",str(execroot),"--output-dir",str(evidence/"parsed")]
                run(evidence,"parse-trace",parser_cmd,ROOT,env);(evidence/"trace.log").unlink();shutil.copytree(assets,evidence/"asset-tree",dirs_exist_ok=True)
                print((evidence/"parsed/summary.md").read_text())
            results[arm]={"inputs":inputs,"tree":treehash}
            run(out,"shutdown",start+["shutdown"],cwd,env);disk(out,"after-phase")
            if arm=="baseline":shutil.rmtree(ob,ignore_errors=True)
        if results["baseline"]["inputs"]!=results["instrumented"]["inputs"]:raise RuntimeError("baseline and instrumented declared inputs differ")
        if results["baseline"]["tree"]!=results["instrumented"]["tree"]:raise RuntimeError("baseline and instrumented asset trees differ")
        (evidence/"comparison.json").write_text(json.dumps(results,indent=2)+"\n");disk(evidence,"after")
        print("Baseline and traced FlutterAssets inputs and output tree match.");return 0
    finally:
        if original_rules is not None and instrumented_path is not None:
            instrumented_path.write_bytes(original_rules)
            (evidence/"restored-rules.sha256").write_text(hashlib.sha256(instrumented_path.read_bytes()).hexdigest()+"\n")
        for i,(ob,cwd) in enumerate(bases):
            if ob.exists():
                shutdown=capture(evidence,f"shutdown-final-{i}",[bazel,f"--output_base={ob}","--host_jvm_args=-XX:ActiveProcessorCount=4","shutdown"],cwd,dict(os.environ,BAZEL_OUTPUT_BASE=str(ob)))
                if shutdown.returncode==0:
                    shutil.rmtree(ob,ignore_errors=True)
                    (evidence/f"output-base-{i}-removed.txt").write_text(str(ob)+"\n")
        capture(evidence,"baseline-worktree-remove",["git","worktree","remove","--force",str(baseline)],ROOT,env0)

if __name__=="__main__":
    try:raise SystemExit(main())
    except (OSError,RuntimeError,KeyError,ValueError,StopIteration) as exc:print(f"asset input proof failed: {exc}",file=sys.stderr);raise SystemExit(1)
