# SPE bring-up on MT6768 (4.19)

**Status: blocked pending hardware verification.** No MT6768 device tree in this
tree (vendor or mainline) exposes SPE, and nobody has confirmed that the
Cortex-A75/A55 configuration in Helio G80/G85 implements it. Until `arm_spe_0`
shows up in `/sys/bus/event_source/devices/`, this project has no sampler and
therefore no AutoFDO profile.

This document is the bring-up checklist, not a finished procedure. Every step
has a clear pass/fail so you stop early instead of collecting garbage.

---

## Prior art (checked 2026-11)

| Place | Result |
|---|---|
| `mt6768-S/android_kernel_xiaomi_mt6768` (vendor, this project) | no SPE node |
| `mt6768-mainline/linux` (mainline port) | no SPE node |
| GitHub issues/repos: `mt6768 spe`, `arm_spe mt6768`, `autofdo mt6768` | 0 results |

**Conclusion: there is no ready-made MT6768 SPE/AutoFDO patch to import.**

The good news is that none is needed:

- `drivers/perf/arm_spe_pmu.c` and `CONFIG_ARM_SPE_PMU` already exist in the
  4.19 tree (ARM SPE landed upstream in 4.14/4.19). **No driver backport.**
- The DT node is 4 lines (Step 1), already carried by
  `patches/0001-arm64-dts-mt6768-add-arm-spe-node.patch`.
- `CONFIG_PID_IN_CONTEXTIDR` also exists (`arch/arm64/Kconfig.debug`) and the
  helper Kconfig selects it. **No PID backport either.**
- `CONFIG_AUTOFDO_CLANG` + the arm64/SPE helper are already carried by this
  tree (see `INSTRUCTIONS.md#patch-stack`).

So the "backport" fear does not apply here: the only edit is a device-tree
node, and it is reversible in one line.

## What we actually know

| Fact | Source |
|---|---|
| Vendor DT (`mt6768.dts` @ `912d9488`) has **no** SPE node | grep for `statistical-profiling` → 0 hits |
| Mainline-ish DT (`mt6768-mainline/linux`) has **no** SPE node either | same grep → 0 hits |
| The SoC uses GICv3, label `gic`; PPIs in use: 7 (PMUv3), 9, 10, 11, 13, 14 | `mt6768.dts` |
| PPI 5 is free in that map | same |
| ARM reference DTS (`fvp-base-revc.dts`) uses `GIC_PPI 5` for SPE | upstream DTS |
| The 4.19 driver requires a **per-CPU PPI** and rejects SPIs | `arm_spe_pmu_irq_probe()` |
| The driver refuses to probe when KPTI is on (`-EPERM`) | `arm_spe_pmu_device_dt_probe()` |
| SPE presence is reported by `ID_AA64DFR0_EL1.PMSVer`; 0 means absent | `__arm_spe_pmu_dev_probe()` |

> **`simpleperf list` is not a test.** It enumerates *events* under
> `/sys/bus/event_source/devices/*/events/`. The SPE PMU has `format/` entries
> but no `events/`, so it is invisible to `simpleperf list` even when it is
> registered and working. Seeing only `armv8_pmuv3` proves nothing.
>
> Also: `armv8_pmuv3` counters are useless for AutoFDO. AutoFDO needs branch
> edges/samples, and Cortex-A75 has no BRBE. Don't try to substitute PMUv3
> `br-*` events for SPE.

The only valid tests are:

```sh
ls /sys/bus/event_source/devices/            # arm_spe_0 present?
zcat /proc/config.gz | grep -E "ARM_SPE|AUTOFDO"   # IKCONFIG builds only
dmesg | grep -i spe                           # driver messages
grep -i spe /proc/interrupts                  # per-CPU PPI counters
```

...and those only work on a kernel built with `CONFIG_ARM_SPE_PMU=y`, i.e. the
**training** kernel. A production/AutoFDO-LTO boot will never show SPE.

---

## Step 1 — Prove the hardware implements SPE

This costs one build and answers the whole question.

The patch is already in the repository and `build.sh --stage profiler` applies
it automatically. It adds this node next to the existing `arm,armv8-pmuv3` node
in `arch/arm64/boot/dts/mediatek/mt6768.dts`:

