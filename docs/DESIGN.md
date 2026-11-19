# Design notes

Why this project builds the kernel twice, what may differ between the two
builds, and where the current implementation is still incomplete.

## 1. Two builds, one source tree

```
┌───────────────────────────────┐        ┌───────────────────────────────┐
│ TRAINING                      │        │ PRODUCTION                    │
│                               │        │                               │
│ CONFIG_AUTOFDO_CLANG=y        │        │ CONFIG_AUTOFDO_CLANG=y        │
│ CLANG_AUTOFDO_PROFILE unset   │        │ CLANG_AUTOFDO_PROFILE=x.afdo  │
│ CONFIG_LTO_CLANG=n            │        │ CONFIG_LTO_CLANG=y            │
│ CONFIG_THINLTO=n              │        │ CONFIG_THINLTO=y              │
│ ..._ARM64_SPE=y (kpti=off)    │        │ ..._ARM64_SPE=n               │
│ CONFIG_PROPELLER_CLANG=n      │        │ CONFIG_PROPELLER_CLANG=?      │
└──────────────┬────────────────┘        └──────────────▲────────────────┘
               │ boot + workloads                       │
               │ perf/SPE → perf-*.data                 │ .afdo
               └──────────► create_llvm_prof ───────────┘
```

`CONFIG_AUTOFDO_CLANG=y` is present in **both** builds and does different
things depending on whether `CLANG_AUTOFDO_PROFILE` is set:

| `CONFIG_AUTOFDO_CLANG` | `CLANG_AUTOFDO_PROFILE` | Compiler behaviour |
|---|---|---|
| `n` | — | plain build, no debug info unless `CONFIG_DEBUG_INFO` |
| `y` | unset | `-gmlt` only (plus FS-discriminator flags under LTO). Binary is *not* optimized differently; it exists to be sampled. This is the training build. |
| `y` | set | `-fprofile-sample-use=...`, `-ffunction-sections`, `-fsplit-machine-functions`; at link `--lto-sample-profile=...`. This is the production build. |

That is the whole trick: **training build = AutoFDO on, profile empty; production
build = AutoFDO on, profile present.** Turning AutoFDO off in the training build
would remove `-gmlt`, and without line tables `create_llvm_prof` cannot map
samples to source locations.

### Why LTO is off while training

- Build time and memory: ThinLTO on a 4.19 arm64 kernel is the slowest and most
  memory-hungry part of the pipeline. The training build needs many iterations.
- Symbol/debug fidelity: a non-LTO `vmlinux` has one symbol per function, in a
  layout that is straightforward to match against samples. Under LTO, functions
  are internalized, renamed (`foo.constprop.0`, `foo.llvm.1234`), split and
  inlined; the mapping still works, but it is noisier and more version
  sensitive.
- The profile itself is source-level (function + line offset + discriminator),
  not IR-level. It survives the transition to a ThinLTO production build.

The cost: hot/cold decisions are made on a non-LTO call graph, so inlining-driven
hot paths in the LTO build are approximated. That is an acceptable, documented
trade-off, not a bug.

## 2. Configuration reference

### Matrix

| Setting | Training | Production | Notes |
|---|---|---|---|
| `CONFIG_AUTOFDO_CLANG` | `y` | `y` | required by both |
| `CLANG_AUTOFDO_PROFILE` (make var) | unset | `*.afdo` | not a Kconfig symbol |
| `CONFIG_LTO_CLANG` | `n` | `y` | |
| `CONFIG_THINLTO` | `n` | `y` | `CONFIG_LTO_CLANG_THIN` on newer trees |
| `CONFIG_PROPELLER_CLANG` | `n` | optional | needs LLVM 19+ |
| `CONFIG_AUTOFDO_CLANG_PROFILER_ARM64_SPE` | `y` | **`n`** | forces `kpti=off` |
| `CONFIG_ARM_SPE_PMU` | `y` (selected) | any | sampler driver |
| `CONFIG_PID_IN_CONTEXTIDR` | `y` (selected) | `n` | writes PID to `CONTEXTIDR_EL1`; costs a sysreg write per switch |
| `CONFIG_CFI_CLANG` | `n` (forced) | `y` | `CFI_CLANG` depends on `LTO_CLANG`, so it cannot be on with LTO off |
| `CONFIG_SHADOW_CALL_STACK` | same | same | keep identical |
| `CONFIG_KASAN` / `KCOV` / lockdep | `n` | `n` | instrumentation distorts samples |
| `CONFIG_DEBUG_INFO` | `n` | `n` | `-gmlt` comes from AutoFDO |
| `CONFIG_KALLSYMS_ALL` | `y` | `y` | full symbol names |

### Names that do not exist

Common assumptions that will silently do nothing (kconfig lets you write
unknown symbols into `.config`; they are simply dropped on the next
`oldconfig`):

| Guess | Reality |
|---|---|
| `CONFIG_AUTOFDO_CLANG_PROFILE` | Not a symbol. Profiles are passed as `CLANG_AUTOFDO_PROFILE=<path>` to `make`. |
| `CONFIG_LTO_CLANG_THIN` | On this 4.19 tree the symbol is `CONFIG_THINLTO`; upstream renamed it later. |
| `CONFIG_AUTOFDO_CLANG_PROFILER_ARM64_SPE` | Exists (commit 6) and is the *only* "profiling mode" switch. It selects `ARM_SPE_PMU` and `PID_IN_CONTEXTIDR` and appends `kpti=off` in `setup_arch()`. |
| `-fprofile-generate`-style instrumentation | AutoFDO has no instrumentation pass in this pipeline. Sampling only. |

Use `grep -n "AUTOFDO\|PROPELLER" arch/Kconfig` in the target tree to see what
your source actually defines.

## 3. AutoFDO is sampling, not instrumentation

