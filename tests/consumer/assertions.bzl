"""Assertions for values a rule computes at loading time.

A BUILD file cannot use `if`, and a bare `x == y or fail(...)` is an expression
statement buildifier rejects, so equality checks go through here.
"""

def expect_equal(actual, expected, what):
    """Fails the load if `actual` differs from `expected`."""
    if actual != expected:
        fail("{}: got {}, expected {}".format(what, actual, expected))
