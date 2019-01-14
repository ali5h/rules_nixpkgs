"""Rules for importing Nixpkgs packages."""

load("@bazel_tools//tools/cpp:cc_configure.bzl", "cc_autoconf_impl")
load("@bazel_tools//tools/cpp:lib_cc_configure.bzl", "get_cpu_value")

def _nixpkgs_git_repository_impl(repository_ctx):
    repository_ctx.file("BUILD")

    # Make "@nixpkgs" (syntactic sugar for "@nixpkgs//:nixpkgs") a valid
    # label for default.nix.
    repository_ctx.symlink("default.nix", repository_ctx.name)

    repository_ctx.download_and_extract(
        url = "%s/archive/%s.tar.gz" % (repository_ctx.attr.remote, repository_ctx.attr.revision),
        stripPrefix = "nixpkgs-" + repository_ctx.attr.revision,
        sha256 = repository_ctx.attr.sha256,
    )

nixpkgs_git_repository = repository_rule(
    implementation = _nixpkgs_git_repository_impl,
    attrs = {
        "revision": attr.string(mandatory = True),
        "remote": attr.string(default = "https://github.com/NixOS/nixpkgs"),
        "sha256": attr.string(),
    },
)

def _nixpkgs_local_repository_impl(repository_ctx):
    repository_ctx.file("BUILD")
    if not bool(repository_ctx.attr.nix_file) != \
       bool(repository_ctx.attr.nix_file_content):
        fail("Specify one of 'nix_file' or 'nix_file_content' (but not both).")
    if repository_ctx.attr.nix_file_content:
        repository_ctx.file(
            path = "default.nix",
            content = repository_ctx.attr.nix_file_content,
            executable = False,
        )
        target = repository_ctx.path("default.nix")
    else:
        target = repository_ctx.path(repository_ctx.attr.nix_file)
        repository_ctx.symlink(target, target.basename)

    # Make "@nixpkgs" (syntactic sugar for "@nixpkgs//:nixpkgs") a valid
    # label for the target Nix file.
    repository_ctx.symlink(target.basename, repository_ctx.name)

    _symlink_nix_file_deps(repository_ctx, repository_ctx.attr.nix_file_deps)

nixpkgs_local_repository = repository_rule(
    implementation = _nixpkgs_local_repository_impl,
    attrs = {
        "nix_file": attr.label(allow_single_file = [".nix"]),
        "nix_file_deps": attr.label_list(),
        "nix_file_content": attr.string(),
    },
)

def _is_supported_platform(repository_ctx):
    return repository_ctx.which("nix-build") != None

