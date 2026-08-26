#!/usr/bin/env python3
"""
Turn a netCDF-C/CLIO test run into the markdown the wiki publishes.

Reads the results directory nc4_clio_test.sh wrote:

    ctest_<variant>.log        ctest console output (--output-on-failure)
    junit_<variant>.xml        ctest --output-junit, absent if ctest was killed
    duration_<variant>.txt     wall clock, seconds
    variant_status.tsv         <variant>\\t<status>\\t<note>, last row wins
    netcdf_build_note.txt      set when some netCDF-C targets did not compile
    sources.json               the three SHAs actually built

and writes

    <page>.md                  the per-platform wiki page
    summary.md                 a short version for $GITHUB_STEP_SUMMARY

and, given --index, rewrites this platform's row in the wiki index page.

Two things this deliberately does NOT do:

  * fail. A failing test is the result being collected, and a variant that never
    ran is reported as such rather than silently omitted -- "no failures" and
    "the adapter does not exist on this platform" must not render the same.
  * trust the JUnit XML to exist. ctest writes it when it finishes, so a variant
    killed by the driver's wall-clock guard has only the console log, and the
    log parser below is what keeps those partial results readable.

Usage:
    nc4_clio_report.py --results-dir DIR --platform linux --platform-label "Linux (ubuntu-latest)" \\
        --page NetCDF-C-CLIO-Tests-Linux --out-dir DIR [--index PATH] \\
        [--run-url URL] [--run-number N] [--runner ubuntu-latest]
"""

import argparse
import codecs
import html
import json
import re
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

VARIANTS = ["baseline", "clio_vfd", "clio_vol"]

VARIANT_BLURB = {
    "baseline": "netCDF-C + HDF5, stock (sec2 VFD, native VOL)",
    "clio_vfd": "`HDF5_DRIVER=clio_vfd`, `HDF5_DRIVER_CONFIG=cache=1`",
    "clio_vol": "`HDF5_VOL_CONNECTOR=clio`",
}

# How the driver's status words read on the page. The distinction between them
# is the whole reason variant_status.tsv exists: an adapter that does not build
# on this platform and one that crashed used to print the same warning.
STATUS_CELL = {
    "ran": "ran",
    "ran_timeout": ":hourglass: killed at the wall clock — **partial results**",
    "not_built": ":no_entry_sign: adapter not built on this platform",
    "no_result": ":warning: no result — the variant never ran",
    "not_requested": "not requested",
}

MAX_OUTPUT_LINES = 40      # per failing test, in the details block
MAX_DETAIL_TESTS = 60      # per variant, before the page just lists names
MAX_LISTED_TESTS = 400     # per variant, in the failure table

# ctest console line, e.g.
#   12/431 Test  #12: nc_test_tst_names ...........   Passed    0.51 sec
#   13/431 Test  #13: ncdump_tst_output ...........***Failed    0.02 sec
CTEST_LINE = re.compile(
    r"^\s*\d+/\d+\s+Test\s+#(\d+):\s+(\S+)\s+\.*\s*(?:\*\*\*)?(.*?)\s+([\d.]+)\s+sec\s*$"
)


def _cp1252_fallback(err):
    """Decode the bytes UTF-8 choked on as cp1252, one run of bytes at a time."""
    return err.object[err.start:err.end].decode("cp1252", errors="replace"), err.end


codecs.register_error("cp1252_fallback", _cp1252_fallback)


def read_text_lenient(path):
    """Read a file as UTF-8, rescuing stray cp1252 bytes, never raising.

    Every file this script reads is decoded through here, and every file it
    writes is written encoding="utf-8", because Path.read_text/write_text
    without an encoding use the *locale's* encoding and the three workflows do
    not share one. The Windows runner writes the wiki index in cp1252, so its
    "·" separator lands as a bare 0xb7 -- which the Linux run then cannot
    decode at all, and the whole report step dies on a byte in a row it does not
    even own (run 32976716550).

    The fallback is per-byte-run rather than a whole-file second pass, because
    the index is genuinely mixed: the Linux and macOS rows hold a correct UTF-8
    "·" (c2 b7) and only the Windows row holds the bare 0xb7, so decoding the
    whole file as cp1252 would rescue that one row by mojibaking the other two.
    Since the page is rewritten encoding="utf-8", one run through here heals it.

    ctest logs get the same treatment for a different reason -- a test that
    prints raw bytes is not a reporting error.
    """
    return path.read_bytes().decode("utf-8", errors="cp1252_fallback")


