# MT6768 AutoFDO Kernel Builder

Profile-guided optimization (AutoFDO + Propeller) for **MT6768** Android kernels.

> **Status: experimental.** The workflow and documentation are in place; the
> collection wrappers in `collector/` are still placeholders. Read
> [`docs/DESIGN.md`](docs/DESIGN.md) before building anything — the profiling
> kernel and the production kernel are deliberately *not* configured the same
> way.

AutoFDO is **sample-based**, not instrumented. A training kernel is built with
line-table debug info (`-gmlt`), a representative workload is sampled with
`perf`, the samples are converted into a `.afdo` profile on the host, and that
profile is fed back into the compiler for the production build.

```
  profiling kernel              on-device training              profile                production kernel
  ─────────────────             ───────────────────            ─────────                ─────────────────
  CONFIG_LTO_CLANG=n     boot ─┐
  no .afdo profile       daily─┘        (branch_filter)          (*.afdo)          CONFIG_THINLTO=y
  (+ kpti=off)                                                                       CLANG_AUTOFDO_PROFILE=...
                                                                                     (+ CONFIG_PROPELLER_CLANG=y)
```

## Why two kernels?

| | Profiling kernel | Production kernel |
|---|---|---|
| `CONFIG_AUTOFDO_CLANG` | `y` (emit `-gmlt`) | `y` (consume profile) |
| `CLANG_AUTOFDO_PROFILE` | unset | `.../mt6768.afdo` |
| `CONFIG_LTO_CLANG` / `CONFIG_THINLTO` | `n` / `n` | `y` / `y` |
| `CONFIG_PROPELLER_CLANG` | `n` | optional |

Disabling LTO for the training build keeps the build fast and the binary easy to
match against samples; the resulting profile is still valid input for a ThinLTO
build. What must **not** drift between the two builds: kernel source commit,
Clang version, optimization level, target CPU, and the codegen-relevant configs
(CFI, shadow call stack, KASAN, …).

Details and the full compatibility list: [`docs/DESIGN.md`](docs/DESIGN.md).

## Quick start

The supported entry point is `build.sh`. It clones the pinned kernel source,
applies the profiler device-tree patch when needed, installs KernelSU and
NoMount from the setup URLs in `build.env`, generates the configuration, builds
the kernel, and creates an AnyKernel3 zip.

```sh
./build.sh --stage profiler --device selene

# Build the optimized kernel from an AFDO profile.
./build.sh --stage optimized --device selene \
  --profile profiles/devices/selene/mt6768-game.afdo
```


```sh
# 0) Host requirements
clang --version                     # >= 17 for AutoFDO, >= 19 for Propeller
create_llvm_prof --version          # google/autofdo >= v0.30.1
```

```sh
# 1) Build the profiling kernel
make O=out ARCH=arm64 vendor/mt6768_defconfig
python3 helpers/cc.py CONFIG_LTO_CLANG=n CONFIG_THINLTO=n \
make O=out ARCH=arm64 -j"$(nproc)" LLVM=1 LLVM_IAS=1 \
        CROSS_COMPILE=aarch64-linux-gnu- \
        CROSS_COMPILE_ARM32=arm-linux-gnueabi-
```

```sh
# 3) Convert samples into an AutoFDO profile
create_llvm_prof --binary=out/arch/arm64/boot/vmlinux \
                 --profile=perf-game.data \
                 --out=profiles/devices/selene/mt6768-game.afdo
```

```sh
# 4) Build the production kernel
python3 helpers/cc.py CONFIG_LTO_CLANG=y CONFIG_THINLTO=y \
make O=out ARCH=arm64 -j"$(nproc)" LLVM=1 LLVM_IAS=1 \
        CROSS_COMPILE=aarch64-linux-gnu- \
        CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
        CLANG_AUTOFDO_PROFILE="$PWD/profiles/devices/selene/mt6768-game.afdo"
```

## CI workflow

`.github/workflows/build-kernel.yml` runs the whole pipeline on GitHub Actions:

```
generate-build-matrix ──> prepare ──┬──> profiler (matrix, cached) ──┐
                                    └──> optimized (matrix) ─────────┴──> release
```

`profiler` and `optimized` are **independent jobs and start together**; nothing
waits for the training kernel to finish compiling. Only `release` joins them.

| Job | What it does |
|---|---|
| `profiler` | Builds the training kernel (SPE, LTO off) once per device, packages `*-profiler-*.zip`, stores `vmlinux` + `Image.gz-dtb` + provenance in the cache. **Skipped entirely when the cache key hits.** |
| `optimized` | Per device: resolves a profile, builds with ThinLTO + AutoFDO, packages `*-autofdo-*.zip`. |
| `release` | Publishes every zip plus `SHA256SUMS`. |

Device list lives in `build.env` (`DEVICES=merlin lancelot selene`); there are no
workflow inputs — a manual run always builds every listed device. Root solution
and toolchain are also `build.env` settings, with no per-variant config files.