def _nixpkgs_package_impl(repository_ctx):
    repositories = repository_ctx.attr.repositories

    # Is nix supported on this platform?
    not_supported = not _is_supported_platform(repository_ctx)
    # Should we fail if Nix is not supported?
    fail_not_supported = repository_ctx.attr.fail_not_supported

    if repository_ctx.attr.build_file and repository_ctx.attr.build_file_content:
        fail("Specify one of 'build_file' or 'build_file_content', but not both.")
    elif repository_ctx.attr.build_file:
        repository_ctx.symlink(repository_ctx.attr.build_file, "BUILD")
    elif repository_ctx.attr.build_file_content:
        repository_ctx.file("BUILD", content = repository_ctx.attr.build_file_content)
    else:
        repository_ctx.template("BUILD", Label("@io_tweag_rules_nixpkgs//nixpkgs:BUILD.pkg"))

    strFailureImplicitNixpkgs = (
        "One of 'repositories', 'nix_file' or 'nix_file_content' must be provided. " +
        "The NIX_PATH environment variable is not inherited."
    )

    expr_args = []
    if repository_ctx.attr.nix_file and repository_ctx.attr.nix_file_content:
        fail("Specify one of 'nix_file' or 'nix_file_content', but not both.")
    elif repository_ctx.attr.nix_file:
        repository_ctx.symlink(repository_ctx.attr.nix_file, "default.nix")
    elif repository_ctx.attr.nix_file_content:
        expr_args = ["-E", repository_ctx.attr.nix_file_content]
    elif not repositories:
        fail(strFailureImplicitNixpkgs)
    else:
        expr_args = ["-E", "import <nixpkgs> {}"]

    _symlink_nix_file_deps(repository_ctx, repository_ctx.attr.nix_file_deps)

    expr_args.extend([
        "-A",
        repository_ctx.attr.attribute_path if repository_ctx.attr.nix_file or repository_ctx.attr.nix_file_content else repository_ctx.attr.attribute_path or repository_ctx.attr.name,
        # Creating an out link prevents nix from garbage collecting the store path.
        # nixpkgs uses `nix-support/` for such house-keeping files, so we mirror them
        # and use `bazel-support/`, under the assumption that no nix package has
        # a file named `bazel-support` in its root.
        # A `bazel clean` deletes the symlink and thus nix is free to garbage collect
        # the store path.
        "--out-link",
        "bazel-support/nix-out-link",
    ])

    expr_args.extend(repository_ctx.attr.nixopts)

    # If repositories is not set, leave empty so nix will fail
    # unless a pinned nixpkgs is set in the `nix_file` attribute.
    nix_path = ""
    if repositories:
        nix_path = ":".join(
            [
                (path_name + "=" + str(repository_ctx.path(target)))
                for (target, path_name) in repositories.items()
            ],
        )
    elif not (repository_ctx.attr.nix_file or repository_ctx.attr.nix_file_content):
        fail(strFailureImplicitNixpkgs)


    if not_supported and fail_not_supported:
        fail("Platform is not supported (see 'fail_not_supported')")
    elif not_supported:
        return
    else:
        nix_build_path = _executable_path(
            repository_ctx,
            "nix-build",
            extra_msg = "See: https://nixos.org/nix/",
        )
        nix_build = [nix_build_path] + expr_args

        # Large enough integer that Bazel can still parse. We don't have
        # access to MAX_INT and 0 is not a valid timeout so this is as good
        # as we can do.
        timeout = 1073741824
        exec_result = _execute_or_fail(
            repository_ctx,
            nix_build,
            failure_message = "Cannot build Nix attribute '{}'.".format(
                repository_ctx.attr.attribute_path,
            ),
            quiet = False,
            timeout = timeout,
            environment = dict(NIX_PATH = nix_path),
        )
        output_path = exec_result.stdout.splitlines()[-1]

        # Build a forest of symlinks (like new_local_package() does) to the
        # Nix store.
        for target in _find_children(repository_ctx, output_path):
            basename = target.rpartition("/")[-1]
            repository_ctx.symlink(target, basename)

_nixpkgs_package = repository_rule(
    implementation = _nixpkgs_package_impl,
    attrs = {
        "attribute_path": attr.string(),
        "nix_file": attr.label(allow_single_file = [".nix"]),
        "nix_file_deps": attr.label_list(),
        "nix_file_content": attr.string(),
        "repositories": attr.label_keyed_string_dict(),
        "repository": attr.label(),
        "build_file": attr.label(),
        "build_file_content": attr.string(),
        "nixopts": attr.string_list(),
        "fail_not_supported": attr.bool(default = True, doc = """
            If set to True (default) this rule will fail on platforms which do not support Nix (e.g. Windows). If set to False calling this rule will succeed but no output will be generated.
                                        """),
    },
)

def nixpkgs_package(*args, **kwargs):
    invert_repositories(_nixpkgs_package, *args, **kwargs)

def invert_dict(dict):
    """Swap the keys and values of a dict − assuming that all values are
    distinct
    """
    return {value: key for (key, value) in dict.items()}

def invert_repositories(f, *args, **kwargs):
    # Because of https://github.com/bazelbuild/bazel/issues/5356 we can't
    # directly pass a dict from strings to labels to the rule (which we'd like
    # for the `repositories` arguments), but we can pass a dict from labels to
    # strings. So we swap the keys and the values (assuming they all are
    # distinct).
    hasRepository = "repository" in kwargs and kwargs["repository"] != None
    hasRepositories = "repositories" in kwargs and kwargs["repositories"] != None
    if hasRepository and hasRepositories:
        fail("Specify one of 'repository' or 'repositories' (but not both).")
    if hasRepositories:
        inversed_repositories = invert_dict(kwargs["repositories"])
        kwargs["repositories"] = inversed_repositories
    if hasRepository:
        repository = kwargs.pop("repository")
        kwargs["repositories"] = { repository: "nixpkgs" }
    f(*args, **kwargs)