This distinction matters when planning work:

| | Instrumented FDO (iFDO/PGO) | AutoFDO |
|---|---|---|
| Data source | compiler-inserted counters | hardware sampling (SPE/LBR/BRBE) |
| Kernel support | invasive, huge overhead | none beyond `-gmlt` |
| Profile key | IR / counter IDs | function + line + discriminator |
| Sensitive to source changes | very | moderately tolerant |
| Sensitive to LTO | yes | mostly no |

So the kernel-side "profiler" here is the **SPE sampler** (`arm_spe_pmu`) plus
`perf`, not a compiler instrumentation mode. `CONFIG_AUTOFDO_CLANG_PROFILER_ARM64_SPE`
is misleadingly named: it only turns on the *enablers* (SPE PMU, PID in
contextidr, `kpti=off`).

## 4. Compatibility rules

The profile is consumed as relative source locations. To keep the compiler's
view of the code identical between the two builds:

**Must match**

- Kernel source commit (and the patch stack listed in `INSTRUCTIONS.md`).
- Clang version — ideally the exact same build; a different minor version
  reorders inlining and shifts discriminators.
- Optimization level (`CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE` ⇒ `-O2`), `-mcpu`,
  `-march`, `CONFIG_ARM64_ERRATUM_*` workarounds that change codegen.
- CFI / shadow-call-stack / stack-protector / `CONFIG_RANDOMIZE_BASE`
  settings.
- `vmlinux` used for conversion must be the training build, unstripped, with
  the same `.config` that produced the flashed image.

**May differ**

- `CONFIG_LTO_CLANG` / `CONFIG_THINLTO` (the whole point).
- `CLANG_AUTOFDO_PROFILE` itself, `CONFIG_PROPELLER_CLANG`.
- Debug info verbosity (`CONFIG_DEBUG_INFO`), as long as `-gmlt` is present.
- Kernel packaging (`Image.gz-dtb`, AnyKernel3 zip, …).

**Will invalidate the profile**

- Rebuilding the training kernel after the samples were taken.
- Stripping `vmlinux` (`llvm-strip`, `INSTALL_MOD_STRIP` does not touch
  `vmlinux`, but manual `strip` does).
- Switching toolchains, `-O3`, `-mcpu` tuning, or enabling KASAN between runs.
- Applying source changes that move code across lines/functions; small edits are
  tolerated, refactors are not.

## 5. Propeller

Propeller is a *second*, layout-only optimization stage on top of AutoFDO:

1. Build with `CONFIG_AUTOFDO_CLANG=y` + `CONFIG_PROPELLER_CLANG=y` and an
   existing `.afdo`, but no Propeller profile → labels mode
   (`-fbasic-block-sections=labels`), emitting `.llvm_bb_addr_map`.
2. Sample that kernel again (same SPE procedure).
3. `create_llvm_prof --format=propeller` → `<prefix>_cc_profile.txt` +
   `<prefix>_ld_profile.txt`.
4. Final build with both the `.afdo` and
   `CLANG_PROPELLER_PROFILE_PREFIX=<prefix>`.

Propeller only reorders basic blocks and symbols; it does not change the
instruction mix, so it cannot rescue a bad AutoFDO profile. Do it after the
AutoFDO-only build is validated. It also requires Clang/LLD 19+, a vmlinux
linker script that places `.llvm_bb_addr_map` (commit 7), and a `System.map`
that still contains the ordering markers.

## 6. Known gaps in this repository

1. **SPE plumbing: driver and PID tagging are already present; only the DT
   node is missing.** This is the project's current blocker.
   - `CONFIG_PID_IN_CONTEXTIDR` **does exist** (`arch/arm64/Kconfig.debug`),
     `contextidr_thread_switch()` is implemented and called. The helper Kconfig
     selects it; `build.sh` enables it in the profiler stage and asserts it is
     off in production. No backport needed.
   - The MT6768 device trees (vendor *and* `mt6768-mainline`) have no SPE node
     (`arm,statistical-profiling-extension-v1`), and the driver requires a
     per-CPU PPI. Without that node `arm_spe_0` never registers, so
     `perf record -e arm_spe_0//` fails. `build.sh` applies
     `patches/0001-arm64-dts-mt6768-add-arm-spe-node.patch` for the profiler
     stage only. The reference-design PPI is 5 and is unused in MT6768's PPI
     map, but the wiring is SoC-specific and unverified.
   - SPE presence per core (A75 vs A55) must be verified via
     `ID_AA64DFR0_EL1.PMSVer` — the feature is optional and firmware can hide it.
     Until that bit is non-zero, there is no sampler and no profile.
   - Practical checklist: [`SPE-BRINGUP.md`](SPE-BRINGUP.md).
2. **The training kernel is built without the root-solution patch stack.**
   KernelSU/NoMount only add functions and call-site hooks; AutoFDO weight is
   keyed by function name, so the hot paths that matter are unchanged. Do not
   expect samples for code that only exists in the production kernel.
3. **`collector/*.sh` are empty.** The documented raw `perf` commands are the
   source of truth until the wrappers exist. They should only shell out to
   exactly those commands (boot/daily/game), pull the files, and print sample
   counts.
3. **No merging policy yet.** `profiles/common/` is intended for profiles whose
   training data is not device-specific, but nothing generates one today.
4. **No automated validation.** `INSTRUCTIONS.md` step 6 is manual.
5. **Security footgun.** The training config disables KPTI and must never be
   shipped. The production step in this guide explicitly turns the SPE helper
   off — do not merge the two `.config` files.
6. **Profile portability is not tested across device variants** (merlin /
   lancelot / selene). Same SoC, same commit, same Clang ⇒ expected to work;
   different firmware or thermal behaviour ⇒ different training data.