def normalize_status(text):
    t = text.strip().lower()
    if t.startswith("passed"):
        return "passed"
    if t.startswith("skipped"):
        return "skipped"
    if t.startswith("not run"):
        return "notrun"
    if t.startswith("timeout"):
        return "timeout"
    return "failed"          # Failed, Exception: SegFault, Child aborted, ...


def parse_junit(path):
    """[(name, status, seconds, output)] from ctest --output-junit, or None."""
    if not path.is_file():
        return None
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError:
        return None
    tests = []
    for case in root.iter("testcase"):
        name = case.get("name", "?")
        secs = float(case.get("time") or 0.0)
        status = case.get("status", "run")
        out = ""
        if case.find("skipped") is not None:
            st = "skipped"
        elif case.find("failure") is not None or status == "fail":
            st = "failed"
            fail = case.find("failure")
            if fail is not None:
                out = (fail.get("message") or "") + "\n" + (fail.text or "")
        elif status in ("notrun", "disabled"):
            st = "notrun"
        else:
            st = "passed"
        # ctest puts the failure reason in <failure> and the test's own stdout in
        # <system-out>, and the reason on its own is usually just the word
        # "Failed" -- which says nothing about why. Keep both.
        sysout = case.find("system-out")
        if st in ("failed", "timeout") and sysout is not None and sysout.text:
            if sysout.text.strip() not in out:
                out = (out + "\n" + sysout.text) if out.strip() else sysout.text
        tests.append((name, st, secs, out.strip()))
    return tests or None


def parse_ctest_log(path):
    """[(name, status, seconds, output)] from the console log.

    The fallback for a variant ctest never finished: no XML gets written, but
    every test that did run has already printed its result line.
    """
    if not path.is_file():
        return []
    tests = []
    for line in read_text_lenient(path).splitlines():
        m = CTEST_LINE.match(line)
        if m:
            tests.append((m.group(2), normalize_status(m.group(3)), float(m.group(4)), ""))
    return tests


# Where a quoted output block ends: the next test's result line, the next
# "Start N: name" banner, or end of log. Without the Start arm the excerpt for
# one failure runs on into the announcement of the next test.
STOP = r"(?=^\s*\d+/\d+\s+Test(?:ing)?[: #]|^\s*Start\s+\d+:|\Z)"


def failure_output_from_log(path, names):
    """Map test name -> the output ctest printed for it under --output-on-failure.

    ctest brackets each failing test's output with a banner naming the test, so
    the sections can be sliced out even when -j interleaved the run.
    """
    out = {}
    if not path.is_file() or not names:
        return out
    text = read_text_lenient(path)
    # "N/M Test #N: name .....***Failed" is followed by the output block in
    # serial runs; in parallel runs ctest emits a labelled banner first.
    for name in names:
        m = re.search(
            r"^\s*\d+/\d+\s+Testing:\s+" + re.escape(name) + r"\s*$(.*?)" + STOP,
            text, re.M | re.S)
        if not m:
            m = re.search(
                r"^(?:\d+: )?.*Test\s+#\d+:\s+" + re.escape(name) + r"\s+\.*\s*\*\*\*.*?$(.*?)" + STOP,
                text, re.M | re.S)
        if m:
            out[name] = m.group(1).strip()
    return out


def read_status(results):
    """variant -> (status, note). Last row for a variant wins."""
    st = {}
    tsv = results / "variant_status.tsv"
    if tsv.is_file():
        for line in read_text_lenient(tsv).splitlines():
            parts = line.split("\t")
            if len(parts) >= 2:
                st[parts[0]] = (parts[1], parts[2] if len(parts) > 2 else "")
    return st


