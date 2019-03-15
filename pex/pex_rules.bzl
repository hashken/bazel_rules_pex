# Copyright 2014 Google Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Originally derived from:
# https://github.com/twitter/heron/blob/master/tools/rules/pex_rules.bzl

"""Python pex rules for Bazel

[![Build Status](https://travis-ci.org/benley/bazel_rules_pex.svg?branch=master)](https://travis-ci.org/benley/bazel_rules_pex)

### Setup

Add something like this to your WORKSPACE file:

    git_repository(
        name = "io_bazel_rules_pex",
        remote = "https://github.com/benley/bazel_rules_pex.git",
        tag = "0.3.0",
    )
    load("@io_bazel_rules_pex//pex:pex_rules.bzl", "pex_repositories")
    pex_repositories()

In a BUILD file where you want to use these rules, or in your
`tools/build_rules/prelude_bazel` file if you want them present repo-wide, add:

    load(
        "@io_bazel_rules_pex//pex:pex_rules.bzl",
        "pex_binary",
        "pex_library",
        "pex_test",
        "pex_pytest",
    )

Lastly, make sure that `tools/build_rules/BUILD` exists, even if it is empty,
so that Bazel can find your `prelude_bazel` file.
"""

pex_file_types = FileType([".py"])
egg_file_types = FileType([".egg", ".whl"])
req_file_types = FileType([".txt"])

# Repos file types according to: https://www.python.org/dev/peps/pep-0527/
repo_file_types = FileType([
    ".egg",
    ".whl",
    ".tar.gz",
    ".zip",
    ".tar",
    ".tar.bz2",
    ".tar.xz",
    ".tar.Z",
    ".tgz",
    ".tbz",
])

# As much as I think this test file naming convention is a good thing, it's
# probably a bad idea to impose it as a policy to all OSS users of these rules,
# so I guess let's skip it.
#
# pex_test_file_types = FileType(["_unittest.py", "_test.py"])

def _collect_transitive_sources(ctx):
    source_files = depset(order = "postorder")
    for dep in ctx.attr.deps:
        if hasattr(dep, "py"):
            source_files += dep.py.transitive_sources
    source_files += pex_file_types.filter(ctx.files.srcs)
    return source_files

def _collect_transitive_eggs(ctx):
    transitive_eggs = depset(order = "postorder")
    for dep in ctx.attr.deps:
        if hasattr(dep, "py") and hasattr(dep.py, "transitive_eggs"):
            transitive_eggs += dep.py.transitive_eggs
    transitive_eggs += egg_file_types.filter(ctx.files.eggs)
    return transitive_eggs

def _collect_transitive_reqs(ctx):
    transitive_reqs = depset(order = "postorder")
    for dep in ctx.attr.deps:
        if hasattr(dep, "py") and hasattr(dep.py, "transitive_reqs"):
            transitive_reqs += dep.py.transitive_reqs
    transitive_reqs += ctx.attr.reqs
    return transitive_reqs

def _collect_repos(ctx):
    repos = {}
    for dep in ctx.attr.deps:
        if hasattr(dep, "py") and hasattr(dep.py, "repos"):
            repos += dep.py.repos
    for file in repo_file_types.filter(ctx.files.repos):
        repos.update({file.dirname: True})
    return repos.keys()

def _collect_transitive(ctx):
    return struct(
        # These rules don't use transitive_sources internally; it's just here for
        # parity with the native py_library rule type.
        transitive_sources = _collect_transitive_sources(ctx),
        transitive_eggs = _collect_transitive_eggs(ctx),
        transitive_reqs = _collect_transitive_reqs(ctx),
        # uses_shared_libraries = ... # native py_library has this. What is it?
    )

def _pex_library_impl(ctx):
    transitive_files = depset(ctx.files.srcs)
    for dep in ctx.attr.deps:
        transitive_files += dep.default_runfiles.files
    return struct(
        files = depset(),
        py = _collect_transitive(ctx),
        runfiles = ctx.runfiles(
            collect_default = True,
            transitive_files = depset(transitive_files),
        ),
    )

