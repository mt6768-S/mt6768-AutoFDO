# MT6768 AutoFDO Kernel Builder

Profile-guided optimization (AutoFDO + Propeller) for
**MT6768** Android kernels.

> **Status: experimental.** The workflow and documentation are in place; the
> collection wrappers in `collector/` are still placeholders. Read
> [`docs/DESIGN.md`](docs/DESIGN.md) before building anything — the profiling
> kernel and the production kernel are deliberately *not* configured the same
> way.

AutoFDO is **sample-based**, not instrumented. A training kernel is built with
line-table debug info (`-gmlt`), a representative workload is sampled with
`perf` + ARM SPE, the samples are converted into a `.afdo` profile on the host,
and that profile is fed back into the compiler for the production build.

```
  profiling kernel              on-device training              profile                production kernel
  ─────────────────             ───────────────────            ─────────                ─────────────────
  CONFIG_LTO_CLANG=n     boot ─┐
  CONFIG_AUTOFDO_CLANG=y game ─┼─> perf record · ARM SPE ─> create_llvm_prof ─> CONFIG_LTO_CLANG=y
  no .afdo profile       daily─┘        (branch_filter)          (*.afdo)          CONFIG_THINLTO=y
  CONFIG_..._ARM64_SPE=y                                                             CONFIG_AUTOFDO_CLANG=y
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
| `CONFIG_AUTOFDO_CLANG_PROFILER_ARM64_SPE` | `y` | **`n`** |
| ARM SPE hints (`kpti=off`) | yes (automatic) | no |

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
# Build the training kernel. It enables SPE and disables LTO.
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
        CONFIG_AUTOFDO_CLANG=y CONFIG_AUTOFDO_CLANG_PROFILER_ARM64_SPE=y
make O=out ARCH=arm64 -j"$(nproc)" LLVM=1 LLVM_IAS=1 \
        CROSS_COMPILE=aarch64-linux-gnu- \
        CROSS_COMPILE_ARM32=arm-linux-gnueabi-
```

```sh
# 3) Convert samples into an AutoFDO profile
create_llvm_prof --binary=out/arch/arm64/boot/vmlinux \
                 --profile=perf-game.data \
                 --profiler=perf_spe --format=extbinary \
                 --out=profiles/devices/selene/mt6768-game.afdo
```

```sh
# 4) Build the production kernel
python3 helpers/cc.py CONFIG_LTO_CLANG=y CONFIG_THINLTO=y \
        CONFIG_AUTOFDO_CLANG=y CONFIG_AUTOFDO_CLANG_PROFILER_ARM64_SPE=n
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
| `prepare` | Resolves the pinned kernel commit and hashes `build.env`, `build.sh`, the SPE patch and the commit into the profiler cache key. |
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
patches/                   SPE device-tree node (training stage only)
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
| [`docs/SPE-BRINGUP.md`](docs/SPE-BRINGUP.md) | **Read this first if `arm_spe_0` is missing** — DT node, PPI, hardware check |
| [`docs/DESIGN.md`](docs/DESIGN.md) | Two-build model, config matrix, profile compatibility rules, known gaps |
| [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) | Symptom → cause → fix |
| [`profiles/README.md`](profiles/README.md) | Profile naming, provenance and retention rules |

## Supported devices

Device directories follow the kernel tree's codenames:

- `merlin`
- `lancelot`
- `selene`

A profile is portable between MT6768 devices *if* it was collected on the same
kernel commit with the same Clang. Per-device directories exist mostly to keep
provenance clear, not because the profile is device-locked.

## Known limitations

- **SPE availability is unverified and currently the project's blocker.** Neither
  the vendor DT nor the LineageOS/mainline MT6768 DTs have an SPE node. No
  ready-made patch exists — but no driver or PID backport is needed either:
  `arm_spe_pmu` and `CONFIG_PID_IN_CONTEXTIDR` are already in this 4.19 tree, so
  the missing piece is a 4-line DT node, carried by
  `patches/0001-arm64-dts-mt6768-add-arm-spe-node.patch`. `simpleperf list`
  showing only `armv8_pmuv3` proves nothing (the SPE PMU has no `events/`
  entries); the only valid test is `arm_spe_0` in
  `/sys/bus/event_source/devices/` on a training kernel. See
  [`docs/SPE-BRINGUP.md`](docs/SPE-BRINGUP.md).
- `collector/*.sh` are empty. Until they land, use the raw `perf` commands from
  [`docs/INSTRUCTIONS.md`](docs/INSTRUCTIONS.md).
- Propeller needs Clang/LLD 19+ and a second profiling round; treat it as a
  separate experiment on top of a working AutoFDO build.
- Profiles are workload-specific. A profile trained on benchmarks and applied
  to UI workloads will optimize the wrong thing.