def collect(results):
    status = read_status(results)
    data = {}
    for v in VARIANTS:
        st, note = status.get(v, ("", ""))
        tests = parse_junit(results / f"junit_{v}.xml")
        source = "ctest --output-junit"
        log = results / f"ctest_{v}.log"
        if tests is None:
            tests = parse_ctest_log(log)
            source = "ctest console log (no JUnit XML — the run did not finish)"
        if not st:
            st = "ran" if tests else "no_result"
        dur = 0
        dpath = results / f"duration_{v}.txt"
        if dpath.is_file():
            try:
                dur = int(read_text_lenient(dpath).strip() or 0)
            except ValueError:
                dur = 0
        by = {}
        for name, s, secs, out in tests:
            by.setdefault(s, []).append((name, secs, out))
        data[v] = {
            "status": st, "note": note, "tests": tests, "by": by,
            "duration": dur, "source": source, "log": log,
        }
    return data


def hms(seconds):
    if not seconds:
        # A variant that never ran gets an explicit "—" from the caller; a
        # sub-second one is not the same thing and must not read as absent.
        return "<1s"
    h, rem = divmod(int(seconds), 3600)
    m, s = divmod(rem, 60)
    return f"{h}h{m:02d}m" if h else (f"{m}m{s:02d}s" if m else f"{s}s")


def counts(d):
    by = d["by"]
    n = lambda k: len(by.get(k, []))
    return {
        "total": len(d["tests"]),
        "passed": n("passed"),
        "failed": n("failed") + n("timeout"),
        "skipped": n("skipped"),
        "notrun": n("notrun"),
    }


def verdict(d):
    """One cell for the index page."""
    st = d["status"]
    if st in ("not_built", "not_requested", "no_result"):
        return STATUS_CELL.get(st, st)
    c = counts(d)
    if c["total"] == 0:
        return ":warning: no tests ran"
    flag = " :hourglass:" if st == "ran_timeout" else ""
    if c["failed"] == 0:
        return f":white_check_mark: {c['passed']}/{c['total']} passed{flag}"
    return f":x: {c['failed']} failed of {c['total']}{flag}"


def fence(text, lines=MAX_OUTPUT_LINES):
    body = [l.rstrip() for l in text.splitlines()]
    if len(body) > lines:
        body = body[:lines] + [f"... [{len(text.splitlines()) - lines} more lines truncated]"]
    body = [l.replace("```", "'''") for l in body]
    return "```\n" + "\n".join(body) + "\n```"


