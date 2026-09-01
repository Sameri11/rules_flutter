#!/usr/bin/env python3
"""Check the source-level contracts that keep Flutter actions portable."""

import argparse
import ast
import re
import sys
from pathlib import Path


FILES = {
    "repo": "tools/flutter/repo.bzl",
    "defs": "tools/flutter/defs.bzl",
    "android": "tools/flutter/android.bzl",
    "plugins": "tools/flutter/plugins.bzl",
    "ndk": "tools/flutter/ndk.bzl",
}


class Checker:
    """Small AST/source-shape checks; every failure is reported at the end."""

    def __init__(self, root):
        self.root = root
        self.sources = {}
        self.trees = {}
        self.failures = []

    def fail(self, contract, message):
        self.failures.append("FAIL {}: {}".format(contract, message))

    def load(self):
        for name, relative in FILES.items():
            path = self.root / relative
            try:
                source = path.read_text(encoding="utf-8")
            except (OSError, UnicodeError) as error:
                self.fail("SOURCE", "{} cannot be read: {}".format(relative, error))
                continue
            self.sources[name] = source
            try:
                self.trees[name] = ast.parse(source, filename=relative)
            except SyntaxError as error:
                self.fail(
                    _file_contract(name),
                    "{} is not Python-AST compatible at line {}: {}".format(
                        relative,
                        error.lineno or "?",
                        error.msg,
                    ),
                )

    def run(self):
        self.load()
        self.check_a()
        self.check_b()
        self.check_c()
        self.check_d()
        self.check_e()
        self.check_f()
        self.check_g()
        self.check_h()
        return self.failures

    def tree(self, name, contract):
        tree = self.trees.get(name)
        if tree is None:
            self.fail(contract, "{} could not be parsed; required source shape is unavailable".format(FILES[name]))
        return tree

    def check_a(self):
        tree = self.tree("repo", "A")
        if tree is None:
            return

        resolve = _function(tree, "_resolve_flutter_root")
        if resolve is None:
            self.fail("A", "repo.bzl must define _resolve_flutter_root")
        else:
            root_assignment = None
            root_lookup = None
            for node in ast.walk(resolve):
                if not isinstance(node, (ast.Assign, ast.AnnAssign)) or node.value is None:
                    continue
                for child in ast.walk(node.value):
                    if not isinstance(child, ast.Call):
                        continue
                    if _call_path(child) != ["ctx", "os", "environ", "get"]:
                        continue
                    if child.args and _string(child.args[0]) == "FLUTTER_ROOT":
                        root_assignment = node
                        root_lookup = child
                        break
                if root_lookup is not None:
                    break
            if root_assignment is None:
                self.fail("A", "_resolve_flutter_root must read FLUTTER_ROOT from ctx.os.environ")
            which_calls = [
                node
                for node in ast.walk(resolve)
                if isinstance(node, ast.Call)
                and _call_path(node) == ["ctx", "which"]
                and node.args
                and _string(node.args[0]) == "flutter"
            ]
            if not which_calls:
                self.fail("A", "_resolve_flutter_root must fall back to ctx.which(\"flutter\")")
            if root_lookup is not None and which_calls:
                if root_lookup.lineno >= min(node.lineno for node in which_calls):
                    self.fail("A", "_resolve_flutter_root must check FLUTTER_ROOT before PATH lookup")


        for node in ast.walk(tree):
            if not isinstance(node, ast.Call) or _call_path(node) is None:
                continue
            path = _call_path(node)
            if len(path) >= 3 and path[-2:] == ["environ", "get"]:
                args = node.args
                if not args or _string(args[0]) != "FLUTTER_ROOT":
                    self.fail("A", "repo.bzl may capture only FLUTTER_ROOT from ctx.os.environ")
        for token in ("FLUTTER_ENV", "sdk.bzl", "ANDROID_HOME", "ANDROID_SDK_ROOT", "HOME", "PUB_CACHE"):
            if _contains_string(tree, token):
                self.fail("A", "repo.bzl must not capture generated SDK or {} environment state".format(token))

        sdk_rule = _named_call(tree, "flutter_sdk")
        if sdk_rule is None or _call_path(sdk_rule) != ["repository_rule"]:
            self.fail("A", "repo.bzl must define flutter_sdk with repository_rule")
        else:
            environ = _keyword(sdk_rule, "environ")
            values = _string_list(environ)
            if values != ["FLUTTER_ROOT", "PATH"]:
                self.fail("A", "flutter_sdk repository environ must be exactly [\"FLUTTER_ROOT\", \"PATH\"]")
            for keyword in sdk_rule.keywords:
                if keyword.arg == "environ":
                    continue
                if any(
                    isinstance(node, ast.Constant)
                    and isinstance(node.value, str)
                    and any(token in node.value for token in ("FLUTTER_ENV", "sdk.bzl", "ANDROID_HOME", "ANDROID_SDK_ROOT", "HOME", "PUB_CACHE"))
                    for node in ast.walk(keyword.value)
                ):
                    self.fail("A", "flutter_sdk repository must not capture generated SDK or unrelated environment state")
                    break

        # A repository rule's environment declaration is the only source-level
        # capture contract here; reject a second environment declaration too.
        environ_calls = [
            node
            for node in ast.walk(tree)
            if isinstance(node, ast.Call) and _keyword(node, "environ") is not None
        ]
        if len(environ_calls) != 1:
            self.fail("A", "repo.bzl must have one environment declaration, on flutter_sdk")

    def check_b(self):
        for name in ("defs", "android"):
            tree = self.tree(name, "B")
            if tree is None:
                continue
            for node in ast.walk(tree):
                if not isinstance(node, ast.Call):
                    continue
                if _call_path(node) not in (["ctx", "actions", "run"], ["ctx", "actions", "run_shell"]):
                    continue
                forbidden = [
                    keyword.arg
                    for keyword in node.keywords
                    if keyword.arg in ("env", "environment", "use_default_shell_env")
                ]
                if forbidden:
                    self.fail(
                        "B",
                        "{} action call must not use {}".format(
                            _call_path(node)[-1], ", ".join(sorted(forbidden))
                        ),
                    )

    def check_c(self):
        tree = self.tree("defs", "C")
        if tree is None:
            return
        function = _function(tree, "_dart_kernel_impl")
        if function is None:
            self.fail("C", "defs.bzl must define _dart_kernel_impl")
            return

        package_add = False
        for node in ast.walk(function):
            if not isinstance(node, ast.Call) or _call_path(node) != ["args", "add"]:
                continue
            if node.args and _string(node.args[0]) == "--packages":
                if len(node.args) >= 2 and _attr_path(node.args[1]) in (
                    ["ctx", "file", "package_config"],
                    ["ctx", "files", "package_config"],
                ):
                    package_add = True
        if not package_add:
            self.fail("C", "_dart_kernel_impl must pass ctx.file.package_config to --packages")

        action = _action_call(function, "run_shell")
        if action is None:
            self.fail("C", "_dart_kernel_impl must create its Dart action with ctx.actions.run_shell")
        else:
            inputs = _keyword(action, "inputs")
            if (
                _contains_attr(inputs, ["ctx", "file", "package_config"])
                or _contains_attr(inputs, ["ctx", "files", "package_config"])
                or _contains_name(inputs, "package_config")
            ):
                self.fail("C", "package_config must not occur in the Dart action inputs")
            tools = _keyword(action, "tools")
            if not _contains_attr(tools, ["ctx", "attr", "_dartaotruntime"]):
                self.fail("C", "Dart action must declare _dartaotruntime as a tool")
            if not _contains_attr(inputs, ["ctx", "file", "_frontend_server"]):
                self.fail("C", "Dart action inputs must declare _frontend_server")
            if not _contains_attr(inputs, ["ctx", "file", "_sdk_version"]):
                self.fail("C", "Dart action inputs must declare _sdk_version")
            if not _contains_attr(inputs, ["platform", "files"]):
                self.fail("C", "Dart action inputs must retain the selected platform files")

        release = _named_value(tree, "_EXEC_RELEASE")
        release_values = _string_dict(release)
        if release_values != {"no-sandbox": "1", "no-remote-exec": "1"}:
            self.fail("C", "_EXEC_RELEASE must require only no-sandbox and no-remote-exec")

        debug = _named_value(tree, "_EXEC_DEBUG")
        if not (
            isinstance(debug, ast.Call)
            and _call_path(debug) == ["dict"]
            and debug.args
            and _name(debug.args[0]) == "_EXEC_RELEASE"
            and _string_dict(_double_star_dict(debug)) == {"local": "1"}
        ):
            self.fail("C", "_EXEC_DEBUG must add local to the release execution requirements")
        requirements = _function(tree, "_exec_requirements")
        if requirements is None or not _function_returns_name(requirements, "_EXEC_DEBUG") or not _function_returns_name(requirements, "_EXEC_RELEASE"):
            self.fail("C", "_exec_requirements must select debug or release cache policy")
        elif action is not None:
            execution = _keyword(action, "execution_requirements")
            if not (isinstance(execution, ast.Call) and _call_path(execution) == ["_exec_requirements"]):
                self.fail("C", "Dart action must use _exec_requirements(mode)")

        for target, expected in (
            ("_dartaotruntime", "@flutter_sdk//:dartaotruntime"),
            ("_frontend_server", "@flutter_sdk//:frontend_server.snapshot"),
            ("_sdk_version", "@flutter_sdk//:flutter.version.json"),
            ("_platform_product", "@flutter_sdk//:platform_product"),
            ("_platform_debug", "@flutter_sdk//:platform_debug"),
        ):
            if not _rule_attr_default(tree, "dart_kernel", target, expected):
                self.fail("C", "dart_kernel must retain {} default {}".format(target, expected))

    def check_d(self):
        tree = self.tree("defs", "D")
        if tree is None:
            return
        function = _function(tree, "_flutter_assets_impl")
        if function is None:
            self.fail("D", "defs.bzl must define _flutter_assets_impl")
            return

        stage = _named_value(function, "stage_manifest_files")
        if not _contains_attr(stage, ["ctx", "file", "package_config"]):
            self.fail("D", "stage_manifest_files must include package_config")

        declared = _named_value(function, "declared_project_files")
        if not _excludes_package_config(declared):
            self.fail("D", "declared_project_files must structurally exclude package_config")

        action = _action_call(function, "run_shell")
        if action is None:
            self.fail("D", "_flutter_assets_impl must create its action with ctx.actions.run_shell")
        else:
            inputs = _keyword(action, "inputs")
            if not _contains_name(inputs, "manifest"):
                self.fail("D", "FlutterAssets inputs must declare the generated stage manifest")
            for name in ("_sdk_version", "_merger", "_flutter", "_android_sdk"):
                expected = ["ctx", "file", name]
                if not _contains_attr(inputs, expected):
                    self.fail("D", "FlutterAssets inputs must declare ctx.file.{}".format(name))
            execution = _keyword(action, "execution_requirements")
            if not (isinstance(execution, ast.Call) and _call_path(execution) == ["_exec_requirements"]):
                self.fail("D", "FlutterAssets action must use release/debug execution requirements")

        command = _assets_command(function)
        if command is None:
            self.fail("D", "_flutter_assets_impl must define its shell command")
        else:
            required = (
                ('export PATH="/usr/bin:/bin"', "fixed PATH"),
                ("$EXECROOT/{android_sdk}", "EXECROOT Android SDK marker"),
                ('export ANDROID_HOME=', "ANDROID_HOME export"),
                ('export ANDROID_SDK_ROOT="$ANDROID_HOME"', "ANDROID_SDK_ROOT export"),
                ('export FLUTTER_ALREADY_LOCKED="true"', "FLUTTER_ALREADY_LOCKED export"),
                ('export HOME="$STAGE/home"', "stage-local HOME"),
            )
            for token, description in required:
                if token not in command:
                    self.fail("D", "FlutterAssets command must contain {}".format(description))
            if "realpath" not in command or "dirname" not in command:
                self.fail("D", "FlutterAssets command must derive Android SDK root from the marker")

        for target, expected in (
            ("_flutter", "@flutter_sdk//:flutter"),
            ("_android_sdk", "//tools/flutter:_android_sdk_marker"),
            ("_merger", "//tools/flutter:merge_native_assets.py"),
            ("_sdk_version", "@flutter_sdk//:flutter.version.json"),
        ):
            if not _rule_attr_default(tree, "flutter_assets", target, expected):
                self.fail("D", "flutter_assets must retain {} default {}".format(target, expected))

    def check_e(self):
        tree = self.tree("android", "E")
        if tree is None:
            return
        transition = _function(tree, "_android_platform_transition_impl")
        if transition is None or not _returns_platform_attr(transition):
            self.fail("E", "platform transition must return the selected attr.platform")

        for rule_name in ("_android_native_lib_jar", "_strip_native_libs"):
            call = _named_call(tree, rule_name)
            if call is None or not _keyword_is_name(call, "cfg", "_android_platform_transition"):
                self.fail("E", "{} must retain cfg = _android_platform_transition".format(rule_name))
            if call is None or not _keyword_is_call(call, "toolchains", "use_cc_toolchain"):
                self.fail("E", "{} must retain use_cc_toolchain()".format(rule_name))

        for function_name in ("_android_native_lib_jar_impl", "_strip_native_libs_impl"):
            function = _function(tree, function_name)
            if function is None or not _has_call(function, "find_cpp_toolchain", ["ctx"]):
                self.fail("E", "{} must resolve C++ tools through find_cpp_toolchain(ctx)".format(function_name))

        if _contains_string(tree, "ANDROID_NDK_HOME"):
            self.fail("E", "Android action source must not use an NDK environment path")

    def check_f(self):
        tree = self.tree("plugins", "F")
        if tree is None:
            return
        template = _string(_named_value(tree, "_NATIVE_ABI_TEMPLATE"))
        if template is None:
            self.fail("F", "plugins.bzl must define _NATIVE_ABI_TEMPLATE as a string template")
        else:
            required = (
                ('build_data = ["{ndk_source_properties}"]', "NDK source.properties build_data"),
                ("CMAKE_TOOLCHAIN_FILE", "CMake toolchain cache entry"),
                ("$$EXT_BUILD_ROOT$$", "external build root"),
                ("$(execpath {ndk_source_properties})", "execpath source.properties marker"),
                ("dirname", "toolchain dirname"),
                ("realpath", "toolchain realpath"),
                ('"ANDROID_ABI"', "ABI cache entry"),
                ('"ANDROID_PLATFORM"', "API cache entry"),
                ("max-page-size=16384", "16 KB linker flag"),
            )
            for token, description in required:
                if token not in template:
                    self.fail("F", "native ABI template must retain {}".format(description))
            if re.search(r"/(?:Users|home|opt|private)/", template):
                self.fail("F", "native ABI cache entries must not contain a host absolute path")

        if _contains_name(tree, "_ndk_root") or any(
            isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == "_ndk_root"
            for node in ast.walk(tree)
        ):
            self.fail("F", "plugins.bzl must not define or use _ndk_root")
        if _contains_string(tree, "ANDROID_NDK_HOME"):
            self.fail("F", "plugins.bzl must not capture or expand ANDROID_NDK_HOME")
        if any(isinstance(node, ast.keyword) and node.arg == "environ" for node in ast.walk(tree)):
            self.fail("F", "plugins.bzl must not declare repository environment capture")

        rule = _named_call(tree, "flutter_plugins")
        if rule is None or not _rule_attr_mandatory_string(tree, "flutter_plugins", "ndk_source_properties"):
            self.fail("F", "flutter_plugins must require the ndk_source_properties repository label")
        ext = _function(tree, "_flutter_plugins_ext_impl")
        if ext is None or not _canonical_ndk_label(ext):
            self.fail("F", "module extension must pass the canonical @androidndk_cmake ndk_source_properties label")
        if rule is None:
            self.fail("F", "plugins.bzl must define flutter_plugins with repository_rule")

    def check_g(self):
        tree = self.tree("ndk", "G")
        if tree is None:
            return
        minimum = _named_value(tree, "_MIN_NDK_MAJOR")
        if not (isinstance(minimum, ast.Constant) and minimum.value == 28):
            self.fail("G", "_MIN_NDK_MAJOR must be 28")

        stub = _string(_named_value(tree, "_CMAKE_STUB_BUILD"))
        if stub is None or not all(
            token in stub
            for token in (
                "ndk_source_properties_missing",
                "ndk_source_properties",
                "ANDROID_NDK_HOME",
                "28.0.0",
                "exit 1",
            )
        ):
            self.fail("G", "no-NDK CMake stub must expose a failing diagnostic through ndk_source_properties")

        implementation = _function(tree, "_androidndk_cmake_repository_impl")
        if implementation is None:
            self.fail("G", "ndk.bzl must define _androidndk_cmake_repository_impl")
        else:
            if not _has_call_with_string(implementation, ["ctx", "path"], "source.properties"):
                self.fail("G", "real NDK repository must validate source.properties")
            if not _contains_string(implementation, "Pkg.Revision"):
                self.fail("G", "real NDK repository must read Pkg.Revision")
            if not _has_call_with_string(implementation, ["ctx", "symlink"], "source.properties"):
                self.fail("G", "real NDK repository must symlink source.properties")
            if not _has_call_with_string(implementation, ["ctx", "path"], "build/cmake/android.toolchain.cmake"):
                self.fail("G", "real NDK repository must validate the CMake toolchain")
            if not _has_name_attr(implementation, "properties", "exists"):
                self.fail("G", "real NDK repository must check source.properties existence")
            if not _has_name_attr(implementation, "toolchain_file", "exists"):
                self.fail("G", "real NDK repository must check CMake toolchain existence")
            if not _has_call_with_string(implementation, ["ctx", "os", "environ", "get"], "ANDROID_NDK_HOME"):
                self.fail("G", "only the NDK repository may read ANDROID_NDK_HOME from ctx.os.environ")

        ext_impl = _function(tree, "_android_ndk_impl")
        if ext_impl is None:
            self.fail("G", "ndk.bzl must define _android_ndk_impl")
        else:
            if _has_call_with_string(ext_impl, ["module_ctx", "getenv"], "ANDROID_NDK_HOME"):
                self.fail("G", "NDK module extension must not read ANDROID_NDK_HOME with module_ctx.getenv")
            cmake_calls = [
                node
                for node in ast.walk(ext_impl)
                if isinstance(node, ast.Call) and _call_path(node) == ["_androidndk_cmake_repository"]
            ]
            if len(cmake_calls) != 1 or not _keyword_string(cmake_calls[0], "name") == "androidndk_cmake":
                self.fail("G", "NDK module extension must always create androidndk_cmake")
            elif not any(
                isinstance(statement, ast.Expr) and statement.value is cmake_calls[0]
                for statement in ext_impl.body
            ):
                self.fail("G", "androidndk_cmake must be created unconditionally")
            cc_calls = [
                _call_path(node)[0]
                for node in ast.walk(ext_impl)
                if isinstance(node, ast.Call)
                and _call_path(node)
                and _call_path(node)[0] in ("android_ndk_repository",)
            ]
            if sorted(cc_calls) != ["android_ndk_repository"]:
                self.fail("G", "NDK module extension must always invoke upstream android_ndk_repository")

        for name, expected in (
            ("_androidndk_cmake_repository", ["ANDROID_NDK_HOME"]),
        ):
            call = _named_call(tree, name)
            values = _string_list(_keyword(call, "environ")) if call is not None else None
            if values != expected:
                self.fail("G", "{} environment declaration must be exactly ANDROID_NDK_HOME".format(name))

        if _named_call(tree, "android_ndk") is not None:
            ndk_ext = _named_call(tree, "android_ndk")
            environ = _keyword(ndk_ext, "environ")
            if environ is not None:
                self.fail("G", "android_ndk extension must not declare environ")

        env_reads = [
            node
            for node in ast.walk(tree)
            if isinstance(node, ast.Call)
            and _call_path(node) in (
                ["ctx", "os", "environ", "get"],
            )
        ]
        if len(env_reads) != 1:
            self.fail("G", "only the NDK repository implementation may read the NDK environment")

    def check_h(self):
        regions = []
        for name in ("defs", "android", "plugins"):
            tree = self.trees.get(name)
            if tree is None:
                continue
            regions.extend(_action_regions(name, tree))
        forbidden = (
            (re.compile(r"/(?:Users|home|opt|private)/"), "host absolute path"),
            (re.compile(r"\bFLUTTER_ROOT\b"), "literal FLUTTER_ROOT"),
            (re.compile(r"\bPUB_CACHE\b"), "literal PUB_CACHE"),
            (re.compile(r"\$(?:\{ANDROID_NDK_HOME\}|ANDROID_NDK_HOME|\(ANDROID_NDK_HOME\))"), "direct ANDROID_NDK_HOME expansion"),
        )
        for name, region in regions:
            for pattern, description in forbidden:
                if pattern.search(region):
                    self.fail("H", "{} action/cache region contains {}".format(name, description))


