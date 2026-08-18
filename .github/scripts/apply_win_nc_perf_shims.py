#!/usr/bin/env python3
#
# Copied from hpf .github/scripts/ -- keep the two in sync.
"""
Make netCDF-C's tst_chunks3 compile with MSVC.

nc_perf is POSIX-only and not one of its sources carries a _WIN32 guard, so the
workload the NetCDF-4/CLIO benchmark measures cannot be built on Windows as it
stands. Two files stand between MSVC and the tst_chunks3 target:

  nc_perf/tst_chunks3.c  timing macros built on getrusage(2), which MSVC has
                         no equivalent of -- supply the part they use
  nc_perf/tst_utils.c    includes <sys/time.h> unguarded for struct timeval,
                         which on Windows comes from <winsock2.h>

The rest of nc_perf (bm_file, tst_ar4*, ...) is equally unportable and is left
alone: the driver builds the `tst_chunks3` target specifically rather than the
whole directory, so those never compile.

Why this is a script and not a .patch
-------------------------------------
It was a patch, and `git apply` failed twice in CI for reasons that had nothing
to do with the change: Git on Windows checks sources out as CRLF
(core.autocrlf=true), so an LF patch's context cannot match -- and once the
sources were pinned to LF, the *patch file itself* came out of the hpf checkout
as CRLF and failed the other way. A diff also carries line numbers and context
that go stale whenever upstream edits the file for unrelated reasons.

Anchoring on a distinctive line instead is immune to all of that: line endings
are normalised for matching and the file's own style is preserved on write, and
the only thing that has to stay true is that the include block still exists.

Usage:
    apply_win_nc_perf_shims.py <netcdf-c-source-dir>

Idempotent: a tree that already carries the shims is left alone. Exits non-zero
if an anchor is gone, because the build cannot succeed without these.
"""

import re
import sys
from pathlib import Path

# One marker per edit: they are what makes re-running a no-op, so two edits
# must not share one or the second would look already-applied (or worse, be
# inserted twice on a re-run against a tree that already has the first).
MARKER = "HPF_WIN32_GETRUSAGE_SHIM"
TIMEVAL_MARKER = "HPF_WIN32_TIMEVAL_SHIM"

# The include block the shim goes after. Matched with flexible line endings and
# trailing whitespace so neither a CRLF checkout nor a reformat breaks it.
ANCHOR = re.compile(
    rb"#ifdef[ \t]+HAVE_SYS_RESOURCE_H[ \t]*\r?\n"
    rb"#include[ \t]+<sys/resource\.h>[ \t]*\r?\n"
    rb"#endif[ \t]*\r?\n"
)

SHIM = """
/* {marker}
 *
 * MSVC has no getrusage(2), and nc_perf's timing macros are built on it, so
 * tst_chunks3 cannot be compiled on Windows as it stands. Supply the small
 * part of the interface those macros use, in the same units.
 *
 * GetProcessTimes reports kernel and user CPU time for the process in 100 ns
 * ticks, which is what ru_utime/ru_stime mean here -- the timing macros sum
 * the two and divide by the repetition count, so the measurement stays CPU
 * time and remains comparable with the POSIX platforms.
 *
 * ru_inblock/ru_oublock have no Win32 equivalent. They are read by the macros
 * but never printed (only the seconds field reaches the output the benchmark
 * parser consumes), so reporting zero costs nothing here. */
#if defined(_WIN32) && !defined(HAVE_SYS_RESOURCE_H)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>   /* struct timeval; must precede windows.h */
#include <windows.h>

#define RUSAGE_SELF 0

struct rusage {{
    struct timeval ru_utime;
    struct timeval ru_stime;
    long ru_inblock;
    long ru_oublock;
}};

static __inline void
hpf_filetime_to_timeval(const FILETIME *ft, struct timeval *tv)
{{
    /* 100 ns ticks since an epoch that cancels out: only differences are used */
    ULARGE_INTEGER t;
    t.LowPart = ft->dwLowDateTime;
    t.HighPart = ft->dwHighDateTime;
    tv->tv_sec = (long)(t.QuadPart / 10000000ULL);
    tv->tv_usec = (long)((t.QuadPart % 10000000ULL) / 10ULL);
}}

static __inline int
getrusage(int who, struct rusage *ru)
{{
    FILETIME creation, exit, kernel, user;
    (void)who;
    if (!GetProcessTimes(GetCurrentProcess(), &creation, &exit, &kernel, &user))
        return -1;
    hpf_filetime_to_timeval(&user, &ru->ru_utime);
    hpf_filetime_to_timeval(&kernel, &ru->ru_stime);
    ru->ru_inblock = 0;
    ru->ru_oublock = 0;
    return 0;
}}
#endif /* _WIN32 && !HAVE_SYS_RESOURCE_H */
""".format(marker=MARKER)


# tst_utils.c pulls in <sys/time.h> unconditionally, for struct timeval alone.
# On Windows that type lives in <winsock2.h>.
TIMEVAL_ANCHOR = re.compile(rb"#include[ \t]+<sys/time\.h>[ \t]*\r?\n")

TIMEVAL_REPLACEMENT = """#if defined(_WIN32) && !defined(HAVE_SYS_TIME_H)
/* {marker}: struct timeval comes from winsock2.h on Windows */
#include <winsock2.h>
#else
#include <sys/time.h>
#endif
""".format(marker=TIMEVAL_MARKER)


def file_eol(data: bytes) -> bytes:
    """The line ending the file already uses, so the result stays consistent."""
    return b"\r\n" if data.count(b"\r\n") > data.count(b"\n") // 2 else b"\n"


def edit(path: Path, anchor, make_text, marker: str, what: str,
         replace: bool = False) -> None:
    """Insert after (or replace) the anchor; idempotent, loud when it cannot."""
    if not path.is_file():
        print(f"ERROR: {path} not found", file=sys.stderr)
        sys.exit(1)

    data = path.read_bytes()
    if marker.encode() in data:
        print(f"{path}: {what} already present")
        return

    match = anchor.search(data)
    if not match:
        print(f"ERROR: could not find the {what} anchor in {path}.", file=sys.stderr)
        print("       nc_perf must have been reorganised upstream; "
              "re-anchor this script.", file=sys.stderr)
        sys.exit(1)

    eol = file_eol(data)
    text = make_text.replace("\n", eol.decode("ascii")).encode("ascii")
    start = match.start() if replace else match.end()
    patched = data[:start] + text + data[match.end():]
    path.write_bytes(patched)
    print(f"{path}: applied {what} ({len(text)} bytes, {eol!r} line endings)")


def main() -> None:
    if len(sys.argv) != 2:
        print("Usage: apply_win_nc_perf_shims.py <netcdf-c-source-dir>")
        sys.exit(2)

    root = Path(sys.argv[1]) / "nc_perf"
    edit(root / "tst_chunks3.c", ANCHOR, SHIM, MARKER, "getrusage shim")
    edit(root / "tst_utils.c", TIMEVAL_ANCHOR, TIMEVAL_REPLACEMENT,
         TIMEVAL_MARKER, "struct timeval include", replace=True)


if __name__ == "__main__":
    main()