def render(args, data, sources, build_note):
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    L = []
    a = L.append
    a(f"# netCDF-C + CLIO test results — {args.platform_label}")
    a("")
    run = f"[run #{args.run_number}]({args.run_url})" if args.run_url else "a local run"
    a(f"The full netCDF-C test suite — unit tests, the ncdump/ncgen/nccopy tool "
      f"tests and the nc_perf performance tests — run three times over, once per "
      f"HDF5 storage stack. Generated by {run} on **{now}**.")
    a("")
    a("| source | ref | commit |")
    a("| --- | --- | --- |")
    a(f"| [HDF5](https://github.com/HDFGroup/hdf5) | `develop` | `{sources.get('hdf5_sha','?')[:12]}` |")
    a(f"| [netCDF-C](https://github.com/Unidata/netcdf-c) | `main` | `{sources.get('netcdf_sha','?')[:12]}` |")
    a(f"| [clio-core](https://github.com/iowarp/clio-core) | `dev` | `{sources.get('clio_sha','?')[:12]}` |")
    a("")
    a(f"Runner: `{args.runner}`. All three variants use the **same** netCDF-C and "
      "HDF5 build; only the HDF5 plugin environment differs, so a test that "
      "passes in one and fails in another indicts the CLIO adapter rather than a "
      "different library build.")
    a("")
    if build_note:
        a(f"> :warning: {build_note}. Tests needing a target that did not compile "
          "are reported by ctest as *Not Run*, in every variant alike.")
        a("")

    a("## Summary")
    a("")
    a("| variant | stack | outcome | tests | passed | failed | skipped | not run | wall clock |")
    a("| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |")
    for v in VARIANTS:
        d = data[v]
        c = counts(d)
        cell = STATUS_CELL.get(d["status"], d["status"])
        if c["total"] == 0 and d["status"] in ("not_built", "no_result", "not_requested"):
            a(f"| `{v}` | {VARIANT_BLURB[v]} | {cell} | — | — | — | — | — | — |")
        else:
            a(f"| `{v}` | {VARIANT_BLURB[v]} | {cell} | {c['total']} | {c['passed']} | "
              f"{c['failed']} | {c['skipped']} | {c['notrun']} | {hms(d['duration'])} |")
    a("")
    for v in VARIANTS:
        note = data[v]["note"]
        if note and data[v]["status"] not in ("ran",):
            a(f"- `{v}`: {note}")
    a("")

    # ---- regressions: the list worth reading first
    base_pass = {n for n, s, _, _ in data["baseline"]["tests"] if s == "passed"}
    a("## Tests that pass on the baseline but fail under CLIO")
    a("")
    if not base_pass:
        a("_The baseline produced no passing tests, so there is nothing to compare against._")
    else:
        any_reg = False
        for v in ("clio_vfd", "clio_vol"):
            d = data[v]
            if d["status"] in ("not_built", "not_requested", "no_result"):
                a(f"### `{v}`")
                a("")
                a(f"_{STATUS_CELL.get(d['status'], d['status'])} — nothing to compare._")
                a("")
                continue
            regressed = [(n, s, t) for n, s, t, _ in d["tests"]
                         if s in ("failed", "timeout") and n in base_pass]
            a(f"### `{v}` — {len(regressed)} regression(s)")
            a("")
            if not regressed:
                a("_None: every test that passes on the baseline also passes here._")
            else:
                any_reg = True
                a("| test | status | seconds |")
                a("| --- | --- | ---: |")
                for n, s, t in sorted(regressed)[:MAX_LISTED_TESTS]:
                    a(f"| `{n}` | {s} | {t:.1f} |")
                if len(regressed) > MAX_LISTED_TESTS:
                    a(f"| _… {len(regressed) - MAX_LISTED_TESTS} more_ | | |")
            a("")
        if not any_reg:
            a("_No CLIO variant regressed a test the baseline passes._")
            a("")

    # ---- full failure report per variant
    a("## Failures in detail")
    a("")
    for v in VARIANTS:
        d = data[v]
        c = counts(d)
        a(f"### `{v}`")
        a("")
        if d["status"] in ("not_built", "not_requested", "no_result"):
            a(STATUS_CELL.get(d["status"], d["status"]) + (f" — {d['note']}" if d["note"] else ""))
            a("")
            continue
        fails = [(n, s, t, o) for n, s, t, o in d["tests"] if s in ("failed", "timeout")]
        a(f"{c['failed']} failed, {c['passed']} passed, {c['skipped']} skipped, "
          f"{c['notrun']} not run, of {c['total']} — parsed from {d['source']}.")
        a("")
        if not fails:
            a("_No failures._")
            a("")
            continue
        missing = [n for n, _, _, o in fails if not o]
        extra = failure_output_from_log(d["log"], missing[:MAX_DETAIL_TESTS])
        a("| test | status | seconds |")
        a("| --- | --- | ---: |")
        for n, s, t, _ in sorted(fails)[:MAX_LISTED_TESTS]:
            a(f"| `{n}` | {s} | {t:.1f} |")
        if len(fails) > MAX_LISTED_TESTS:
            a(f"| _… {len(fails) - MAX_LISTED_TESTS} more_ | | |")
        a("")
        shown = 0
        for n, s, t, o in sorted(fails):
            if shown >= MAX_DETAIL_TESTS:
                a(f"_Output for the remaining {len(fails) - shown} failures is in the "
                  "run's `nc4-clio-test-results` artifact._")
                a("")
                break
            body = o or extra.get(n, "")
            if not body:
                continue
            a("<details>")
            a(f"<summary><code>{html.escape(n)}</code> — {s}</summary>")
            a("")
            a(fence(body))
            a("")
            a("</details>")
            a("")
            shown += 1
    a("")
    a("---")
    a("")
    a("Produced by [`.github/workflows/nc4-clio-test*.yml`]"
      "(https://github.com/hyoklee/actions/tree/main/.github/workflows) via "
      "[`.github/scripts/nc4_clio_test.sh`]"
      "(https://github.com/hyoklee/actions/blob/main/.github/scripts/nc4_clio_test.sh). "
      "Full ctest logs, JUnit XML and the clio runtime log are attached to each run "
      "as the `nc4-clio-test-results` artifact.")
    # The change gate reads this back off the published page: the workflow only
    # spends an hour rebuilding three trees when one of the three upstream HEADs
    # actually moved. Keeping it in the page rather than in a side-car file
    # means the stamp cannot drift away from the results it describes.
    stamp = dict(sources)
    stamp.update(platform=args.platform, run_id=args.run_id,
                 run_number=args.run_number, completed_at=now)
    a("")
    a("<!-- nc4-clio-stamp: " + json.dumps(stamp, sort_keys=True) + " -->")
    return "\n".join(L) + "\n"