def _file_contract(name):
    return {"repo": "A", "defs": "B", "android": "E", "plugins": "F", "ndk": "G"}[name]


def _string(node):
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    return None


def _name(node):
    return node.id if isinstance(node, ast.Name) else None


def _attr_path(node):
    if isinstance(node, ast.Name):
        return [node.id]
    if isinstance(node, ast.Attribute):
        prefix = _attr_path(node.value)
        return prefix + [node.attr] if prefix else None
    return None


def _call_path(node):
    return _attr_path(node.func) if isinstance(node, ast.Call) else None


def _function(tree, name):
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == name:
            return node
    return None


def _assignments(node):
    result = {}
    for child in ast.walk(node):
        if isinstance(child, ast.Assign):
            for target in child.targets:
                if isinstance(target, ast.Name):
                    result[target.id] = child.value
        elif isinstance(child, ast.AnnAssign) and isinstance(child.target, ast.Name):
            result[child.target.id] = child.value
    return result


def _named_value(node, name):
    return _assignments(node).get(name)


def _named_call(tree, name):
    value = _named_value(tree, name)
    return value if isinstance(value, ast.Call) else None


def _keyword(call, name):
    if not isinstance(call, ast.Call):
        return None
    for keyword in call.keywords:
        if keyword.arg == name:
            return keyword.value
    return None