def _readlink(repository_ctx, path):
    return repository_ctx.path(path).realpath

def _nixpkgs_packages_instantiate_impl(repository_ctx):
    repository_ctx.file("BUILD", "exports_files([\"nix_attrs.nix\"])")

    nix_instantiate_path = _executable_path(
        repository_ctx,
        "nix-instantiate",
        extra_msg = "See: https://nixos.org/nix/",
    )

    packages_from_attr = \
        [
            "\"{name}\" = nixpkgs.{attrPath}".format(name = name, attrPath = attrPath)
            for (name, attrPath) in repository_ctx.attr.packagesFromAttr.items()
        ]

    generatedPackageFiles = {}
    for (name, expr) in repository_ctx.attr.packagesFromExpr.items():
        nix_definition_file = "__internal_" + name + "_definition.nix"
        repository_ctx.file(
            nix_definition_file,
            content = expr
            )
        # generatedPackageFiles[nix_definition_file] = name
        generatedPackageFiles[name] = nix_definition_file
    packagesFromFileLabels = \
      { name: Label(filePath)
        for (name, filePath) in repository_ctx.attr.packagesFromFile.items()
      }
    packagesFromFile = packagesFromFileLabels + generatedPackageFiles

    packages_from_file = \
        [
            "\"{name}\" = import {filePath}".format(name = name, filePath = repository_ctx.path(filePath))
            for (name, filePath) in packagesFromFile.items()
        ]

    packages_record_inside = ";".join(packages_from_attr + packages_from_file)
    packages_record = "nixpkgs: { " + packages_record_inside + "; }"

    repository_ctx.file("packages_attributes_mappings.nix", packages_record)

    nix_set_builder = repository_ctx.template("drv_set_builder.nix", Label("@io_tweag_rules_nixpkgs//nixpkgs:drv_set_builder.nix"))
    nix_instantiate_args = [
        "--eval",
        "--strict",
        "--read-write-mode",
        "--json",
        "drv_set_builder.nix",
        "--arg", "packages", "import ./packages_attributes_mappings.nix",
        ]

    nix_instantiate = [nix_instantiate_path] + \
        nix_instantiate_args + \
        repository_ctx.attr.nixopts

    # Large enough integer that Bazel can still parse. We don't have
    # access to MAX_INT and 0 is not a valid timeout so this is as good
    # as we can do.
    timeout = 1073741824

    nix_path = ":".join(
        [
            (path_name + "=" + str(repository_ctx.path(target)))
            for (target, path_name) in repository_ctx.attr.repositories.items()
        ],
    )

    exec_result = _execute_or_fail(
        repository_ctx,
        nix_instantiate,
        timeout = timeout,
        environment = dict(NIX_PATH = nix_path),
    )
    repository_ctx.file("nix_attrs.nix", content = exec_result.stdout)

nixpkgs_packages_instantiate_swapped = repository_rule(
    implementation = _nixpkgs_packages_instantiate_impl,
    attrs = {
        "packagesFromAttr": attr.string_dict(
            mandatory = False,
            doc = "A map between the name of the packages to instantiate and their attribute path in the nix expression",
        ),
        "packagesFromFile": attr.string_dict(
            mandatory = False,
            doc = "A map between the name of the packages to instantiate and a nix file defining them",
        ),
        "packagesFromExpr": attr.string_dict(
            mandatory = False,
            doc = "A map between the name of the packages to instantiate and their nix expression",
        ),
        "repositories": attr.label_keyed_string_dict(),
        "nixopts": attr.string_list(),
    },
)

def nixpkgs_packages_instantiate(**kwargs):
    invert_repositories(nixpkgs_packages_instantiate_swapped, **kwargs)

