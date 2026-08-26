#!/usr/bin/env bash
#
# nc4_clio_test.sh -- run the WHOLE netCDF-C test suite (unit tests, tool tests
# and the nc_perf performance tests) three times over, once per HDF5 storage
# stack:
#
#   baseline   netCDF-C main + HDF5 develop                     (sec2 VFD, native VOL)
#   clio_vfd   netCDF-C main + HDF5 develop + clio-core dev VFD (HDF5_DRIVER=clio_vfd)
#   clio_vol   netCDF-C main + HDF5 develop + clio-core dev VOL (HDF5_VOL_CONNECTOR=clio)
#
# All three run the SAME netCDF-C and HDF5 build; only the HDF5 plugin
# environment differs, so a test that passes in one variant and fails in another
# indicts the CLIO adapter and not a different library build. Do not "optimize"
# this into three separate netCDF-C builds.
#
# Adapted from hpf's .github/scripts/nc4_clio_bench.sh, which measures
# tst_chunks3 rather than running the suite. The build half is nearly identical
# (same three trees, same ABI gate, same clio runtime); the run half is entirely
# different: ctest instead of one workload, and a failing test is DATA, not an
# error -- every variant runs to completion and the failures are reported at the
# end (see .github/scripts/nc4_clio_report.py).
#
# Exit status is non-zero only when something structural went wrong (a library
# failed to build, the results directory could not be written). Test failures
# never fail this script.
#
#   CI:    .github/workflows/nc4-clio-test*.yml call it with --clone
#   local: .github/scripts/nc4_clio_test.sh --hdf5-src ~/hdf5 \
#            --netcdf-src ~/netcdf-c --clio-src ~/clio-core --work-dir /tmp/nc4t

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------- portability
# Runs on Linux CI (ubuntu container), macOS CI and Windows CI (Git Bash).
# macOS ships bash 3.2, so keep this bash-3.2 clean: no `local -n` namerefs,
# no `declare -A`, and no GNU-only sed/find spellings.
OS="$(uname -s)"
case "$OS" in
    MINGW*|MSYS*|CYGWIN*) WIN=1 ;;
    *)                    WIN=0 ;;
esac

# CMake on Windows wants native (or mixed D:/foo) paths; bash wants something it
# can stat. MSYS2 accepts the mixed form for both, so convert once at the
# boundary and use one spelling everywhere afterwards.
native_path() { if [ "$WIN" = 1 ]; then cygpath -m "$1"; else echo "$1"; fi; }
# The inverse, for anything joined with ':'. PATH entries must NOT be the mixed
# form -- bash splits on ':', so "D:/a/actions" becomes "D" plus "/a/actions".
posix_path()  { if [ "$WIN" = 1 ]; then cygpath -u "$1"; else echo "$1"; fi; }

GIT_CLONE_OPTS=""
[ "$WIN" = 1 ] && GIT_CLONE_OPTS="-c core.autocrlf=false -c core.eol=lf"

CMAKE_TOOL_OPTS=""
CMAKE_CONFIG_OPTS=""
CMAKE_BUILD_OPTS=""
CTEST_CONFIG_OPTS=""
ZLIB_OPTS=""
VCPKG_INSTALLED=""

case "$OS" in
    MINGW*|MSYS*|CYGWIN*)
        NCPU="${NUMBER_OF_PROCESSORS:-4}"
        DSO_EXT="dll"
        # Visual Studio is a multi-config generator: the configuration is picked
        # at build time, so every --build/--install/ctest needs it.
        CMAKE_CONFIG_OPTS="-A x64"
        CMAKE_BUILD_OPTS="--config Release"
        CTEST_CONFIG_OPTS="-C Release"
        if [ -n "${VCPKG_INSTALLATION_ROOT:-}" ]; then
            VCPKG_INSTALLED="$(cygpath -m "$VCPKG_INSTALLATION_ROOT")/installed/x64-windows"
            ZLIB_OPTS="-DZLIB_ROOT=$VCPKG_INSTALLED -DZLIB_USE_EXTERNAL=OFF"
        fi
        ;;
    Darwin)
        NCPU="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
        # The conda env that supplies clio's dependencies puts conda's
        # llvm-tools on PATH; CMake then picks llvm-ranlib, which cannot load
        # its own runtime dylib and aborts static archiving intermittently
        # (clio-core issue #797). Xcode's ar/ranlib have no such dependency and
        # nothing here produces LTO archives.
        CMAKE_TOOL_OPTS="-DCMAKE_AR=$(xcrun -f ar 2>/dev/null || echo /usr/bin/ar)"
        CMAKE_TOOL_OPTS="$CMAKE_TOOL_OPTS -DCMAKE_RANLIB=$(xcrun -f ranlib 2>/dev/null || echo /usr/bin/ranlib)"
        DSO_EXT="dylib"
        ;;
    *)
        NCPU="$(nproc 2>/dev/null || echo 4)"
        DSO_EXT="so"
        ;;
esac

# coreutils timeout(1) is not in the macOS base system; Homebrew installs it as
# gtimeout. Fall back to a shell watchdog so a variant that wedges costs its own
# budget instead of the whole job.
TIMEOUT_BIN=""
if [ "$WIN" = 1 ]; then
    # NOT `command -v timeout`: on Windows that resolves to System32\timeout.exe,
    # an interactive "pause for N seconds" command that would silently sleep.
    [ -x /usr/bin/timeout ] && TIMEOUT_BIN="/usr/bin/timeout"
elif command -v timeout >/dev/null 2>&1; then
    TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_BIN="gtimeout"
fi

duration_seconds() {
    case "$1" in
        *h) echo $(( ${1%h} * 3600 )) ;;
        *m) echo $(( ${1%m} * 60 )) ;;
        *s) echo "${1%s}" ;;
        *)  echo "$1" ;;
    esac
}