def _pex_binary_impl(ctx):
    transitive_files = depset(ctx.files.srcs)

    if ctx.attr.entrypoint and ctx.file.main:
        fail("Please specify either entrypoint or main, not both.")

    main_file = None
    main_pkg = None
    script = None
    if ctx.attr.entrypoint:
        main_pkg = ctx.attr.entrypoint
    elif ctx.file.main:
        main_file = ctx.file.main
    elif ctx.attr.script:
        script = ctx.attr.script
    elif ctx.files.srcs:
        main_file = pex_file_types.filter(ctx.files.srcs)[0]

    if main_file:
        # Translate main_file's short path into a python module name
        main_pkg = main_file.short_path.replace("/", ".")[:-3]
        transitive_files += [main_file]

    py = _collect_transitive(ctx)
    repos = _collect_repos(ctx)

    for dep in ctx.attr.deps:
        transitive_files += dep.default_runfiles.files

    runfiles = ctx.runfiles(
        collect_default = True,
        transitive_files = transitive_files,
    )

    resources_dir = ctx.actions.declare_directory("resources")
    ctx.actions.run_shell(
        mnemonic = "CreateResourceDirectory",
        outputs = [resources_dir],
        inputs = runfiles.files.to_list(),
        command = "mkdir -p {resources_dir} && rsync -R {transitive_files} {resources_dir}".format(
            resources_dir = resources_dir.path,
            transitive_files = " ".join([file.path for file in runfiles.files]),
        ),
    )

    pexbuilder = ctx.executable._pexbuilder
    arguments = ["setuptools>=40.8.0"]

    # form the arguments to pex builder
    if not ctx.attr.zip_safe:
        arguments += ["--not-zip-safe"]
    if not ctx.attr.use_wheels:
        arguments += ["--no-use-wheel"]
    if ctx.attr.no_index:
        arguments += ["--no-index"]
    if ctx.attr.disable_cache:
        arguments += ["--disable-cache"]
    for interpreter in ctx.attr.interpreters:
        arguments += ["--python", interpreter]
    for platform in ctx.attr.platforms:
        arguments += ["--platform", platform]
    for req_file in ctx.files.req_files:
        arguments += ["--requirement", req_file.path]
    for repo in repos:
        arguments += ["--repo", repo]
    for egg in py.transitive_eggs:
        arguments += [egg.path]
    for req in py.transitive_reqs:
        arguments += [req]
    if main_pkg:
        arguments += ["--entry-point", main_pkg]
    elif script:
        arguments += ["--script", script]
    arguments += [
        "--resources-directory",
        "{resources_dir}/{strip_prefix}".format(
            resources_dir = resources_dir.path,
            strip_prefix = ctx.attr.strip_prefix.strip("/"),
        ),
        "--resources-directory",
        "{resources_dir}/{genfiles_dir}/{strip_prefix}".format(
            resources_dir = resources_dir.path,
            genfiles_dir = ctx.configuration.genfiles_dir.path,
            strip_prefix = ctx.attr.strip_prefix.strip("/"),
        ),
        "--pex-root",
        "$(mktemp -d)" if ctx.attr.disable_cache else ".pex",  # So pex doesn't try to unpack into $HOME/.pex
        "--output-file",
        ctx.outputs.executable.path,
    ]

    # form the inputs to pex builder
    _inputs = (
        list(runfiles.files) +
        list(py.transitive_eggs)
    ) + [resources_dir]

    ctx.actions.run(
        mnemonic = "PexPython",
        inputs = _inputs,
        outputs = [ctx.outputs.executable],
        executable = pexbuilder,
        execution_requirements = {
            "requires-network": "1",
        },
        env = {
            # TODO(benley): Write a repository rule to pick up certain
            # PEX-related environment variables (like PEX_VERBOSE) from the
            # system.
            # Also, what if python is actually in /opt or something?
            "PATH": "/bin:/usr/bin:/usr/local/bin",
            "PEX_VERBOSE": str(ctx.attr.verbosity),
        },
        arguments = arguments,
    )

    return struct(
        files = depset([ctx.outputs.executable]),  # Which files show up in cmdline output
        runfiles = runfiles,
    )

def _get_runfile_path(ctx, f):
    """Return the path to f, relative to runfiles."""
    if ctx.workspace_name:
        return ctx.workspace_name + "/" + f.short_path
    else:
        return f.short_path

def _pex_pytest_impl(ctx):
    test_runner = ctx.executable.runner
    output_file = ctx.outputs.executable

    test_file_paths = ["${RUNFILES}/" + _get_runfile_path(ctx, f) for f in ctx.files.srcs]
    ctx.template_action(
        template = ctx.file.launcher_template,
        output = output_file,
        substitutions = {
            "%test_runner%": _get_runfile_path(ctx, test_runner),
            "%test_files%": " \\\n    ".join(test_file_paths),
        },
        executable = True,
    )

    transitive_files = depset(ctx.files.srcs + [test_runner])
    for dep in ctx.attr.deps:
        transitive_files += dep.default_runfiles

    return struct(
        runfiles = ctx.runfiles(
            files = [output_file],
            transitive_files = transitive_files,
            collect_default = True,
        ),
    )

