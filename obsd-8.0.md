# OpenBSD 8.0 HDF5 tests under QEMU

Notes on running `.github/workflows/obsd-8.0_matrix.yml` (HDF5 `develop` on
OpenBSD 8.0 via `vmactions/openbsd-vm`) for x86_64, aarch64, riscv64 and
sparc64, both on GitHub and locally with [act](https://github.com/nektos/act).
Collected 2026-10-21/22.

## GitHub results

Run [39702319713](https://github.com/hyoklee/actions/actions/runs/39702319713)
(ccache + `-j2`, default 1200 s test timeout):

| Arch    | Result                          | Duration | Failed tests                                       |
|---------|---------------------------------|----------|----------------------------------------------------|
| x86_64  | success                         | 19 min   | -                                                  |
| riscv64 | 2820/2821 passed                | 3h27m    | `testhdf5-select` (timeout)                        |
| aarch64 | 2818/2821 passed                | 5h24m    | `testhdf5-select`, `dsets`, `cache_image` (timeout) |
| sparc64 | cancelled at the 6 h job limit  | 6h00m    | never finished building                            |

* x86_64 is fast because GitHub's `ubuntu-latest` exposes `/dev/kvm`.
  The other three architectures are pure TCG (software emulation).
* Every failure is a timeout, not a wrong result.
* sparc64 cannot fit in a GitHub-hosted job: configure alone took 1031 s and
  the build was still running when the job was cancelled.  QEMU's sun4u
  machine is single-CPU, so `-j2` does not help it.

## Test timeouts

HDF5's `CTestConfig.cmake` sets the timeout with `FORCE`:

```cmake
set (DART_TESTING_TIMEOUT 1200 CACHE STRING "..." FORCE)
```

so `-DDART_TESTING_TIMEOUT=2400` on the cmake command line is silently reset
to 1200 (verified: `DartConfiguration.tcl` still says `TimeOut: 1200`).  Use
ctest's command-line option instead:

```sh
ctest -D Experimental -C Release -j2 --timeout 2400
```

Only 5 tests set their own `TIMEOUT` property (7200 s); every other test uses
the default, so `--timeout` doubles the limit for all of them.

## aarch64 vs riscv64: slow, not hung

aarch64 has two more timeouts than riscv64 (`dsets`, `cache_image`).  The
evidence points to slower emulation, not an aarch64-specific HDF5 hang:

* Per-test time, aarch64 / riscv64, over 2781 tests: median 1.28x,
  90th percentile 2.2x.  Total 5.4 h vs 3.5 h.
* Scaling riscv64 by 1.28x lands both tests right at the limit:

  | Test          | riscv64        | x 1.28  | aarch64          |
  |---------------|----------------|---------|------------------|
  | `dsets`       | 932 s, passed  | 1193 s  | timeout (1200 s) |
  | `cache_image` | 935 s, passed  | 1197 s  | timeout (1200 s) |

* CDash output for aarch64 `cache_image` shows it was still advancing: it had
  passed 11 of 18 subtests and was inside smoke check 6, the heaviest one
  (256 create/write/delete + close/reopen cycles, `MAX_NUM_DSETS` in
  `test/cache_image.c`).
* `testhdf5-select` times out on every TCG architecture, including a local
  x86_64 run without KVM.
* CDash captured no output for the timed-out aarch64 `dsets`, so its progress
  is not proven.  Running `bin/dsets` alone without a timeout would settle it.

Likely reason aarch64 emulates slower (not verified): anyvm starts OpenBSD
aarch64 guests with `-cpu max` under TCG, which enables pointer
authentication emulated with QARMA5, and OpenBSD arm64 signs return addresses
in nearly every function.  `ttsafe` (threads) was 2.4x slower, consistent
with the extra cost of emulating memory ordering across vCPUs.
`-cpu max,pauth-impdef=on` would be faster, but vmactions has no input for the
CPU model.

## Hardware acceleration on GitHub arm64 runners

[`kvm-probe.yml`](.github/workflows/kvm-probe.yml) (manual dispatch), run
[39706770295](https://github.com/hyoklee/actions/actions/runs/39706770295):

| Runner             | Result                          |
|--------------------|---------------------------------|
| `ubuntu-24.04-arm` | no `/dev/kvm`                   |
| `macos-15` (arm64) | `kern.hv_support` sysctl absent (no HVF) |

anyvm would use KVM or HVF for aarch64 guests if available, but neither runner
provides it, so moving aarch64 off `ubuntu-latest` gains nothing.

## Caching

* The action already caches the OpenBSD VM image, and `cache-after-prepare:
  true` caches the image after `pkg_add`.
* `make`/ctest `-D Continuous` cannot do incremental builds in CI: each run
  is a fresh checkout in a fresh VM.  ccache is used instead (content-hash
  based), restored before the VM step and saved with `if: always()`.
* `copyback: true` brings `.ccache` back out of the VM; `build/` is deleted
  first so the copy stays small.
* The VM runs the `run:` script under `sh -e`, so a failing ctest aborted the
  script before copyback and no ccache was ever saved.  ctest's exit code is
  now captured with `|| rc=$?`, written to `ctest.rc`, and checked in a final
  step so test failures still fail the job.
* ccache only helps the compile.  Configure and the tests run every time.

## Running locally with act

Host: LXC container on Proxmox, 4 vCPUs, 8 GB RAM, no `/dev/kvm`.  Disk is
not a concern (roughly 5-8 GB per architecture); RAM is: the action gives each
VM 6 GB by default, so only one VM fits at a time.

act runs the workflow in Docker, so no sudo is needed (membership in the
`docker` group is enough).  `vmactions/openbsd-vm` assumes a GitHub-hosted
runner, and needed these workarounds:

| Problem | Symptom | Workaround |
|---------|---------|------------|
| `catthehacker/ubuntu:act-latest` has no rsync | `Unable to locate executable file: rsync` | `apt-get install rsync` in a step before the VM step |
| Action syncs `$HOME/work`; act's workspace is not under `/root/work` | `rsync: change_dir "/root/work" failed` (code 23) | Put the repo at `<dir>/work/actions/actions` and set `HOME: <dir>` on the VM step |
| ssh reads `/root/.ssh`, not `$HOME/.ssh` | `Could not resolve hostname openbsd` | `ln -sfn /root/.ssh <dir>/.ssh` |
| Container PID 1 does not reap children | QEMU left `<defunct>`; stuck at "Waiting for QEMU to exit" after the prepare restart | `--container-options "--privileged --init"` |
| OpenBSD clears `/tmp` at boot | Workspace gone after the prepare restart (`cd: ... No such file or directory`) | Keep `<dir>` outside `/tmp`, e.g. `~/.cache/act-obsd-run` |

Command used:

```sh
act push -C ~/.cache/act-obsd-run/work/actions/actions \
  -W .github/workflows/obsd-8.0_matrix.yml -j test --matrix arch:x86_64 \
  -P ubuntu-latest=catthehacker/ubuntu:act-latest \
  --container-options "--privileged --init"
```

act does not enforce `timeout-minutes`, so it can run sparc64 to completion.

Local x86_64 under TCG (old workflow: serial ctest, 1200 s timeout):

| Stage | Time |
|-------|------|
| cmake configure | 651 s |
| build (0 errors, 102 warnings) | ~3h25m |
| ctest | 3h07m, 2819/2821 passed (`testhdf5-select`, `cache_image` timed out) |
| whole VM step | 6h51m |

The slowest passing tests were `dsets` (1141 s), `vds` (912 s),
`set_extent` (740 s) and `objcopy` (724 s).