```dts
spe-pmu {
        compatible = "arm,statistical-profiling-extension-v1";
        interrupt-parent = <&gic>;
        interrupts = <GIC_PPI 5 IRQ_TYPE_LEVEL_HIGH>;
};
```

Build the training kernel (`CONFIG_ARM_SPE_PMU=y`) and boot. Then:

```sh
adb shell 'dmesg | grep -i spe'
```

| Output | Meaning |
|---|---|
| `unsupported ID_AA64DFR0_EL1.PMSVer [0] on CPU 0` | **Hardware/firmware does not implement SPE. Stop here.** |
| `probed` / `arm_spe_0` in sysfs | SPE exists. Continue. |
| `failed to get IRQ`, `expected PPI but got SPI` | Node/PPI is wrong — try the next PPI |
| `profiling buffer inaccessible` | `kpti=off` not applied |
| nothing at all | Node not visible to the driver (wrong parent node, `status = "disabled"`, or DT not rebuilt) |

PPI 5 is the reference-design convention and is free in MT6768's PPI map, but
the SPE interrupt line is **implementation defined**. If probe fails or the
interrupt never fires, the number is wrong — the SoC's interrupt map (MTK
TRM / `mt6768-mainline` community) is the only authoritative source. Do not
brute-force PPI numbers on a live device: several PPIs are timers and PMU.

## Step 2 — PID attribution (already wired)

`CONFIG_PID_IN_CONTEXTIDR` **exists in this tree** — it is defined in
`arch/arm64/Kconfig.debug`, implemented by `contextidr_thread_switch()` in
`arch/arm64/include/asm/mmu_context.h`, and already called from `__switch_to()`
in `arch/arm64/kernel/process.c`.

`CONFIG_AUTOFDO_CLANG_PROFILER_ARM64_SPE=y` selects it, and `build.sh` also
sets it explicitly for the profiler stage, so SPE records carry a PID and
`perf record -p <pid>` works.

Keep it **off** in production (it writes a sysreg on every context switch);
`build.sh` asserts that it is disabled in the optimized stage and enabled in
the profiler stage.

## Step 3 — Verify the sampler end to end

```sh
adb shell 'ls /sys/bus/event_source/devices/arm_spe_0/format/'
adb shell 'perf list | grep -i arm_spe'
adb shell 'perf record -e arm_spe_0/branch_filter=1/ -a -N -c 500009 \
           -o /data/local/tmp/perf-test.data -- sleep 10'
adb shell 'perf report --stdio -i /data/local/tmp/perf-test.data | head'
```

Pass criteria: `arm_spe_0` in sysfs, a non-trivial `perf-test.data`, and kernel
symbols (not `[unknown]`) in the report.

Use **`perf`**, not `simpleperf`. `create_llvm_prof --profiler=perf_spe`
expects perf's AUX/SPE file format; simpleperf's record format is its own.

---

## If PMSV is 0

Then this SoC has no SPE and the sample-based path is dead on MT6768. Be honest
about the consequences:

| Alternative | Verdict |
|---|---|
| iFDO / `-fprofile-generate` | Not supported by this 4.19 AutoFDO stack; counters in kernel are invasive |
| ETM / CoreSight trace | MT6768 phones expose no trace sink; not usable |
| BRBE | Not present on Cortex-A75 (Armv8.2) |
| Train on another device | Profile must come from the same kernel commit → not portable to a different SoC kernel |
| PMUv3 sampling (`-e cycles`) | Produces call stacks, not branch edges; `create_llvm_prof` cannot use it |
| Switch target to an SPE-capable device | The only path that keeps AutoFDO viable |

Do not start building the production/LTO half of the pipeline before Step 1
passes. A `.afdo` is required by that build; there is nothing to tune without
samples.

---

## Where to ask

- `mt6768-mainline` (GitHub org) — mainline port, closest thing to public
  MT6768 SoC documentation.
- MediaTek MT6768 interrupt map / TRM — the SPE PPI number lives there.
- Upstream `linux-arm-kernel` — if the PPI is discoverable, someone there will
  know the reference wiring.