def _keyword_string(call, name):
    return _string(_keyword(call, name))


def _string_list(node):
    if not isinstance(node, (ast.List, ast.Tuple)):
        return None
    values = []
    for element in node.elts:
        value = _string(element)
        if value is None:
            return None
        values.append(value)
    return values


def _string_dict(node):
    if not isinstance(node, ast.Dict):
        return None
    result = {}
    for key, value in zip(node.keys, node.values):
        key_value = _string(key)
        value_value = _string(value)
        if key_value is None or value_value is None:
            return None
        result[key_value] = value_value
    return result


def _double_star_dict(call):
    for keyword in call.keywords:
        if keyword.arg is None and isinstance(keyword.value, ast.Dict):
            return keyword.value
    return None


def _contains_attr(node, path):
    if node is None:
        return False
    return any(_attr_path(child) == path for child in ast.walk(node))


def _contains_name(node, name):
    return node is not None and any(isinstance(child, ast.Name) and child.id == name for child in ast.walk(node))


def _contains_string(node, value):
    return any(isinstance(child, ast.Constant) and child.value == value for child in ast.walk(node))


def _action_call(function, action_name):
    for node in ast.walk(function):
        if isinstance(node, ast.Call) and _call_path(node) == ["ctx", "actions", action_name]:
            return node
    return None