run_with_timeout() {
    # run_with_timeout <duration> <cmd> [args...]
    local dur="$1"; shift
    if [ -n "$TIMEOUT_BIN" ]; then
        "$TIMEOUT_BIN" "$dur" "$@"
        return $?
    fi
    local secs pid watchdog rc=0
    secs="$(duration_seconds "$dur")"
    "$@" &
    pid=$!
    ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null || true
      sleep 10;      kill -KILL "$pid" 2>/dev/null || true ) >/dev/null 2>&1 &
    watchdog=$!
    wait "$pid" || rc=$?
    kill "$watchdog" 2>/dev/null || true
    return $rc
}

# ----------------------------------------------------------------- defaults
WORK_DIR="${PWD}/nc4-clio-work"
RESULTS_DIR=""
HDF5_SRC=""
NETCDF_SRC=""
CLIO_SRC=""
CLONE=0
HDF5_REF="develop"
NETCDF_REF="main"
CLIO_REF="dev"
HDF5_REPO="https://github.com/HDFGroup/hdf5.git"
NETCDF_REPO="https://github.com/Unidata/netcdf-c.git"
CLIO_REPO="https://github.com/iowarp/clio-core.git"
VARIANTS="baseline,clio_vfd,clio_vol"
STAGES="build,run"
JOBS="$NCPU"
CTEST_JOBS=4
TEST_TIMEOUT=1200         # per test, seconds -- ctest --timeout. Large enough
                          # that the CLIO VOL, which runs write-heavy tests up to
                          # ~14x slower than the baseline, is reported as slow
                          # rather than killed; --run-timeout is what bounds a hang.
RUN_TIMEOUT="120m"        # per variant, wall clock
ALLOW_ADAPTER_BUILD_FAILURE=0
ALLOW_PARTIAL_NETCDF_BUILD=0
UNBUILDABLE=""

usage() {
    sed -n '2,30p' "$0"
    cat <<'USAGE'

Options:
  --clone                    fetch the three sources into --work-dir
  --hdf5-src/--netcdf-src/--clio-src DIR  use an existing checkout
  --hdf5-ref/--netcdf-ref/--clio-ref REF  branch to clone (default develop/main/dev)
  --work-dir DIR             build trees and clones (default ./nc4-clio-work)
  --results-dir DIR          ctest logs, JUnit XML, variant_status.tsv
  --variants LIST            comma list of baseline,clio_vfd,clio_vol
  --stages LIST              comma list of build,run
  --jobs N                   compile parallelism
  --ctest-jobs N             ctest -j (same for every variant, for comparability)
  --test-timeout SECS        ctest --timeout, per test (default 1200)
  --run-timeout DURATION     wall clock per variant (default 120m)
  --allow-adapter-build-failure   drop a CLIO variant whose adapter will not build
  --allow-partial-netcdf-build    keep going when some netCDF-C test targets fail to compile
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --clone)         CLONE=1; shift ;;
        --hdf5-src)      HDF5_SRC="$2"; shift 2 ;;
        --netcdf-src)    NETCDF_SRC="$2"; shift 2 ;;
        --clio-src)      CLIO_SRC="$2"; shift 2 ;;
        --hdf5-ref)      HDF5_REF="$2"; shift 2 ;;
        --netcdf-ref)    NETCDF_REF="$2"; shift 2 ;;
        --clio-ref)      CLIO_REF="$2"; shift 2 ;;
        --work-dir)      WORK_DIR="$2"; shift 2 ;;
        --results-dir)   RESULTS_DIR="$2"; shift 2 ;;
        --variants)      VARIANTS="$2"; shift 2 ;;
        --stages)        STAGES="$2"; shift 2 ;;
        --jobs)          JOBS="$2"; shift 2 ;;
        --ctest-jobs)    CTEST_JOBS="$2"; shift 2 ;;
        --test-timeout)  TEST_TIMEOUT="$2"; shift 2 ;;
        --run-timeout)   RUN_TIMEOUT="$2"; shift 2 ;;
        --allow-adapter-build-failure) ALLOW_ADAPTER_BUILD_FAILURE=1; shift ;;
        --allow-partial-netcdf-build)  ALLOW_PARTIAL_NETCDF_BUILD=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

mkdir -p "$WORK_DIR"
WORK_DIR="$(cd "$WORK_DIR" && pwd)"
[ -n "$RESULTS_DIR" ] || RESULTS_DIR="$WORK_DIR/results"
mkdir -p "$RESULTS_DIR"
RESULTS_DIR="$(cd "$RESULTS_DIR" && pwd)"

HDF5_INSTALL="$WORK_DIR/hdf5-install"
NETCDF_INSTALL="$WORK_DIR/netcdf-install"
NETCDF_BUILD="$WORK_DIR/netcdf-build"
CLIO_BUILD="$WORK_DIR/clio-build"
CLIO_BIN="$CLIO_BUILD/bin"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '[warn] %s\n' "$*" >&2; }