pex_attrs = {
    "srcs": attr.label_list(
        flags = ["DIRECT_COMPILE_TIME_INPUT"],
        allow_files = pex_file_types,
    ),
    "deps": attr.label_list(allow_files = False),
    "eggs": attr.label_list(
        flags = ["DIRECT_COMPILE_TIME_INPUT"],
        allow_files = egg_file_types,
    ),
    "reqs": attr.string_list(),
    "req_files": attr.label_list(
        flags = ["DIRECT_COMPILE_TIME_INPUT"],
        allow_files = req_file_types,
    ),
    "no_index": attr.bool(default = False),
    "disable_cache": attr.bool(default = False),
    "repos": attr.label_list(
        flags = ["DIRECT_COMPILE_TIME_INPUT"],
        allow_files = repo_file_types,
    ),
    "data": attr.label_list(
        allow_files = True,
        cfg = "data",
    ),

    # required for pex_library targets in third_party subdirs
    # but theoretically a common attribute for all rules
    "licenses": attr.license(),

    # Used by pex_binary and pex_*test, not pex_library:
    "_pexbuilder": attr.label(
        default = Label("@pex_bin//file"),
        executable = True,
        cfg = "host",
    ),
}

def _dmerge(a, b):
    """Merge two dictionaries, a+b

    Workaround for https://github.com/bazelbuild/skydoc/issues/10
    """
    return dict(a.items() + b.items())

pex_bin_attrs = _dmerge(pex_attrs, {
    "main": attr.label(
        allow_files = True,
        single_file = True,
    ),
    "entrypoint": attr.string(),
    "script": attr.string(),
    "interpreters": attr.string_list(),
    "platforms": attr.string_list(),
    "use_wheels": attr.bool(default = True),
    "verbosity": attr.int(default = 0),
    "zip_safe": attr.bool(
        default = True,
        mandatory = False,
    ),
    "strip_prefix": attr.string(default = ""),
})

pex_library = rule(
    _pex_library_impl,
    attrs = pex_attrs,
)

pex_binary = rule(
    _pex_binary_impl,
    executable = True,
    attrs = pex_bin_attrs,
)
"""Build a deployable pex executable.

Args:
  deps: Python module dependencies.

    `pex_library` and `py_library` rules should work here.

  eggs: `.egg` and `.whl` files to include as python packages.

  reqs: External requirements to retrieve from pypi, in `requirements.txt` format.

    This feature will reduce build determinism!  It tells pex to resolve all
    the transitive python dependencies and fetch them from pypi.

    It is recommended that you use `eggs` instead where possible.

  req_files: Add requirements from the given requirements files. Must be provided as labels.

    This feature will reduce build determinism!  It tells pex to resolve all
    the transitive python dependencies and fetch them from pypi.

    It is recommended that you use `eggs` or specify `no_index` instead where possible.

  no_index: If True, don't use pypi to resolve dependencies for `reqs` and `req_files`; Default: False

  disable_cache: Disable caching in the pex tool entirely. Default: False

  repos: Additional repository labels (filegroups of wheel/egg files) to look for requirements.

  data: Files to include as resources in the final pex binary.

    Putting other rules here will cause the *outputs* of those rules to be
    embedded in this one. Files will be included as-is. Paths in the archive
    will be relative to the workspace root.

  main: File to use as the entrypoint.

    If unspecified, `script` or first file from the `srcs` attribute will be used.
    It is an error to specify `entrypoint`, `main`, and `script` together.

  entrypoint: Name of a python module to use as the entrypoint.

    e.g. `your.project.main`

    If unspecified, the `main`, `script`, or first file from the `srcs` attribute will be used.
    It is an error to specify `entrypoint`, `main`, and `script` together.

  script: Set the entrypoint to the script or console_script as defined by any of the distributions in the pex.

    For example: "pex --script fab fabric" or "pex --script mturk boto"
    
    If unspecified, the first file from the `srcs` attribute will be used.
    It is an error to specify `entrypoint`, `main`, and `script` together.

  strip_prefix: Set the path prefix to strip out from your sources.

    For example: If you have `services/foo/bar.py` and you want to call it with an `entrypoint` of `foo.bar`,
    you can set `strip_prefix` to `services`.

  interpreters: The list of python interpreters used to build the pex. Either specify explicit paths to interpreters
    or specify binary names.

  platforms: The platforms for which to build the pex.

    To use wheels for specific interpreter/platform tags, you can append them to the platform with hyphens like:
    PLATFORM-IMPL-PYVER-ABI (e.g. "linux_x86_64-cp-27-cp27mu", "macosx_10.12_x86_64-cp-36-cp36m") PLATFORM is the
    host platform e.g. "linux-x86_64", "macosx-10.12-x86_64", etc". IMPL is the python implementation abbreviation
    (e.g. "cp", "pp", "jp"). PYVER is a two-digit string representing the python version (e.g. "27", "36"). ABI is
    the ABI tag (e.g. "cp36m", "cp27mu", "abi3", "none").

  verbosity: Set logging verbosity level.
"""