Profile resolution for the optimized stage, in order:

1. `profiles/devices/<device>/*.afdo` (or `profiles/common/*.afdo`) — used as-is.
2. `profiles/devices/<device>/perf-*.data` — converted in CI with
   `create_llvm_prof` against the **cached profiler `vmlinux`**, so the profile
   is guaranteed to match the training build. Because the profiler runs in
   parallel, a *brand-new* profiler build is not in the cache yet: the
   conversion is then skipped with a warning, and the next run picks it up.
3. Neither → the run publishes the profiler kernel only and warns in the
   summary. It never guesses.

The profiler build uses the same KernelSU/NoMount settings as the production
build by default. Keeping the integration configuration identical makes the
training and production binaries comparable. Disable the integrations in
`build.env` if a clean profiling kernel is specifically required. The cache key
covers everything that can alter the profiler output, so a profile remains
usable only while the kernel commit, toolchain, configuration, and workload
assumptions remain compatible.

Artifacts are per run and kept for 30 days; releases are tagged
`kernel-r<run_number>`.

## Repository layout

```
build.env                  kernel source, device list, toolchain, root solution, packaging
build.sh                   the two-stage builder (--stage profiler|optimized)
collector/                 on-device workload wrappers (boot / game / daily) — WIP
helpers/cc.py              tiny .config editor used by the build steps
profiles/                  collected profiles, one directory per device
  common/                  device-independent profiles
  devices/{merlin,lancelot,selene}/
docs/                      design notes, step-by-step guide, troubleshooting
.github/workflows/         the CI pipeline described above
```

## Documentation

| Document | Contents |
|---|---|
| [`docs/INSTRUCTIONS.md`](docs/INSTRUCTIONS.md) | End-to-end workflow: patch stack, configs, collection, conversion, validation |
| [`docs/DESIGN.md`](docs/DESIGN.md) | Two-build model, config matrix, profile compatibility rules, known gaps |
| [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) | Symptom → cause → fix |
| [`profiles/README.md`](profiles/README.md) | Profile naming, provenance and retention rules |

## Collecting PMU profiles

The collector scripts use `cpu-cycles:k` by default, which is the recommended
first AutoFDO event on MT6768. Boot, game, and daily collection have different
lifecycles: boot uses `simpleperf boot-record`, game waits for a package and
records for five minutes, and daily records 96 fifteen-minute samples.

```sh
./collector/collect-game.sh com.example.game
```

If an Android device is connected, the script runs `simpleperf` through `adb`
and pulls the result into `profiles/devices/selene/`. Set `ADB_SERIAL` when
more than one device is connected:

```sh
ADB_SERIAL=ABC123 ./collector/collect-game.sh
```

When `adb` is available, the host wrappers enable/run collection through adb
and pull the completed files. They are not intended to remain connected for a
24-hour run. When `adb` is unavailable, use the Android/Termux scripts in
`collector/device/`; they run manually as root and write directly to
`/storage/emulated/0/profiles/`. Boot is manually enabled or disabled with
`collector/device/boot.sh enable|disable`.

`PERF_EVENT` can override the event, and `PERF_INTERVAL` controls the sampling
 frequency (`-f`). The game and daily ADB wrappers use it for every recording;
 boot uses it when scheduling the next boot. For example:

```sh
PERF_EVENT=instructions ./collector/collect-game.sh com.example.game 60
PERF_EVENT=branch-instructions ./collector/collect-daily.sh
```

The event names supported by the scripts include `branch-instructions`,
`bus-cycles`, `cpu-cycles`, `instructions`, `stalled-cycles-backend`,
`stalled-cycles-frontend`, `arm_dsu_0/bus_cycles/`, `arm_dsu_0/cycles/`,
`armv8_pmuv3/bus_cycles/`, `armv8_pmuv3/cpu_cycles/`,
`armv8_pmuv3/inst_spec/`, and the `raw-*` events documented in
`collector/common.sh`. Raw stall and ZA events may only work on CPUs 6–7;
start with `cpu-cycles` and validate alternatives using `simpleperf stat`.

## Supported devices

Device directories follow the kernel tree's codenames:

- `merlin`
- `lancelot`
- `selene`

A profile is portable between MT6768 devices *if* it was collected on the same
kernel commit with the same Clang. Per-device directories exist mostly to keep
provenance clear, not because the profile is device-locked.

## Known limitations

- `collector/*.sh` are empty. Until they land, use the raw `perf` commands from
  [`docs/INSTRUCTIONS.md`](docs/INSTRUCTIONS.md).
- Propeller needs Clang/LLD 19+ and a second profiling round; treat it as a
  separate experiment on top of a working AutoFDO build.
- Profiles are workload-specific. A profile trained on benchmarks and applied
  to UI workloads will optimize the wrong thing.