def _function_returns_name(function, name):
    for node in ast.walk(function):
        if not isinstance(node, ast.Return):
            continue
        value = node.value
        if _name(value) == name:
            return True
        if isinstance(value, ast.IfExp) and (_name(value.body) == name or _name(value.orelse) == name):
            return True
    return False

def _rule_decl(tree, rule_name):
    value = _named_value(tree, rule_name)
    return value if isinstance(value, ast.Call) and _call_path(value) == ["rule"] else None




def _rule_attr_default(tree, rule_name, attr_name, expected):
    rule = _rule_decl(tree, rule_name)
    if rule is None:
        return False
    attrs = _keyword(rule, "attrs")
    if not isinstance(attrs, ast.Dict):
        return False
    for key, value in zip(attrs.keys, attrs.values):
        if _string(key) != attr_name or not isinstance(value, ast.Call):
            continue
        default = _keyword(value, "default")
        return _string(default) == expected
    return False


def _rule_attr_mandatory_string(tree, rule_name, attr_name):
    rule = _named_call(tree, rule_name)
    if rule is None or _call_path(rule) != ["repository_rule"]:
        return False
    attrs = _keyword(rule, "attrs")
    if not isinstance(attrs, ast.Dict):
        return False
    for key, value in zip(attrs.keys, attrs.values):
        if _string(key) == attr_name and isinstance(value, ast.Call):
            mandatory = _keyword(value, "mandatory")
            return isinstance(mandatory, ast.Constant) and mandatory.value is True
    return False