pex_test = rule(
    _pex_binary_impl,
    executable = True,
    attrs = pex_bin_attrs,
    test = True,
)

_pytest_pex_test = rule(
    _pex_pytest_impl,
    executable = True,
    test = True,
    attrs = _dmerge(pex_attrs, {
        "runner": attr.label(
            executable = True,
            mandatory = True,
            cfg = "data",
        ),
        "launcher_template": attr.label(
            allow_files = True,
            single_file = True,
            default = Label("//pex:testlauncher.sh.template"),
        ),
    }),
)

def pex_pytest(
        name,
        srcs,
        deps = [],
        eggs = [],
        data = [],
        args = [],
        flaky = False,
        licenses = [],
        local = None,
        size = None,
        timeout = None,
        tags = [],
        **kwargs):
    """A variant of pex_test that uses py.test to run one or more sets of tests.

    This produces two things:

      1. A pex_binary (`<name>_runner`) containing all your code and its
         dependencies, plus py.test, and the entrypoint set to the py.test
         runner.
      2. A small shell script to launch the `<name>_runner` executable with each
         of the `srcs` enumerated as commandline arguments.  This is the actual
         test entrypoint for bazel.

    Almost all of the attributes that can be used with pex_test work identically
    here, including those not specifically mentioned in this docstring.
    Exceptions are `main` and `entrypoint`, which cannot be used with this macro.

    Args:

      srcs: List of files containing tests that should be run.
    """
    if "main" in kwargs:
        fail("Specifying a `main` file makes no sense for pex_pytest.")
    if "entrypoint" in kwargs:
        fail("Do not specify `entrypoint` for pex_pytest.")

    pex_binary(
        name = "%s_runner" % name,
        srcs = srcs,
        deps = deps,
        data = data,
        eggs = eggs + [
            "@pytest_whl//file",
            "@py_whl//file",
        ],
        entrypoint = "pytest",
        licenses = licenses,
        testonly = True,
        **kwargs
    )
    _pytest_pex_test(
        name = name,
        runner = ":%s_runner" % name,
        args = args,
        data = data,
        flaky = flaky,
        licenses = licenses,
        local = local,
        size = size,
        srcs = srcs,
        timeout = timeout,
        tags = tags,
    )

def pex_repositories():
    """Rules to be invoked from WORKSPACE for remote dependencies."""
    native.http_file(
        name = "pytest_whl",
        url = "https://pypi.python.org/packages/8c/7d/f5d71f0e28af32388e07bd4ce0dbd2b3539693aadcae4403266173ec87fa/pytest-3.2.3-py2.py3-none-any.whl",
        sha256 = "81a25f36a97da3313e1125fce9e7bbbba565bc7fec3c5beb14c262ddab238ac1",
    )

    native.http_file(
        name = "py_whl",
        url = "https://pypi.python.org/packages/53/67/9620edf7803ab867b175e4fd23c7b8bd8eba11cb761514dcd2e726ef07da/py-1.4.34-py2.py3-none-any.whl",
        sha256 = "2ccb79b01769d99115aa600d7eed99f524bf752bba8f041dc1c184853514655a",
    )

    native.http_file(
        name = "pex_bin",
        executable = True,
        url = "https://github.com/pantsbuild/pex/releases/download/v1.6.2/pex27",
        sha256 = "f6395a71b15e1cbeedfd417724413f7f7f2453ffa6a91db0dbd884ad8576a4ce",
    )
