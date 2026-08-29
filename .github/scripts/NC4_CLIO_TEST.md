# netCDF-C test suite over CLIO

Runs the **whole** netCDF-C test suite -- unit tests, the ncdump/ncgen/nccopy
tool tests and the `nc_perf` performance tests -- three times over, once per
HDF5 storage stack, and publishes the failures as markdown on the wiki.

| Variant | Stack | How it is selected |
| --- | --- | --- |
| `baseline` | netCDF-C `main` + HDF5 `develop` | nothing set (sec2 VFD, native VOL) |
| `clio_vfd` | + clio-core `dev` HDF5 VFD | `HDF5_DRIVER=clio_vfd`, `HDF5_DRIVER_CONFIG="cache=1"` |
| `clio_vol` | + clio-core `dev` HDF5 VOL connector | `HDF5_VOL_CONNECTOR=clio` |

All three run **the same** netCDF-C binaries against **the same** HDF5 build.
Only the HDF5 plugin environment differs, so a test that passes in one variant
and fails in another indicts the CLIO adapter rather than a different library
build. The report leads with exactly that list -- *tests that pass on the
baseline but fail under CLIO*.

This is the test counterpart of hpf's NetCDF-4 CLIO **benchmark**
(`hpf/.github/workflows/nc4-clio-benchmark*.yml`), which these workflows are
modelled on. The benchmark measures one workload, `tst_chunks3`, and plots it
over time; this one asks a different question -- *what breaks* -- and answers it
for the whole suite.

## Pieces

