"""The install step must run even when lint_command is overridden.

Dependency installation used to live inside python.yml's lint_command default,
so a caller overriding that input silently lost its dependencies and only found
out when tests failed on imports. This import is that failure, made explicit.
"""


def test_declared_dependency_is_importable():
    import six  # noqa: F401  -- installed only by install_command
