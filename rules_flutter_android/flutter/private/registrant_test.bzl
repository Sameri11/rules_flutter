"""Focused tests for generated Android registrant dependency ordering."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":registrant.bzl", "android_plugin", "resolve_android_plugins")

visibility(["//flutter/private"])

def _plugin(name, dependencies = []):
    return android_plugin(name, "", {"package": "test", "pluginClass": "TestPlugin"}, False, False, dependencies)

def _ordered_names(plugins):
    return [plugin["name"] for plugin in resolve_android_plugins(plugins, release = False)]

def _orders_ready_nodes_alphabetically_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, ["alpha", "beta", "zeta"], _ordered_names([
        _plugin("zeta"),
        _plugin("beta"),
        _plugin("alpha"),
    ]))
    return unittest.end(env)

_orders_ready_nodes_alphabetically_test = unittest.make(_orders_ready_nodes_alphabetically_impl)

def _breaks_cycles_by_smallest_in_degree_then_name_impl(ctx):
    env = unittest.begin(ctx)
    # `a` has more dependents than `c`, but the same incoming degree. Flutter
    # chooses `a` by name, not by total graph degree.
    asserts.equals(env, ["a", "d", "e", "f", "g", "b", "c"], _ordered_names([
        _plugin("a", ["b"]),
        _plugin("b", ["a", "c"]),
        _plugin("c", ["b"]),
        _plugin("d", ["a"]),
        _plugin("e", ["a"]),
        _plugin("f", ["a"]),
        _plugin("g", ["a"]),
    ]))
    return unittest.end(env)

_breaks_cycles_by_smallest_in_degree_then_name_test = unittest.make(_breaks_cycles_by_smallest_in_degree_then_name_impl)

def _prioritizes_in_degree_before_name_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, ["b", "a", "c"], _ordered_names([
        _plugin("a", ["b", "c"]),
        _plugin("b", ["a"]),
        _plugin("c", ["a"]),
    ]))
    return unittest.end(env)

_prioritizes_in_degree_before_name_test = unittest.make(_prioritizes_in_degree_before_name_impl)

def _ignores_duplicate_and_self_edges_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, ["b", "a", "c"], _ordered_names([
        _plugin("a", ["a", "b", "b"]),
        _plugin("b"),
        _plugin("c"),
    ]))
    return unittest.end(env)

_ignores_duplicate_and_self_edges_test = unittest.make(_ignores_duplicate_and_self_edges_impl)

def registrant_test_suite(name):
    """Registers the Android plugin ordering tests."""
    unittest.suite(
        name,
        _orders_ready_nodes_alphabetically_test,
        _breaks_cycles_by_smallest_in_degree_then_name_test,
        _prioritizes_in_degree_before_name_test,
        _ignores_duplicate_and_self_edges_test,
    )
