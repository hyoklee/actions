#!/usr/bin/env bash
#
# Copied from hpf .github/scripts/ -- keep the two in sync.
#
# Give clio-core's conda recipe a macOS `c_stdlib` before CI/ci-deps.sh renders
# it.  Temporary, and it removes itself: see "When this stops being needed".
#
# ---------------------------------------------------------------------------
# Why
# ---------------------------------------------------------------------------
# clio-core ae532d92 (PR #973, 2026-08-13) added `{{ stdlib("c") }}` to
# installers/conda/meta.yaml so the Linux package builds against
# sysroot_linux-64 2.28 and installs on RHEL8.  The matching variant keys in
# installers/conda/conda_build_config.yaml were written Linux-only:
#
#     c_stdlib:
#       - sysroot                 # [linux]
#     c_stdlib_version:
#       - '2.28'                  # [linux]
#
# conda-build strips `# [selector]` lines that do not match the build platform
# *before* parsing the YAML, so on macOS `c_stdlib` is simply undefined.  With
# no variant to consult, conda_build/jinja_context.py's `_target()` falls back
# to the language name itself:
#
#     package_prefix = language                      # "c", for stdlib
#     package = f"{package_prefix}_{target_platform}"
#
# so `{{ stdlib("c") }}` renders to the package name `c_osx-arm64`, which has
# never existed on conda-forge.  CI/ci-deps.sh --only-deps feeds the rendered
# requirements straight to `conda install`, which fails all three attempts with
#
#     PackagesNotFoundInChannelsError: The following packages are not
#     available from current channels:
#       - c_osx-arm64
#
# and the benchmark job dies before it builds anything.  This is also why
# clio-core's own ci-macos.yml has been red since 2026-08-13.
#
# The fix is the mapping conda-forge's pinning already publishes: on macOS the C
# stdlib package is `macosx_deployment_target`, whose per-target build is a real
# package (`macosx_deployment_target_osx-arm64`).  Versions mirror the recipe's
# own MACOSX_DEPLOYMENT_TARGET comment -- 11.0 is the arm64 default and 10.13 is
# the x86_64 floor nanobind's C++17 aligned new/delete needs.
#
# This touches the recipe's *variant config* only.  It selects which dependency
# packages conda resolves for the build environment; it does not patch a line of
# clio-core source, so the benchmark still measures the tree upstream ships.
#
# ---------------------------------------------------------------------------
# When this stops being needed
# ---------------------------------------------------------------------------
# Both exits below are no-ops that print why, so the call sites can stay in
# place until someone deletes them deliberately:
#
#   * the recipe stops calling `stdlib(` at all, or
#   * conda_build_config.yaml gains a `c_stdlib` entry that applies to macOS
#     (no selector, or one naming osx) -- i.e. upstream fixed it.
#
# Usage: patch_clio_conda_variants.sh <clio-core checkout>
# Set CLIO_CONDA_PATCH_FORCE=1 to run the edit off Darwin (for local testing).

set -euo pipefail

CLIO_SRC="${1:?usage: patch_clio_conda_variants.sh <clio-core checkout>}"

# The bug is macOS-only: on Linux the selectored entries match and render
# correctly, and patching there would *break* the 2.28 glibc floor #973 exists
# for.  Guard rather than trust the caller.
if [ "$(uname -s)" != "Darwin" ] && [ "${CLIO_CONDA_PATCH_FORCE:-0}" != "1" ]; then
  echo "patch_clio_conda_variants: not Darwin; nothing to do"
  exit 0
fi

python3 - "$CLIO_SRC" <<'PY'
import sys, os, re

clio_src = sys.argv[1]
recipe = os.path.join(clio_src, "installers", "conda")
cbc_path = os.path.join(recipe, "conda_build_config.yaml")
meta_path = os.path.join(recipe, "meta.yaml")

def done(msg):
    print(f"patch_clio_conda_variants: {msg}")
    sys.exit(0)

if not os.path.isfile(meta_path):
    done(f"no recipe at {meta_path}; nothing to do")

if "stdlib(" not in open(meta_path).read():
    done("recipe does not use stdlib(); nothing to patch")

lines = open(cbc_path).read().splitlines() if os.path.isfile(cbc_path) else []

# Items of a top-level list key, as (index, text). A selector is the trailing
# `# [...]` comment; conda-build drops the line when the selector is false, so
# an item is "live on macOS" when it has no selector or names osx.
def block(key):
    out, inside = [], False
    for i, line in enumerate(lines):
        if re.match(rf"^{re.escape(key)}\s*:", line):
            inside = True
            continue
        if inside:
            if re.match(r"^\s*-\s", line):
                out.append((i, line))
            elif line.strip() == "" or line.lstrip().startswith("#"):
                continue          # blank/comment lines stay inside the block
            else:
                break             # next top-level key
    return out

def applies_to_osx(item):
    m = re.search(r"#\s*\[([^\]]*)\]", item)
    return "osx" in m.group(1) if m else True

c_stdlib = block("c_stdlib")
if c_stdlib and any(applies_to_osx(text) for _, text in c_stdlib):
    done("conda_build_config.yaml already defines c_stdlib for macOS; nothing to patch")

ADDED = {
    "c_stdlib": ["  - macosx_deployment_target  # [osx]"],
    "c_stdlib_version": [
        "  - '11.0'                    # [osx and arm64]",
        "  - '10.13'                   # [osx and x86_64]",
    ],
}
NOTE = [
    "",
    "# Added by actions .github/scripts/patch_clio_conda_variants.sh -- macOS half of",
    "# the c_stdlib mapping PR #973 defined for Linux only. Without it",
    "# {{ stdlib(\"c\") }} renders as the nonexistent package c_osx-arm64.",
]

# Insert after the key's last item so the Linux entries keep their meaning;
# append the whole key when the recipe never declared it.
for key in ("c_stdlib", "c_stdlib_version"):
    items = block(key)
    if items:
        at = items[-1][0] + 1
        lines[at:at] = ADDED[key]
    else:
        lines.extend(NOTE if key == "c_stdlib" else [])
        lines.append(f"{key}:")
        lines.extend(ADDED[key])

with open(cbc_path, "w") as fh:
    fh.write("\n".join(lines) + "\n")

print("patch_clio_conda_variants: patched " + cbc_path)
for key in ("c_stdlib", "c_stdlib_version"):
    for _, text in block(key):
        print(f"  {key}: {text.strip()}")
PY