def _nixpkgs_package_realize_impl(repository_ctx):
    if repository_ctx.attr.build_file and repository_ctx.attr.build_file_content:
        fail("Specify one of 'build_file' or 'build_file_content', but not both.")
    elif repository_ctx.attr.build_file:
        repository_ctx.symlink(repository_ctx.attr.build_file, "BUILD")
    elif repository_ctx.attr.build_file_content:
        repository_ctx.file("BUILD", content = repository_ctx.attr.build_file_content)
    else:
        repository_ctx.template("BUILD", Label("@io_tweag_rules_nixpkgs//nixpkgs:BUILD.pkg"))

    nix_store_path = _executable_path(
        repository_ctx,
        "nix-store",
        extra_msg = "See: https://nixos.org/nix/",
    )
    nix_instantiate_path = _executable_path(
        repository_ctx,
        "nix-instantiate",
        extra_msg = "See: https://nixos.org/nix/",
    )

    attribute_path = repository_ctx.attr.name
    if repository_ctx.attr.attribute_name:
      attribute_path = repository_ctx.attr.attribute_name

    nix_instantiate_args = [
        "--eval",
        "-E", "(builtins.fromJSON (builtins.readFile {drv_set_file})).{attribute_path}".format(
            drv_set_file = repository_ctx.path(repository_ctx.attr.drv_set_file),
            attribute_path = attribute_path,
          )
        ]

    drv_path = _execute_or_fail(
        repository_ctx,
        [nix_instantiate_path] + nix_instantiate_args,
        quiet = True,
    ).stdout.strip("\"\n")

    nix_store_args = [
        "--realize",
        "--no-build-output",
        "--add-root", "nix-root", "--indirect",
        drv_path
        ] + repository_ctx.attr.nixopts
    exec_result = _execute_or_fail(
        repository_ctx,
        [nix_store_path] + nix_store_args,
        quiet = True,
    )
    output_path = exec_result.stdout.splitlines()[0]

    # Build a forest of symlinks (like new_local_package() does) to the
    # Nix store.
    for target in _find_children(repository_ctx, output_path):
        basename = target.rpartition("/")[-1]
        repository_ctx.symlink(target, basename)


nixpkgs_package_realize = repository_rule(
    implementation = _nixpkgs_package_realize_impl,
    attrs = {
        "drv_set_file": attr.label(
            allow_single_file = [".nix"],
            doc = "A nix file containing a map from package names to their drv path",
        ),
        "attribute_name": attr.string(),
        "build_file": attr.label(),
        "build_file_content": attr.string(),
        "nixopts": attr.string_list(),
    },
)

def nixpkgs_cc_autoconf_impl(repository_ctx):
    cpu_value = get_cpu_value(repository_ctx)
    if not _is_supported_platform(repository_ctx):
        cc_autoconf_impl(repository_ctx)
        return

    # Calling repository_ctx.path() on anything but a regular file
    # fails. So the roundabout way to do the same thing is to find
    # a regular file we know is in the workspace (i.e. the WORKSPACE
    # file itself) and then use dirname to get the path of the workspace
    # root.
    workspace_file_path = repository_ctx.path(
        Label("@nixpkgs_cc_toolchain//:WORKSPACE"),
    )
    workspace_root = _execute_or_fail(
        repository_ctx,
        ["dirname", workspace_file_path],
    ).stdout.rstrip()

    # Make a list of all available tools in the Nix derivation. Override
    # the Bazel autoconfiguration with the tools we found.
    bin_contents = _find_children(repository_ctx, workspace_root + "/bin")
    overriden_tools = {
        tool: _readlink(repository_ctx, entry)
        for entry in bin_contents
        for tool in [entry.rpartition("/")[-1]]  # Compute basename
    }
    cc_autoconf_impl(repository_ctx, overriden_tools = overriden_tools)