def _keyword_is_name(call, keyword, name):
    return _name(_keyword(call, keyword)) == name
def _keyword_is_call(call, keyword, name):
    return _call_path(_keyword(call, keyword)) == [name]


def _canonical_ndk_label(function):
    expected = "@androidndk_cmake//:ndk_source_properties"
    for node in ast.walk(function):
        if not isinstance(node, ast.Call) or _call_path(node) != ["str"]:
            continue
        if len(node.args) != 1 or not isinstance(node.args[0], ast.Call):
            continue
        label = node.args[0]
        if _call_path(label) == ["Label"] and len(label.args) == 1 and _string(label.args[0]) == expected:
            return True
    return False



def _has_call(node, function_name, args=None):
    for child in ast.walk(node):
        if not isinstance(child, ast.Call) or _call_path(child) != [function_name]:
            continue
        if args is None or [_name(arg) for arg in child.args] == args:
            return True
    return False


def _has_call_with_string(node, path, text):
    for child in ast.walk(node):
        if not isinstance(child, ast.Call) or _call_path(child) != path:
            continue
        for argument in child.args:
            if _string(argument) == text:
                return True
            formatted = _formatted_template(argument)
            if formatted is not None and text in formatted:
                return True
    return False


def _has_name_attr(node, name, attr):
    return any(
        isinstance(child, ast.Attribute)
        and child.attr == attr
        and _name(child.value) == name
        for child in ast.walk(node)
    )