| File | Role |
| --- | --- |
| `../workflows/nc4-clio-test.yml` | Linux (`ubuntu-latest`, in `iowarp/deps-cpu`) |
| `../workflows/nc4-clio-test-mac.yml` | macOS (`macos-latest`, conda deps via clio-core's `CI/ci-deps.sh`) |
| `../workflows/nc4-clio-test-win.yml` | Windows (`windows-latest`, vcpkg deps) |
| `nc4_clio_test.sh` | builds the three stacks and runs ctest per variant |
| `nc4_clio_report.py` | ctest logs + JUnit XML -> the wiki page and the index row |
| `clio_runtime.yaml` | `clio_run` compose config used by both CLIO variants |
| `apply_win_nc_perf_shims.py` | supplies `getrusage` so `tst_chunks3` compiles with MSVC (obsolete once [netcdf-c#3446](https://github.com/Unidata/netcdf-c/pull/3446) lands) |
| `patch_clio_conda_variants.sh` | macOS `c_stdlib` for clio-core's conda recipe |

The last two are copies of hpf's; keep them in sync.

## Where the results go

The wiki, one page per platform plus an index:

* `NetCDF-C-CLIO-Tests` -- one row per platform, rewritten in place by whichever
  workflow ran. A whole-page rewrite would blank the other two platforms' rows
  every time one of them ran, so the script merges on the `<!-- row:linux -->`
  markers instead.
* `NetCDF-C-CLIO-Tests-Linux` / `-macOS` / `-Windows` -- the full report:
  per-variant counts, the regressions-against-baseline table, and every failing
  test with the output ctest captured for it.

Full ctest logs, the JUnit XML and `clio_run.log` are attached to each run as the
`nc4-clio-test-results-<platform>-<run>` artifact; the wiki page carries only
what fits comfortably on a page (60 failure excerpts, 40 lines each).

**Pushing to a wiki needs a token that may not be `GITHUB_TOKEN`.** The
workflows use `secrets.WIKI_TOKEN` when it exists and fall back to
`GITHUB_TOKEN`. If the push step fails with a 403, add a `WIKI_TOKEN` repository
secret holding a PAT with `repo` (or fine-grained *Contents: write*) scope.

## Change gate

A run only happens when one of `HDFGroup/hdf5@develop`,
`Unidata/netcdf-c@main` or `iowarp/clio-core@dev` has moved since the last one.
The last tested triple is carried by the published wiki page itself, as an HTML
comment:

```
<!-- nc4-clio-stamp: {"hdf5_sha": "...", "netcdf_sha": "...", "clio_sha": "..."} -->
```

Keeping the stamp in the page rather than in a side-car file means it cannot
drift away from the results it describes. `workflow_dispatch` with `force: true`
overrides it.

## Running it locally

```bash
.github/scripts/nc4_clio_test.sh \
  --hdf5-src   ~/hdf5      \
  --netcdf-src ~/netcdf-c  \
  --clio-src   ~/clio-core \
  --work-dir   /tmp/nc4-clio-test \
  --results-dir /tmp/nc4-clio-test/results

python3 .github/scripts/nc4_clio_report.py \
  --results-dir /tmp/nc4-clio-test/results \
  --platform linux --platform-label "Linux (local)" \
  --page NetCDF-C-CLIO-Tests-Linux --out-dir /tmp/nc4-clio-test
```

`--clone` fetches the three sources instead. `--stages build` / `--stages run`
split the two phases so a rebuild is not needed to re-test, and `--variants`
narrows which stacks run.

## Things that are easy to get wrong

**A failing test is the deliverable, not an error.** ctest keeps going after a
failure by default and the driver never lets a non-zero ctest exit fail the run.
The only thing that cuts a variant short is `--run-timeout`, and that is recorded
as `ran_timeout` so the report can say the numbers are partial instead of
pretending the suite finished. `nc4_clio_test.sh` exits non-zero only for
structural failures -- a library that would not build, a results directory it
could not write.

**"No result" is four different things and the report has to say which.** The
driver records every variant's outcome, with a reason, in
`variant_status.tsv` (`<variant>\t<status>\t<note>`; statuses `ran`,
`ran_timeout`, `not_built`, `no_result`, `not_requested`). An adapter that does
not exist on the platform, one that fails to compile, and one that crashed must
not all render as the same empty table.

**The plugins must link the HDF5 the application links.** A VFD/VOL plugin is
`dlopen`'d into the process; built against a different `libhdf5` it either fails
to load or mismatches the VOL ABI, and HDF5 falls back to native *silently* --
which would make a CLIO variant a duplicate of the baseline with nothing in the
log to say so. The driver gates on `ldd` / `otool -L` (and on PATH order on
Windows, where the first `hdf5.dll` loaded wins for the whole process) and fails
the build if a plugin resolved the wrong one.

**The runtime needs the `clio_cte_filesystem` pool.** The VFD does its I/O
through the context-filesystem chimod, not through the CTE core pool directly.
Without that pool composed, the first `H5Fcreate` blocks forever while the
runtime logs `ChiMod 'clio_cte_filesystem' not found`. It is loaded at runtime,
so nothing in the plugin's link graph pulls it in -- the build target list names
`clio_cte_filesystem_runtime` explicitly.

**The VFD driver name is `clio_vfd`, not `clio`,** and `HDF5_DRIVER_CONFIG` is
`key=value`. clio-core's `adapter/vfd/README.md` says `clio`; `H5FD_CLIO_NAME`
in `H5FDclio.h` says `clio_vfd`, and the header is what HDF5 matches against. A
config string the driver cannot parse fails the open, and netCDF-C reports **any**
`H5Fcreate` failure as `Permission denied`, so a mistyped knob here shows up as
hundreds of unexplained test failures.

**Windows cannot build all of `nc_perf`, and it costs 11 tests in every variant.**
19 of the 23 sources fail with MSVC, from four separate causes: `<sys/time.h>`
and `<unistd.h>` included unguarded, `bigmeta.c`'s GNU `getopt_long_only()`,
`getopt`/`optarg`/`optind` unresolved at link time in `bm_file.c` and
`tst_ar4*.c`, and `strtok_r`/`sbrk`. `apply_win_nc_perf_shims.py` covers only the
first, for `tst_chunks3` and `tst_utils.c`. The Windows workflow therefore passes
`--allow-partial-netcdf-build`: ctest reports seven tests as *Not Run* and four
shell tests as failed, **in every variant including the baseline**, and the report
prints a warning naming the partial build so it does not read as a CLIO failure.

[Unidata/netcdf-c#3446](https://github.com/Unidata/netcdf-c/pull/3446) fixes all
four upstream and takes the baseline to 204/204. When it lands in `main`, drop
`--allow-partial-netcdf-build` from `nc4-clio-test-win.yml` and delete
`apply_win_nc_perf_shims.py` along with the block that calls it. Full analysis on
the wiki page
[NetCDF-C-CLIO-Tests-Windows-Fixes](https://github.com/hyoklee/actions/wiki/NetCDF-C-CLIO-Tests-Windows-Fixes).

**The CLIO VOL currently cannot exit.** With the connector selected a process
that leaves an HDF5 file open at `exit()` blocks forever in `H5_term_library` --
clio's atexit handler tears its client down first, and the connector then waits
on a reply that can never arrive (see hpf's `NC4_CLIO_BENCHMARK.md` for the
stack). Under ctest that shows up as a wall of `Timeout` results rather than a
single hang, which is why `--test-timeout` (1200 s in CI) and `--run-timeout`
(60 m) both matter: without them one variant would consume the whole job.

The per-test timeout was 300 s until run 32976716550, where it reported
`nc_perf_tst_files3` as a `clio_vol` failure that was nothing of the sort -- the
test was still running. The VOL is 9-14x slower than the baseline on the
write-heavy tests that do finish (`ncdump_tst_ncgen4`, `nc_test`,
`nc_test4_tst_files4`), and `nc_perf_tst_files3` takes 40 s on the baseline, so
300 s cut it off well short of where it would have landed. The two guards have
different jobs and only the second one bounds a hang: `--run-timeout` caps what a
wedged variant can cost, and `--test-timeout` should therefore be loose enough
that a slow-but-correct adapter is reported as slow rather than as broken.

**ctest `-j` is the same for every variant on purpose.** A test that only fails
under load then fails the same way in all three, and the comparison stays
honest. It also means the wall-clock column is a rough figure, not a benchmark --
for numbers, use hpf's benchmark workflows.

**`nc_perf` is not parallel-safe, and its `CMakeLists.txt` does not say so.**
`nc_perf_tst_create_files` writes `tst_<type>2_<n>D.nc`, `tst_elena_int_3D.nc`
and `tst_simple.nc` into the build directory; `run_bm_test1`, `run_bm_test2` and
`run_bm_elena` read exactly those files, and no `DEPENDS` connects them. Under
`ctest -j` the reader can therefore start while the writer is still writing --
which is what run 32976716550 did, reporting `nc_perf_run_bm_test1` as a
`clio_vfd` regression when the same suite had passed under `baseline` minutes
earlier purely because ctest scheduled the two the other way round. `bm_file`
returns the netCDF error without printing anything, so the only symptom is a
result table that stops mid-way.

The driver appends the missing `DEPENDS` to `nc_perf/CMakeLists.txt` before
configuring (`apply_nc_perf_test_order`, marker `NC4_CLIO_NC_PERF_TEST_ORDER`),
and only ever to a checkout it cloned itself. If a variant ever reports a
`nc_perf` failure that another variant in the same job does not, check the
`Start`/result interleaving in `ctest_<variant>.log` before blaming CLIO: two
`nc_perf` tests running at once is a harness bug, not an adapter bug.