has_stage()   { case ",$STAGES,"   in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
has_variant() { case ",$VARIANTS," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

# ------------------------------------------------------------ variant status
# <variant>\t<status>\t<note>. Appended, never rewritten: run_variant runs in a
# subshell, so a shell variable would not survive. Readers take the LAST row for
# a variant, which lets a later, better-informed row win.
#
# status is one of:
#   ran            ctest ran the suite to completion (with or without failures)
#   ran_timeout    ctest was killed at --run-timeout; results are partial
#   not_built      the adapter does not exist / does not compile on this platform
#   no_result      the variant never ran (clio runtime would not start)
#   not_requested  excluded via --variants
STATUS_FILE="$RESULTS_DIR/variant_status.tsv"
set_variant_status() { printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >>"$STATUS_FILE"; }

# Where the built plugins actually are. clio-core pins RUNTIME_OUTPUT_DIRECTORY
# to bin/, so on Windows the DLLs land in bin/ while only the import libraries
# go to bin/Release -- but both layouts exist in the wild, so locate the plugin
# instead of assuming either.
resolve_clio_bin() {
    [ "$WIN" = 1 ] || return 0
    local cand
    for cand in $(find "$CLIO_BUILD/bin" -maxdepth 2 \
                       \( -name clio_hdf5_vol.dll -o -name clio_vfd.dll \) 2>/dev/null); do
        CLIO_BIN="$(dirname "$cand")"
        return 0
    done
}

# ------------------------------------------------------------------ sources
resolve_src() {
    # resolve_src <given> <repo> <ref> <name>
    local given="$1" repo="$2" ref="$3" name="$4" dest="$WORK_DIR/$4-src"
    if [ -n "$given" ]; then echo "$given"; return; fi
    [ "$CLONE" = 1 ] || { echo "no --${name}-src and no --clone" >&2; exit 2; }
    if [ ! -d "$dest/.git" ]; then
        # shellcheck disable=SC2086  # GIT_CLONE_OPTS is a deliberate word-split
        git $GIT_CLONE_OPTS clone --depth 1 --branch "$ref" --recurse-submodules \
            "$repo" "$dest" >&2
    fi
    echo "$dest"
}

head_of() { git -C "$1" rev-parse HEAD 2>/dev/null || echo unknown; }

# The run stage does not need the sources -- it needs the trees the build stage
# left behind -- so a `--stages run` against an existing work dir must not insist
# on a checkout it will never read. It still wants sources.json, because the
# report labels the results with the SHAs actually built; an unknown stamp is
# better than refusing to run.
if ! has_stage build && [ ! -f "$WORK_DIR/sources.json" ]; then
    warn "no sources.json in $WORK_DIR; the report will not name the commits tested"
    printf '{"hdf5_sha":"unknown","netcdf_sha":"unknown","clio_sha":"unknown"}\n' \
        >"$WORK_DIR/sources.json"
fi

if has_stage build; then
    HDF5_SRC="$(resolve_src   "$HDF5_SRC"   "$HDF5_REPO"   "$HDF5_REF"   hdf5)"
    NETCDF_SRC="$(resolve_src "$NETCDF_SRC" "$NETCDF_REPO" "$NETCDF_REF" netcdf)"
    if has_variant clio_vfd || has_variant clio_vol; then
        CLIO_SRC="$(resolve_src "$CLIO_SRC" "$CLIO_REPO" "$CLIO_REF" clio)"
    fi
    cat >"$WORK_DIR/sources.json" <<JSON
{
  "hdf5_sha":   "$(head_of "$HDF5_SRC")",
  "netcdf_sha": "$(head_of "$NETCDF_SRC")",
  "clio_sha":   "$(head_of "${CLIO_SRC:-/nonexistent}")"
}
JSON
    cat "$WORK_DIR/sources.json"
fi

for v in baseline clio_vfd clio_vol; do
    has_variant "$v" || set_variant_status "$v" not_requested "excluded via --variants"
done

# ================================================================== build ===
if has_stage build; then

# A build starts a fresh accounting. `--stages run` alone does NOT truncate, so
# not_built rows from a preceding `--stages build` survive into the run.
: >"$STATUS_FILE"
for v in baseline clio_vfd clio_vol; do
    has_variant "$v" || set_variant_status "$v" not_requested "excluded via --variants"
done

log "Building HDF5 ($HDF5_REF) -> $HDF5_INSTALL"
# Shared libraries are mandatory: a VFD/VOL plugin is dlopen'd into the process
# and must resolve against the SAME libhdf5 the application links.
# shellcheck disable=SC2086  # the *_OPTS vars are a deliberate word-split
cmake -S "$(native_path "$HDF5_SRC")" -B "$(native_path "$WORK_DIR/hdf5-build")" \
      $CMAKE_TOOL_OPTS $CMAKE_CONFIG_OPTS $ZLIB_OPTS \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$(native_path "$HDF5_INSTALL")" \
      -DBUILD_SHARED_LIBS=ON \
      -DBUILD_STATIC_LIBS=OFF \
      -DHDF5_ENABLE_PARALLEL=OFF \
      -DHDF5_ENABLE_THREADSAFE=OFF \
      -DBUILD_TESTING=OFF \
      -DHDF5_BUILD_EXAMPLES=OFF \
      -DHDF5_BUILD_TOOLS=ON \
      -DHDF5_BUILD_HL_LIB=ON \
      -DHDF5_ENABLE_ZLIB_SUPPORT=ON \
      -DHDF5_ENABLE_Z_LIB_SUPPORT=ON \
      -DHDF5_ENABLE_SZIP_SUPPORT=OFF \
      >/dev/null
# shellcheck disable=SC2086
cmake --build "$(native_path "$WORK_DIR/hdf5-build")" -j "$JOBS" $CMAKE_BUILD_OPTS
# shellcheck disable=SC2086
cmake --install "$(native_path "$WORK_DIR/hdf5-build")" $CMAKE_BUILD_OPTS >/dev/null

# netCDF-C's nc_perf suite is POSIX-only: its timing macros are built on
# getrusage(2), which MSVC does not have, and not one of the 23 sources carries
# a _WIN32 guard. The performance tests are part of what this workflow is asked
# to run, so supply the shim rather than dropping them. Only ever applied to a
# checkout this script cloned itself -- silently rewriting a developer's tree
# would be a nasty surprise.
if [ "$WIN" = 1 ]; then
    case "$NETCDF_SRC" in
        "$WORK_DIR"/*)
            PY=python3; command -v python3 >/dev/null 2>&1 || PY=python
            "$PY" "$SCRIPT_DIR/apply_win_nc_perf_shims.py" "$NETCDF_SRC" ;;
        *)  warn "netcdf-c checkout was not cloned by this script; leaving it alone."
            warn "nc_perf will not compile on Windows without the getrusage shim." ;;
    esac
fi

# nc_perf is not parallel-safe and its CMakeLists does not say so. tst_create_files
# writes tst_<type>2_<n>D.nc, tst_elena_int_3D.nc and tst_simple.nc into the build
# directory, and run_bm_test1 / run_bm_test2 / run_bm_elena then read exactly those
# files -- but nothing declares the dependency, so under `ctest -j` the reader and
# the writer are free to run at the same time.
#
# They did, in run 32976716550: ctest started nc_perf_run_bm_test1 one slot before
# nc_perf_tst_create_files, bm_file read the 1D-4D files (leftovers from the
# preceding variant, still intact), reached tst_floats2_5D.nc while it was being
# rewritten and returned the netCDF error silently -- bm_file's `return ret` prints
# nothing, which is why the log ends mid-table with no message. That is a harness
# race, not a CLIO regression: the same suite passed under baseline in the same job,
# purely because ctest happened to schedule the two the other way round.
#
# ctest's DEPENDS is the ordering primitive, so declare what the shell scripts have
# always assumed. Appended rather than patched in place: it needs no anchor line,
# and `if(TEST ...)` keeps it correct when NETCDF_BUILD_UTILITIES is off and the
# run_bm_* tests do not exist. Only ever applied to a checkout this script cloned.
NC_PERF_ORDER_MARKER="NC4_CLIO_NC_PERF_TEST_ORDER"
apply_nc_perf_test_order() {
    local cml="$NETCDF_SRC/nc_perf/CMakeLists.txt"
    [ -f "$cml" ] || { warn "no nc_perf/CMakeLists.txt; skipping the test-order patch"; return 0; }
    if grep -q "$NC_PERF_ORDER_MARKER" "$cml"; then
        return 0
    fi
    cat >>"$cml" <<'CMAKE'

# NC4_CLIO_NC_PERF_TEST_ORDER -- added by hyoklee/actions .github/scripts/nc4_clio_test.sh.
# These three shell tests read the files nc_perf_tst_create_files writes. Without
# DEPENDS, `ctest -j` may run them while that test is still writing.
foreach(_nc4_clio_reader nc_perf_run_bm_test1 nc_perf_run_bm_test2 nc_perf_run_bm_elena)
  if(TEST ${_nc4_clio_reader})
    set_tests_properties(${_nc4_clio_reader} PROPERTIES DEPENDS nc_perf_tst_create_files)
  endif()
endforeach()
CMAKE
    log "netcdf-c: nc_perf tests ordered after tst_create_files"
}

case "$NETCDF_SRC" in
    "$WORK_DIR"/*) apply_nc_perf_test_order ;;
    *) warn "netcdf-c checkout was not cloned by this script; leaving its nc_perf test order alone." ;;
esac

log "Building netCDF-C ($NETCDF_REF) with its full test suite against HDF5 $HDF5_REF"
# ENABLE_TESTS + BUILD_UTILITIES + ENABLE_BENCHMARKS is the whole point of this
# workflow: unit tests, the ncdump/ncgen/nccopy tool tests, and nc_perf.
# DAP/NCZarr/byterange stay off -- they reach the network, and a flaky remote
# server would show up here as a CLIO adapter regression.
NETCDF_EXTRA_OPTS=""
if [ -n "${NC_M4:-}" ]; then
    # netCDF-C generates libsrc/attr.c and friends from .m4 sources; there is no
    # m4 in a stock Windows toolchain. Pre-seeding the cache variable satisfies
    # find_program(NC_M4 ...) without putting MSYS2's bin directory on PATH,
    # where its link.exe would shadow MSVC's linker.
    NETCDF_EXTRA_OPTS="-DNC_M4=$NC_M4"
    echo "netcdf-c: using m4 at $NC_M4"
fi
# shellcheck disable=SC2086  # the *_OPTS vars are a deliberate word-split
cmake -S "$(native_path "$NETCDF_SRC")" -B "$(native_path "$NETCDF_BUILD")" \
      $CMAKE_TOOL_OPTS $CMAKE_CONFIG_OPTS $ZLIB_OPTS $NETCDF_EXTRA_OPTS \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$(native_path "$NETCDF_INSTALL")" \
      -DCMAKE_PREFIX_PATH="$(native_path "$HDF5_INSTALL")${VCPKG_INSTALLED:+;$VCPKG_INSTALLED}" \
      -DHDF5_ROOT="$(native_path "$HDF5_INSTALL")" \
      -DENABLE_HDF5=ON \
      -DUSE_PARALLEL=OFF -DHDF5_PARALLEL=OFF -DUSE_PARALLEL4=OFF \
      -DENABLE_PARALLEL4=OFF \
      -DENABLE_DAP=OFF \
      -DENABLE_LIBXML2=OFF \
      -DENABLE_NCZARR=OFF \
      -DENABLE_BYTERANGE=OFF \
      -DENABLE_PLUGINS=OFF \
      -DBUILD_UTILITIES=ON \
      -DBUILD_TESTING=ON \
      -DENABLE_TESTS=ON \
      -DENABLE_BENCHMARKS=ON \
      >/dev/null

NETCDF_BUILD_NOTE=""
# shellcheck disable=SC2086  # CMAKE_BUILD_OPTS is a deliberate word-split
if cmake --build "$(native_path "$NETCDF_BUILD")" -j "$JOBS" $CMAKE_BUILD_OPTS; then
    :
else
    [ "$ALLOW_PARTIAL_NETCDF_BUILD" = 1 ] || {
        echo "ERROR: netCDF-C failed to build" >&2
        exit 1
    }
    # A test target that will not compile on this platform is itself a result
    # worth reporting: ctest will report the tests that need it as "Not Run",
    # and the report names the partial build so nobody reads that as a CLIO
    # regression. The library itself is not optional, though.
    warn "some netCDF-C targets failed to build; continuing with what did build"
    NETCDF_BUILD_NOTE="partial netCDF-C build: some test/tool targets did not compile"
    # shellcheck disable=SC2086
    cmake --build "$(native_path "$NETCDF_BUILD")" --target netcdf -j "$JOBS" $CMAKE_BUILD_OPTS
fi
printf '%s' "$NETCDF_BUILD_NOTE" >"$RESULTS_DIR/netcdf_build_note.txt"
# shellcheck disable=SC2086
cmake --install "$(native_path "$NETCDF_BUILD")" $CMAKE_BUILD_OPTS >/dev/null 2>&1 || \
    warn "netCDF-C install step failed; tests run out of the build tree anyway"

if has_variant clio_vfd || has_variant clio_vol; then
    log "Building clio-core ($CLIO_REF) VFD + VOL against HDF5 $HDF5_REF"

    # Our HDF5 must win over any other on the prefix path, but the rest of the
    # path has to survive: on macOS clio's dependencies (thallium, mercury,
    # argobots, cereal, yaml-cpp, ...) come from the conda env the workflow
    # activates and passes in through the environment.
    CLIO_PREFIX_PATH="$(native_path "$HDF5_INSTALL")"
    if [ -n "${CMAKE_PREFIX_PATH:-}" ]; then
        CLIO_PREFIX_PATH="$CLIO_PREFIX_PATH;$(echo "$CMAKE_PREFIX_PATH" | tr ':' ';')"
    fi

    # CLIO_CORE_ENABLE_ELF does pkg_check_modules(libelf REQUIRED libelf) and is
    # Linux-only. It no longer gates the VFD -- clio-core df614075 (PR #938)
    # moved add_subdirectory(vfd) to `if(UNIX AND CLIO_CTE_ENABLE_VFD)`, since
    # the VFD is a plugin HDF5 dlopen's and never touches real_api.h. So macOS
    # builds the VFD and Windows does not have the target at all.
    if [ "$WIN" = 1 ]; then
        CLIO_PLATFORM_OPTS="-DCLIO_CORE_ENABLE_ELF=OFF -DCLIO_CORE_ENABLE_CONDA=OFF"
        CLIO_PLATFORM_OPTS="$CLIO_PLATFORM_OPTS -DCLIO_CORE_ENABLE_RPATH=OFF"
        CLIO_PLATFORM_OPTS="$CLIO_PLATFORM_OPTS -DCLIO_CORE_ENABLE_ZMQ=ON -DCLIO_CORE_ENABLE_CEREAL=ON"
        CLIO_PLATFORM_OPTS="$CLIO_PLATFORM_OPTS -DVCPKG_TARGET_TRIPLET=x64-windows"
        CLIO_PLATFORM_OPTS="$CLIO_PLATFORM_OPTS -DVCPKG_MANIFEST_DIR=$(native_path "$CLIO_SRC")/installers/vcpkg"
        CLIO_PLATFORM_OPTS="$CLIO_PLATFORM_OPTS -DVCPKG_OVERLAY_PORTS=$(native_path "$CLIO_SRC")/installers/vcpkg/overlay-ports"
        CLIO_PLATFORM_OPTS="$CLIO_PLATFORM_OPTS -DVCPKG_APPLOCAL_DEPS=OFF"
        if [ -n "${VCPKG_INSTALLATION_ROOT:-}" ]; then
            CLIO_PLATFORM_OPTS="$CLIO_PLATFORM_OPTS -DCMAKE_TOOLCHAIN_FILE=$(native_path "$VCPKG_INSTALLATION_ROOT")/scripts/buildsystems/vcpkg.cmake"
        fi
    elif [ "$OS" = Darwin ]; then
        CLIO_PLATFORM_OPTS="-DCLIO_CORE_ENABLE_ELF=OFF -DCLIO_CORE_ENABLE_CONDA=ON"
    else
        CLIO_PLATFORM_OPTS="-DCLIO_CORE_ENABLE_ELF=ON -DCLIO_CORE_ENABLE_CONDA=OFF"
    fi

    # shellcheck disable=SC2086  # the *_OPTS vars are a deliberate word-split
    cmake -S "$(native_path "$CLIO_SRC")" -B "$(native_path "$CLIO_BUILD")" \
          $CMAKE_TOOL_OPTS $CMAKE_CONFIG_OPTS \
          -DCMAKE_PREFIX_PATH="$CLIO_PREFIX_PATH" \
          -DCMAKE_BUILD_TYPE=Release \
          $CLIO_PLATFORM_OPTS \
          -DHDF5_DIR="$(native_path "$HDF5_INSTALL")/cmake" \
          -DCLIO_CORE_ENABLE_RUNTIME=ON \
          -DCLIO_CORE_ENABLE_CTE=ON \
          -DCLIO_CORE_ENABLE_CAE=OFF \
          -DCLIO_CORE_ENABLE_CEE=OFF \
          -DCLIO_CORE_ENABLE_TESTS=OFF \
          -DCLIO_CORE_ENABLE_BENCHMARKS=OFF \
          -DCLIO_CORE_ENABLE_PYTHON=OFF \
          -DCLIO_CTE_ENABLE_POSIX_ADAPTER=ON \
          -DCLIO_CTE_ENABLE_STDIO_ADAPTER=ON \
          -DCLIO_CTE_ENABLE_VFD=ON \
          -DCLIO_CTE_ENABLE_HDF5_VOL=ON \
          -DCLIO_CTE_ENABLE_FUSE_ADAPTER=OFF \
          -DCLIO_CTE_ENABLE_ADIOS2_ADAPTER=OFF \
          -DCLIO_CTE_ENABLE_COMPRESS=OFF \
          -DCLIO_CORE_ENABLE_GRAY_SCOTT=OFF \
          -DCLIO_CTP_LOG_LEVEL=1

    # clio_cte_filesystem_runtime is the chimod the VFD's CFS client talks to.
    # It is loaded at runtime, so nothing in clio_vfd's link graph pulls it in --
    # omit it and the VFD hangs on its first H5Fcreate while the runtime logs
    # "ChiMod 'clio_cte_filesystem' not found".
    # shellcheck disable=SC2086
    cmake --build "$(native_path "$CLIO_BUILD")" -j "$JOBS" $CMAKE_BUILD_OPTS --target \
        clio_run clio_cte_core_runtime clio_cte_filesystem_runtime \
        clio_bdev_runtime clio_admin_runtime

    # One target at a time, so an adapter that does not compile on this platform
    # drops on its own and leaves the other variants testable.
    build_adapter() {
        # build_adapter <variant> <cmake-target>
        local variant="$1" target="$2" note
        has_variant "$variant" || return 0
        # shellcheck disable=SC2086
        if cmake --build "$(native_path "$CLIO_BUILD")" -j "$JOBS" $CMAKE_BUILD_OPTS --target "$target"; then
            return 0
        fi
        [ "$ALLOW_ADAPTER_BUILD_FAILURE" = 1 ] || {
            echo "ERROR: target $target failed to build" >&2
            exit 1
        }
        warn "target $target failed to build; dropping the $variant variant"
        VARIANTS="$(echo ",$VARIANTS," | sed "s/,$variant,/,/" | sed 's/^,//; s/,$//')"
        UNBUILDABLE="$UNBUILDABLE $variant"
        note="target $target did not build on $OS"
        if [ "$WIN" = 1 ] && [ "$variant" = clio_vfd ]; then
            note="$note: clio-core gates the VFD on UNIX, and the Windows port (PR #950) is on the fs-descriptor-windows branch, not on $CLIO_REF"
        fi
        set_variant_status "$variant" not_built "$note"
    }
    build_adapter clio_vfd clio_vfd
    build_adapter clio_vol clio_hdf5_vol

    # ABI gate. A plugin linked against a DIFFERENT libhdf5 than the application
    # either fails to load or corrupts the VOL ABI, and HDF5 reports that as a
    # silent fallback to native -- which would make a CLIO variant a duplicate
    # of the baseline with nothing in the log to say so. The risk is concrete on
    # macOS, where the conda env supplying clio's dependencies ships its own
    # libhdf5, and on Windows, where vcpkg does.
    check_links_our_hdf5() {
        # check_links_our_hdf5 <dso>
        local dso="$1" linked base soname first resolved hdf5_real rp
        base="$(basename "$dso")"
        if [ "$WIN" = 1 ]; then
            # Windows binds imports by bare filename with no soversion, and the
            # first hdf5.dll loaded serves the whole process. What the plugin
            # recorded is therefore not the question; what the loader finds
            # first is, and that is decided by PATH in the run stage below. All
            # that can be checked here is that no stray copy sits beside the
            # plugin, where it would win before PATH is consulted.
            if [ -f "$(dirname "$dso")/hdf5.dll" ] && \
               [ "$(dirname "$dso")" != "$(native_path "$HDF5_INSTALL")/bin" ]; then
                echo "ERROR: a stray hdf5.dll sits beside $base and would win over ours" >&2
                return 1
            fi
            echo "$base: no stray hdf5.dll beside it (PATH order decides; checked in the run stage)"
            return 0
        fi
        if [ "$OS" = Darwin ]; then
            # HDF5 stamps its install name as @rpath/libhdf5.<soversion>.dylib
            # and dyld searches each LC_RPATH in order FOR THAT EXACT FILENAME.
            # The conda env always ships some libhdf5, but as a different
            # release it cannot shadow ours -- so resolve the actual soname
            # rather than failing on "an earlier rpath contains some libhdf5".
            soname="$(otool -L "$dso" | awk '/libhdf5/ {print $1; exit}')"
            case "$soname" in
                @rpath/*)
                    soname="${soname#@rpath/}"
                    first=""
                    for rp in $(otool -l "$dso" | awk '/LC_RPATH/{f=1} f && /path /{print $2; f=0}'); do
                        case "$rp" in
                            @loader_path*) rp="$(dirname "$dso")${rp#@loader_path}" ;;
                        esac
                        if [ -f "$rp/$soname" ]; then first="$rp/$soname"; break; fi
                    done
                    [ -n "$first" ] || {
                        echo "ERROR: $base needs $soname but no rpath entry provides it" >&2
                        return 1
                    }
                    resolved="$(cd "$(dirname "$first")" && pwd -P)/$(basename "$first")"
                    hdf5_real="$(cd "$HDF5_INSTALL" && pwd -P)"
                    case "$resolved" in
                        "$hdf5_real"/*) echo "$base resolves $soname -> $resolved"; return 0 ;;
                        *) echo "ERROR: $base resolves $soname to $resolved, not the HDF5 under $HDF5_INSTALL" >&2
                           return 1 ;;
                    esac ;;
                "") echo "ERROR: $base does not link libhdf5 at all" >&2; return 1 ;;
                *)  echo "ERROR: $base links $soname, not the HDF5 under $HDF5_INSTALL" >&2
                    return 1 ;;
            esac
        fi
        linked="$(ldd "$dso" | awk '/libhdf5/ {print $3; exit}')"
        echo "$base -> libhdf5: ${linked:-<none>}"
        case "$linked" in
            "$HDF5_INSTALL"/*) return 0 ;;
            *) echo "ERROR: $base does not link the HDF5 under $HDF5_INSTALL" >&2; return 1 ;;
        esac
    }

    resolve_clio_bin
    for pair in "clio_vfd:libclio_vfd:clio_vfd" "clio_vol:libclio_hdf5_vol:clio_hdf5_vol"; do
        variant="${pair%%:*}"; rest="${pair#*:}"
        libname="${rest%%:*}"; winname="${rest#*:}"
        has_variant "$variant" || continue
        # MSVC produces clio_vfd.dll, not libclio_vfd.dll.
        if [ "$WIN" = 1 ]; then dso="$CLIO_BIN/$winname.dll"; else dso="$CLIO_BIN/$libname.$DSO_EXT"; fi
        [ -f "$dso" ] || { echo "missing $dso" >&2; exit 1; }
        check_links_our_hdf5 "$dso" || exit 1
    done
fi

fi  # stage build

# ==================================================================== run ===
if ! has_stage run; then
    log "stages=$STAGES -- skipping run"
    exit 0
fi

# Every run tests afresh, so drop the previous run's outcomes. not_built and
# not_requested rows are the exception: they are build-stage facts, and a
# `--stages build` + `--stages run` pair must not lose them.
if [ -f "$STATUS_FILE" ]; then
    awk -F'\t' '$2 == "not_built" || $2 == "not_requested"' "$STATUS_FILE" >"$STATUS_FILE.new" || true
    mv "$STATUS_FILE.new" "$STATUS_FILE"
fi

# Repeated from the build stage so that --stages run alone still finds them.
resolve_clio_bin

[ -d "$NETCDF_BUILD" ] || { echo "no netCDF-C build tree at $NETCDF_BUILD" >&2; exit 1; }

export LD_LIBRARY_PATH="$HDF5_INSTALL/lib:$NETCDF_INSTALL/lib:$CLIO_BIN${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# Some tests shell out to HDF5's own tools and resolve them through PATH --
# nc_test4/run_zero_len_att_test.sh runs `h5dump` and parses its output.
# Whatever HDF5 already sits on PATH (deps-cpu's under /usr/local, a conda env
# on a developer machine) is a DIFFERENT release from the one under test, and
# under a CLIO variant it inherits HDF5_VOL_CONNECTOR/HDF5_DRIVER pointing at a
# plugin built against an HDF5 it cannot load. The tool then fails and prints
# nothing, and the test reports a data mismatch that has nothing to do with
# CLIO. Our HDF5 goes first so the tools match the library.
export PATH="$HDF5_INSTALL/bin:$NETCDF_INSTALL/bin:$PATH"
# macOS: SIP strips DYLD_* from the environment of protected binaries, so this
# is belt-and-braces only. What actually resolves the libraries there is the
# install RPATH that all three projects bake in.
if [ "$OS" = Darwin ]; then
    export DYLD_LIBRARY_PATH="$HDF5_INSTALL/lib:$NETCDF_INSTALL/lib:$CLIO_BIN${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
fi
if [ "$WIN" = 1 ]; then
    # There is no rpath on Windows: a DLL is found beside the executable, in the
    # system directories, or on PATH -- and the first hdf5.dll to load wins for
    # every module in the process. Our HDF5 goes first, ahead of the vcpkg tree
    # that supplies clio's dependencies (and its own hdf5, which must not win).
    VCPKG_BIN="$CLIO_BUILD/vcpkg_installed/x64-windows/bin"
    # The install step is best-effort on Windows (its rules cover binaries a
    # partial build never produced), so netcdf.dll may only exist in the build
    # tree, beside the test executables the multi-config generator put there.
    NETCDF_DLL_DIR=""
    for cand in $(find "$NETCDF_BUILD" -name netcdf.dll -type f 2>/dev/null); do
        NETCDF_DLL_DIR="$(dirname "$cand")"; break
    done
    WIN_DLL_PATH="$(posix_path "$HDF5_INSTALL/bin")"
    WIN_DLL_PATH="$WIN_DLL_PATH:$(posix_path "$NETCDF_INSTALL/bin")"
    if [ -n "$NETCDF_DLL_DIR" ]; then
        WIN_DLL_PATH="$WIN_DLL_PATH:$(posix_path "$NETCDF_DLL_DIR")"
    fi
    WIN_DLL_PATH="$WIN_DLL_PATH:$(posix_path "$CLIO_BIN")"
    WIN_DLL_PATH="$WIN_DLL_PATH:$(posix_path "$VCPKG_BIN")"
    if [ -n "$VCPKG_INSTALLED" ]; then
        WIN_DLL_PATH="$WIN_DLL_PATH:$(posix_path "$VCPKG_INSTALLED/bin")"
    fi
    export PATH="$WIN_DLL_PATH:$PATH"
    echo "DLL search path: $WIN_DLL_PATH"
    [ -f "$HDF5_INSTALL/bin/hdf5.dll" ] || {
        echo "ERROR: no hdf5.dll under $HDF5_INSTALL/bin; the vcpkg copy would win" >&2
        exit 1
    }
fi

# ------------------------------------------------------------ clio runtime
CLIO_CONF="$WORK_DIR/clio_runtime.yaml"
CLIO_RUN_LOG="$WORK_DIR/clio_run.log"
CLIO_RUNTIME_STARTED=0

# clio/chimaera shm segments outlive a killed runtime and make the next
# `clio_run start` fail with "Address already in use". macOS has no /dev/shm --
# its POSIX shm objects are not exposed in the filesystem, so there is nothing
# to sweep and the runtime has to reclaim them itself.
clio_shm_sweep() {
    [ -d /dev/shm ] || return 0
    rm -f /dev/shm/chi_* /dev/shm/clio_* 2>/dev/null || true
}

clio_runtime_alive() {
    if [ "$WIN" = 1 ]; then
        tasklist //FI "IMAGENAME eq clio_run.exe" 2>/dev/null | grep -qi clio_run.exe
        return $?
    fi
    pgrep -f "^$CLIO_BIN/clio_run" >/dev/null 2>&1
}

clio_runtime_stop() {
    # Match the runtime we started by its full path: a bare `pkill -f clio_run`
    # would also kill a developer's unrelated clio_run on the same machine.
    if [ "$WIN" = 1 ]; then
        taskkill //F //IM clio_run.exe >/dev/null 2>&1 || true
    else
        pkill -f "^$CLIO_BIN/clio_run" >/dev/null 2>&1 || true
    fi
    [ "$CLIO_RUNTIME_STARTED" = 1 ] || return 0
    local i=0
    while [ $i -lt 60 ]; do
        clio_runtime_alive || break
        sleep 1; i=$((i + 1))
    done
    if clio_runtime_alive; then
        warn "clio_run still alive 60s after SIGTERM; sending SIGKILL"
        pkill -9 -f "^$CLIO_BIN/clio_run" >/dev/null 2>&1 || true
        sleep 2
    fi
    clio_shm_sweep
    CLIO_RUNTIME_STARTED=0
}

clio_runtime_start() {
    clio_runtime_stop
    clio_shm_sweep
    CLIO_RUNTIME_STARTED=1
    cp "$SCRIPT_DIR/clio_runtime.yaml" "$CLIO_CONF"
    CLIO_SERVER_CONF="$CLIO_CONF" "$CLIO_BIN/clio_run" start >"$CLIO_RUN_LOG" 2>&1 &
    local i=0
    while [ $i -lt 60 ]; do
        if grep -q "pools created successfully" "$CLIO_RUN_LOG" 2>/dev/null; then
            echo "clio_run ready"
            return 0
        fi
        if grep -q "Could not start TCP server" "$CLIO_RUN_LOG" 2>/dev/null; then
            warn "clio_run could not bind its server port; tail of $CLIO_RUN_LOG:"
            tail -40 "$CLIO_RUN_LOG" >&2 || true
            return 1
        fi
        sleep 1; i=$((i + 1))
    done
    warn "clio_run did not become ready in 60s; tail of $CLIO_RUN_LOG:"
    tail -40 "$CLIO_RUN_LOG" >&2 || true
    return 1
}

trap clio_runtime_stop EXIT

# --------------------------------------------------------------- run_suite
# run_suite <variant>
#
# Runs the ENTIRE ctest suite and never fails the script: a failing test is the
# result this workflow exists to collect. ctest already keeps going after a
# failure, so the only thing that can cut a variant short is the wall-clock
# guard -- and that is recorded as ran_timeout so the report can say the numbers
# are partial rather than pretending the suite finished.
run_suite() {
    local variant="$1" rc=0 started ended
    local logfile="$RESULTS_DIR/ctest_${variant}.log"
    local xml="$RESULTS_DIR/junit_${variant}.xml"

    log "ctest: $variant"
    rm -f "$xml"
    started="$(date -u +%s)"
    # ctest -j: the same for every variant, so a test that only fails under load
    # fails the same way in all three. --output-on-failure puts the failing
    # test's output in the log, which is what the report quotes when a JUnit XML
    # never gets written (a killed ctest writes none).
    # shellcheck disable=SC2086  # CTEST_CONFIG_OPTS is a deliberate word-split
    run_with_timeout "$RUN_TIMEOUT" \
        ctest --test-dir "$(native_path "$NETCDF_BUILD")" $CTEST_CONFIG_OPTS \
              -j "$CTEST_JOBS" \
              --timeout "$TEST_TIMEOUT" \
              --output-on-failure \
              --no-tests=error \
              --output-junit "$(native_path "$xml")" \
        >"$logfile" 2>&1 || rc=$?
    ended="$(date -u +%s)"
    echo "$((ended - started))" >"$RESULTS_DIR/duration_${variant}.txt"
    tail -30 "$logfile" || true

    if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
        warn "variant $variant hit the ${RUN_TIMEOUT} wall clock; results are partial"
        set_variant_status "$variant" ran_timeout \
            "ctest was killed after $RUN_TIMEOUT; the tests it had not reached are missing"
    else
        # Any other non-zero is "some tests failed", which is data, not an error.
        set_variant_status "$variant" ran "ctest exit $rc"
    fi
    return 0
}

# ------------------------------------------------------------------ baseline
if has_variant baseline; then
    ( unset HDF5_DRIVER HDF5_DRIVER_CONFIG HDF5_VOL_CONNECTOR HDF5_PLUGIN_PATH
      run_suite baseline )
fi

# ------------------------------------------------------------------ clio_vfd
if has_variant clio_vfd; then
    if clio_runtime_start; then
        ( unset HDF5_VOL_CONNECTOR
          export HDF5_PLUGIN_PATH="$CLIO_BIN"
          # The driver name is H5FD_CLIO_NAME from clio-core's H5FDclio.h --
          # `clio_vfd`, not the `clio` that adapter/vfd/README.md says. The
          # header is what HDF5 matches against.
          export HDF5_DRIVER="clio_vfd"
          # key=value, parsed by clio's shared grammar; unparseable input is
          # rejected on purpose. netCDF-C reports ANY H5Fcreate failure as
          # "Permission denied", so a mistyped knob here is very hard to see.
          export HDF5_DRIVER_CONFIG="cache=1"
          export CLIO_SERVER_CONF="$CLIO_CONF"
          run_suite clio_vfd )
    else
        set_variant_status clio_vfd no_result "clio_run did not become ready; variant never ran"
    fi
    clio_runtime_stop
fi

# ------------------------------------------------------------------ clio_vol
if has_variant clio_vol; then
    if clio_runtime_start; then
        ( unset HDF5_DRIVER HDF5_DRIVER_CONFIG
          export HDF5_PLUGIN_PATH="$CLIO_BIN"
          export HDF5_VOL_CONNECTOR="clio"   # under-VOL defaults to native
          export CLIO_SERVER_CONF="$CLIO_CONF"
          run_suite clio_vol )
    else
        set_variant_status clio_vol no_result "clio_run did not become ready; variant never ran"
    fi
    clio_runtime_stop
fi

cp "$WORK_DIR/sources.json" "$RESULTS_DIR/sources.json" 2>/dev/null || true
if [ -f "$CLIO_RUN_LOG" ]; then cp "$CLIO_RUN_LOG" "$RESULTS_DIR/clio_run.log"; fi

log "done -- results in $RESULTS_DIR"
cat "$STATUS_FILE" || true