def _returns_platform_attr(function):
    for node in ast.walk(function):
        if not isinstance(node, ast.Return) or not isinstance(node.value, ast.Dict):
            continue
        for key, value in zip(node.value.keys, node.value.values):
            if _string(key) == "//command_line_option:platforms":
                if isinstance(value, ast.List) and len(value.elts) == 1 and _attr_path(value.elts[0]) == ["attr", "platform"]:
                    return True
    return False


def _excludes_package_config(node):
    if not isinstance(node, ast.ListComp):
        return False
    for generator in node.generators:
        if _name(generator.target) != "f" or _name(generator.iter) != "stage_manifest_files":
            continue
        for condition in generator.ifs:
            if not isinstance(condition, ast.Compare) or len(condition.ops) != 1 or not isinstance(condition.ops[0], ast.NotEq):
                continue
            if _name(condition.left) == "f" and any(
                _attr_path(comparator) in (
                    ["ctx", "file", "package_config"],
                    ["ctx", "files", "package_config"],
                )
                for comparator in condition.comparators
            ):
                return True
    return False


def _formatted_template(node):
    if isinstance(node, ast.Constant):
        return _string(node)
    if (
        isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and node.func.attr == "format"
    ):
        return _string(node.func.value)
    return None


def _assets_command(function):
    value = _assignments(function).get("cmd")
    return _formatted_template(value)


