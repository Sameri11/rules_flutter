"""Load-time assertions for the helper's own BUILD files.

A BUILD file cannot use `if`, so an equality check goes through a function.
"""

def expect_equal(actual, expected, what):
    """Fails the load if `actual` differs from `expected`."""
    if actual != expected:
        fail("{}: got {}, expected {}".format(what, actual, expected))
