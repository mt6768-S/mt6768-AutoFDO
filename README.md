# mt6768 AutoFDO

Profile-guided optimization (AutoFDO, optionally + Propeller) for MediaTek
**MT6768 / Helio G80–G85** Android kernels.

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
# 2) Flash it, boot it, confirm SPE is live, then collect
adb shell 'cat /proc/cmdline'                 # must contain kpti=off
adb shell 'ls /sys/bus/event_source/devices/' # must list arm_spe_0
adb shell '/data/local/tmp/perf record -e arm_spe_0/branch_filter=1/ -a -N -c 500009 \
           -o /data/local/tmp/perf-game.data -- sleep 1800'
adb pull /data/local/tmp/perf-game.data
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

`kpti=off` is only honoured by the training kernel — never ship a production
build with `CONFIG_AUTOFDO_CLANG_PROFILER_ARM64_SPE=y`.

## Repository layout

```
build.env                  kernel source, toolchain and packaging defaults
collector/                 on-device workload wrappers (boot / game / daily) — WIP
helpers/cc.py              tiny .config editor used by the build steps
profiles/                  collected profiles, one directory per device
  common/                  device-independent profiles
  devices/{merlin,lancelot,selene}/
docs/                      design notes, step-by-step guide, troubleshooting
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
  the vendor DT nor the LineageOS/mainline MT6768 DTs have an SPE node, and the
  tree lacks `CONFIG_PID_IN_CONTEXTIDR`. No ready-made patch exists — but no
  driver backport is needed either: `arm_spe_pmu` is already in this 4.19 tree,
  so the missing piece is a 4-line DT node. `simpleperf list` showing only
  `armv8_pmuv3` proves nothing (the SPE PMU has no `events/` entries); the only
  valid test is `arm_spe_0` in `/sys/bus/event_source/devices/` on a training
  kernel. See [`docs/SPE-BRINGUP.md`](docs/SPE-BRINGUP.md).
- `collector/*.sh` are empty. Until they land, use the raw `perf` commands from
  [`docs/INSTRUCTIONS.md`](docs/INSTRUCTIONS.md).
- Propeller needs Clang/LLD 19+ and a second profiling round; treat it as a
  separate experiment on top of a working AutoFDO build.
- Profiles are workload-specific. A profile trained on benchmarks and applied
  to UI workloads will optimize the wrong thing.