nixpkgs_cc_autoconf = repository_rule(
    implementation = nixpkgs_cc_autoconf_impl,
    # Copied from
    # https://github.com/bazelbuild/bazel/blob/master/tools/cpp/cc_configure.bzl.
    # Keep in sync.
    environ = [
        "ABI_LIBC_VERSION",
        "ABI_VERSION",
        "BAZEL_COMPILER",
        "BAZEL_HOST_SYSTEM",
        "BAZEL_LINKOPTS",
        "BAZEL_PYTHON",
        "BAZEL_SH",
        "BAZEL_TARGET_CPU",
        "BAZEL_TARGET_LIBC",
        "BAZEL_TARGET_SYSTEM",
        "BAZEL_USE_CPP_ONLY_TOOLCHAIN",
        "BAZEL_DO_NOT_DETECT_CPP_TOOLCHAIN",
        "BAZEL_USE_LLVM_NATIVE_COVERAGE",
        "BAZEL_VC",
        "BAZEL_VS",
        "BAZEL_LLVM",
        "USE_CLANG_CL",
        "CC",
        "CC_CONFIGURE_DEBUG",
        "CC_TOOLCHAIN_NAME",
        "CPLUS_INCLUDE_PATH",
        "GCOV",
        "HOMEBREW_RUBY_PATH",
        "SYSTEMROOT",
        "VS90COMNTOOLS",
        "VS100COMNTOOLS",
        "VS110COMNTOOLS",
        "VS120COMNTOOLS",
        "VS140COMNTOOLS",
    ],
)

def nixpkgs_cc_configure(
        repository = None,
        repositories = None,
        nix_file = None,
        nix_file_deps = None,
        nix_file_content = None,
        nixopts = []):
    """Use a CC toolchain from Nixpkgs. No-op if not a nix-based platform.

    By default, Bazel auto-configures a CC toolchain from commands (e.g.
    `gcc`) available in the environment. To make builds more hermetic, use
    this rule to specific explicitly which commands the toolchain should
    use.
    """
    if not nix_file and not nix_file_content:
        nix_file_content = """
          with import <nixpkgs> {}; buildEnv {
            name = "bazel-cc-toolchain";
            paths = [ stdenv.cc binutils ];
          }
        """
    nixpkgs_package(
        name = "nixpkgs_cc_toolchain",
        repository = repository,
        repositories = repositories,
        nix_file = nix_file,
        nix_file_deps = nix_file_deps,
        nix_file_content = nix_file_content,
        build_file_content = """exports_files(glob(["bin/*"]))""",
        nixopts = nixopts,
    )

    # Following lines should match
    # https://github.com/bazelbuild/bazel/blob/master/tools/cpp/cc_configure.bzl#L93.
    nixpkgs_cc_autoconf(name = "local_config_cc")
    native.bind(name = "cc_toolchain", actual = "@local_config_cc//:toolchain")
    native.register_toolchains("@local_config_cc//:all")

def _execute_or_fail(repository_ctx, arguments, failure_message = "", *args, **kwargs):
    """Call repository_ctx.execute() and fail if non-zero return code."""
    result = repository_ctx.execute(arguments, *args, **kwargs)
    if result.return_code:
        outputs = dict(
            failure_message = failure_message,
            arguments = arguments,
            return_code = result.return_code,
            stderr = result.stderr,
        )
        fail("""
{failure_message}
Command: {arguments}
Return code: {return_code}
Error output:
{stderr}
""".format(**outputs))
    return result

def _find_children(repository_ctx, target_dir):
    find_args = [
        _executable_path(repository_ctx, "find"),
        "-L",
        target_dir,
        "-maxdepth",
        "1",
        # otherwise the directory is printed as well
        "-mindepth",
        "1",
        # filenames can contain \n
        "-print0",
    ]
    exec_result = _execute_or_fail(repository_ctx, find_args)
    return exec_result.stdout.rstrip("\0").split("\0")

def _executable_path(repository_ctx, exe_name, extra_msg = ""):
    """Try to find the executable, fail with an error."""
    path = repository_ctx.which(exe_name)
    if path == None:
        fail("Could not find the `{}` executable in PATH.{}\n"
            .format(exe_name, " " + extra_msg if extra_msg else ""))
    return path

def _symlink_nix_file_deps(repository_ctx, deps):
    """Introduce an artificial dependency with a bogus name on each input."""
    for dep in deps:
        components = [c for c in [dep.workspace_root, dep.package, dep.name] if c]
        link = "/".join(components).replace("_", "_U").replace("/", "_S")
        repository_ctx.symlink(dep, link)