def _action_regions(name, tree):
    regions = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and _call_path(node) in (
            ["ctx", "actions", "run"],
            ["ctx", "actions", "run_shell"],
        ):
            command = _keyword(node, "command")
            text = _formatted_template(command)
            if text is None and isinstance(command, ast.Name):
                text = _formatted_template(_named_value(tree, command.id))
            if text is not None:
                regions.append((name, text))
    if name == "defs":
        function = _function(tree, "_flutter_assets_impl")
        if function is not None:
            command = _assets_command(function)
            if command is not None:
                regions.append((name, command))
        bundle = _function(tree, "_bundle_command")
        if bundle is not None:
            for node in ast.walk(bundle):
                if isinstance(node, ast.Call):
                    text = _formatted_template(node)
                    if text is not None:
                        regions.append((name, text))
    if name == "plugins":
        template = _string(_named_value(tree, "_NATIVE_ABI_TEMPLATE"))
        if template is not None:
            regions.append((name, template))
    return regions


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("."), help="workspace root containing tools/flutter")
    args = parser.parse_args(argv)
    failures = Checker(args.root).run()
    if failures:
        print("\n".join(failures))
        return 1
    print("OK: key portability contracts A-H hold")
    return 0


if __name__ == "__main__":
    sys.exit(main())
