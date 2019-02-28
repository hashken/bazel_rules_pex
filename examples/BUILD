load("//pex:pex_rules.bzl", "pex_binary", "pex_library", "pex_pytest")

pex_binary(
    name = "foo",
    srcs = [
        "__init__.py",
        "foo.py"
    ],
    reqs = [
        "flask",
        "pyyaml",
    ],
    entrypoint = "examples.foo:main"
)

pex_library(
    name = "libfoo",
    srcs = [
        "__init__.py",
        "foo.py"
    ],
    reqs = [
        "flask",
        "pyyaml",
    ],
)

pex_pytest(
    name = "foo_test",
    size = "small",
    srcs = [
        "__init__.py",
        "foo_test.py"
    ],
    args = ["--strict"],
    deps = [":libfoo"],
)