def render_summary(args, data):
    L = [f"### netCDF-C + CLIO tests — {args.platform_label}", "",
         "| variant | outcome | tests | passed | failed | skipped | not run | wall clock |",
         "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for v in VARIANTS:
        d = data[v]
        c = counts(d)
        L.append(f"| `{v}` | {verdict(d)} | {c['total']} | {c['passed']} | {c['failed']} | "
                 f"{c['skipped']} | {c['notrun']} | {hms(d['duration'])} |")
    L.append("")
    return "\n".join(L) + "\n"


# The index page as it looks before any platform has run. Only used when the
# page does not exist yet: an existing page is edited row by row, so the prose
# below it -- which is maintained by hand on the wiki -- survives every run.
INDEX_TEMPLATE = """\
# netCDF-C + CLIO test matrix

The full netCDF-C test suite — unit tests, tool tests and the nc_perf
performance tests — run on three platforms against three HDF5 storage stacks:
stock HDF5, the clio-core HDF5 **VFD** (`HDF5_DRIVER=clio_vfd`), and the
clio-core HDF5 **VOL** connector (`HDF5_VOL_CONNECTOR=clio`).

Each row is rewritten by the platform's own workflow, so a platform that has not
run yet says so rather than borrowing another platform's numbers.

| platform | last run | baseline | clio_vfd | clio_vol | report |
| --- | --- | --- | --- | --- | --- |
| Linux (ubuntu-latest) | not run yet | — | — | — | [details](NetCDF-C-CLIO-Tests-Linux) | <!-- row:linux -->
| macOS (macos-latest) | not run yet | — | — | — | [details](NetCDF-C-CLIO-Tests-macOS) | <!-- row:macos -->
| Windows (windows-latest) | not run yet | — | — | — | [details](NetCDF-C-CLIO-Tests-Windows) | <!-- row:windows -->

Workflows: [`nc4-clio-test.yml`](https://github.com/hyoklee/actions/blob/main/.github/workflows/nc4-clio-test.yml),
[`nc4-clio-test-mac.yml`](https://github.com/hyoklee/actions/blob/main/.github/workflows/nc4-clio-test-mac.yml),
[`nc4-clio-test-win.yml`](https://github.com/hyoklee/actions/blob/main/.github/workflows/nc4-clio-test-win.yml).

## What each row means

All three variants of a platform run the **same** netCDF-C and HDF5 build; only
the HDF5 plugin environment differs. A test that passes on the baseline and
fails under a CLIO variant is therefore attributable to the adapter, and each
platform's report leads with exactly that list.

A cell can also say something other than a pass/fail count:

| cell | meaning |
| --- | --- |
| :no_entry_sign: adapter not built on this platform | the target does not exist or does not compile there — a platform gap, not a crash |
| :warning: never ran | `clio_run` would not become ready, so the variant was skipped |
| :hourglass: | the variant was killed at its wall-clock limit; the counts are partial |

Known platform gaps as of clio-core `dev` @ `a19a0356`: the HDF5 **VFD** target
is gated on `if(UNIX AND ...)` and so does not exist on Windows (the port,
[PR #950](https://github.com/iowarp/clio-core/pull/950), is on the
`fs-descriptor-windows` branch), and the **VOL** does not compile on macOS or
Windows — it reads `st.st_mtim`, which Darwin spells `st_mtimespec` and MSVC does
not have at all ([PR #971](https://github.com/iowarp/clio-core/pull/971)). Both
are reported as *adapter not built* rather than as an empty result.

## How the runs are triggered

Daily on a cron (Linux 13:00, macOS 15:00, Windows 17:00 UTC), but only when
`HDFGroup/hdf5@develop`, `Unidata/netcdf-c@main` or `iowarp/clio-core@dev` has
moved since the last run — the last tested triple is stamped into each platform
page as an HTML comment. Run any of them by hand from the Actions tab with
**force** to override the gate.

Setup, options and the failure modes worth knowing about are documented in
[`.github/scripts/NC4_CLIO_TEST.md`](https://github.com/hyoklee/actions/blob/main/.github/scripts/NC4_CLIO_TEST.md).
"""



def update_index(path, args, data):
    """Rewrite this platform's row, leaving the rest of the page alone.

    Three workflows push to one wiki, so the page has to be edited rather than
    regenerated: a whole-page rewrite would blank the other two platforms every
    time one of them ran, and would throw away the prose maintained by hand
    underneath the table.
    """
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    link = f"[{args.run_number}]({args.run_url})" if args.run_url else "local"
    marker = f"<!-- row:{args.platform} -->"
    row = (f"| {args.platform_label} | {now} · run {link} | "
           f"{verdict(data['baseline'])} | {verdict(data['clio_vfd'])} | "
           f"{verdict(data['clio_vol'])} | [details]({args.page}) | {marker}")

    text = read_text_lenient(path) if path.is_file() else INDEX_TEMPLATE
    lines = text.splitlines()

    for i, line in enumerate(lines):
        if marker in line:
            lines[i] = row
            break
    else:
        # No row for this platform yet: put it after the last row that is there,
        # or failing that after the table header separator.
        last = max((i for i, l in enumerate(lines) if re.search(r"<!-- row:[a-z0-9_]+ -->", l)),
                   default=None)
        if last is None:
            last = next((i for i, l in enumerate(lines) if re.match(r"^\|\s*---", l)), len(lines) - 1)
        lines.insert(last + 1, row)

    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--results-dir", required=True)
    p.add_argument("--platform", required=True, help="row key: linux|macos|windows")
    p.add_argument("--platform-label", required=True)
    p.add_argument("--page", required=True, help="wiki page name, without .md")
    p.add_argument("--out-dir", required=True)
    p.add_argument("--index", help="wiki index page to rewrite this platform's row in")
    p.add_argument("--run-url", default="")
    p.add_argument("--run-number", default="")
    p.add_argument("--run-id", default="")
    p.add_argument("--runner", default="")
    args = p.parse_args()

    results = Path(args.results_dir)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    sources = {}
    sj = results / "sources.json"
    if sj.is_file():
        try:
            sources = json.loads(read_text_lenient(sj))
        except json.JSONDecodeError:
            pass
    note_path = results / "netcdf_build_note.txt"
    build_note = read_text_lenient(note_path).strip() if note_path.is_file() else ""

    data = collect(results)
    (out_dir / f"{args.page}.md").write_text(render(args, data, sources, build_note),
                                             encoding="utf-8")
    (out_dir / "summary.md").write_text(render_summary(args, data), encoding="utf-8")
    if args.index:
        update_index(Path(args.index), args, data)

    for v in VARIANTS:
        c = counts(data[v])
        print(f"{v:10s} {data[v]['status']:12s} "
              f"total={c['total']} passed={c['passed']} failed={c['failed']} "
              f"skipped={c['skipped']} notrun={c['notrun']}")


if __name__ == "__main__":
    main()
