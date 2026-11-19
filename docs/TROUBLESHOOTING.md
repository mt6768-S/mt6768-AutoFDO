# Troubleshooting

Symptom-first. If a section does not cover your case, start by proving the basics:

```sh
# device
adb shell 'uname -a; cat /proc/cmdline; ls /sys/bus/event_source/devices/'

# host
clang --version; ld.lld --version; create_llvm_prof --version
sha256sum out/arch/arm64/boot/vmlinux profiles/devices/*/vmlinux-training
```

The two most common root causes for everything below are (a) the training
kernel is not the kernel that produced `vmlinux-training`, and (b) SPE was never
available in the first place.

---

## `arm_spe_0` is missing

`ls /sys/bus/event_source/devices/` has no `arm_spe_0`.

> **Not evidence:** `simpleperf list` printing only `armv8_pmuv3` events. SPE
> exposes `format/` but no `events/`, so simpleperf cannot list it even when it
> is registered. Also check on the **training** kernel — a production build
> (`CONFIG_AUTOFDO_CLANG_PROFILER_ARM64_SPE=n`) never registers the PMU.
> Full bring-up checklist: [`SPE-BRINGUP.md`](SPE-BRINGUP.md).

Check in this order:

1. **Config is really on.** The Kconfig `select`s are not enough if the symbol
   was dropped:

   ```sh
   adb shell 'zcat /proc/config.gz | grep -E "ARM_SPE_PMU|AUTOFDO|PID_IN_CONTEXTIDR"'
   # or, from the build:
   grep -E "ARM_SPE_PMU|AUTOFDO_CLANG_PROFILER" out/.config
   ```

   `CONFIG_ARM_SPE_PMU` must be `y` (not `m`; there is no module load on a
   boot image).

2. **Driver probe errors.**

   ```sh
   adb shell 'dmesg | grep -i -A3 "spe"'
   ```

   | Message | Meaning |
   |---|---|
   | `failed to get IRQ` | DT node exists but `interrupts` is missing/wrong |
   | `expected PPI but got SPI` | SPE needs a per-CPU PPI, not an SPI |
   | `profiling buffer inaccessible. Try passing "kpti=off"` | KPTI is on → `CONFIG_AUTOFDO_CLANG_PROFILER_ARM64_SPE` not applied, or cmdline override |
   | no `arm_spe` lines at all | **no DT node** → driver never probes (see 3) |
   | `no SPE support` / probe `-ENODEV` | CPU/firmware does not expose SPE |

3. **DT node.** This tree's MT6768 DTs have no SPE node. The driver matches
   `arm,statistical-profiling-extension-v1` and requires a per-CPU PPI:

   ```dts
   spe-pmu {
           compatible = "arm,statistical-profiling-extension-v1";
           interrupts = <GIC_PPI N IRQ_TYPE_LEVEL_HIGH>;  /* N is SoC-specific */
   };
   ```

   `N` must come from the SoC/GIC documentation — a wrong PPI either fails to
   register or steals another CPU interrupt. This is board bring-up work, not a
   config tweak.

4. **Hardware.** SPE is optional in ARMv8.2. Confirm the part actually
   implements it (PMSVer field of `ID_AA64DFR0_EL1`, or the core TRM) before
   chasing software.

If SPE is genuinely unavailable, this pipeline has no sampler. AutoFDO needs
branch samples; there is no instrumentation fallback in this tree.

---

## `perf record` fails on `arm_spe_0/...`

| Error | Fix |
|---|---|
| `event syntax error` / `unknown PMU` | `arm_spe_0` missing (above), or `perf` too old for the event format |
| `Permission denied` | run as root (`adb root` / `su`), or lower `kernel.perf_event_paranoid` |
| `No such file or directory` on `-o` path | `/data/local/tmp` not writable from your shell context |
| `failed to set aux buffer` / truncated data | close other perf users, raise `-m` if supported, reduce duration |
| File is a few KB, `perf report` shows nothing | `kpti=off` missing, or the event never armed |

Quick check that the event exists at all:

```sh
adb shell 'perf list | grep -i spe'
adb shell 'cat /sys/bus/event_source/devices/arm_spe_0/type'
```

`branch_filter=1` only selects branch records; if you omit it the file grows
quickly and contains load/store/latency records the branch profile ignores.

---

## `kpti=off` is not on the command line

`CONFIG_AUTOFDO_CLANG_PROFILER_ARM64_SPE` appends it in `setup_arch()` **unless**
the cmdline already contains `kpti=`. So:

- the symbol is not actually enabled → check `out/.config`;
- your bootloader passes `kpti=on` explicitly → remove it from the boot args
  (`CONFIG_CMDLINE` / `CONFIG_CMDLINE_EXTEND` / vendor `bootargs`);
- you flashed a different image than you built (`uname -a`, build timestamp).

Setting `kpti=off` by hand is also fine for a training boot, but it must go into
the boot image's cmdline (AnyKernel3 `cmdline=` field, `boot.img` header, or
`CONFIG_CMDLINE` with `CONFIG_CMDLINE_EXTEND`). There is no runtime toggle on
arm64; `arch/arm64` decides once at boot, and `arm_spe_pmu` checks it at probe
time.

---

## The profile is empty or has almost no functions

`llvm-profdata show --all-functions x.afdo` lists a handful of entries, or
`create_llvm_prof` prints a very low matched-sample count.

Check:

1. **Right binary.** `--binary` must be the `vmlinux` from the *training* build
   (same `.config`, same commit). Compare against the archived copy:

   ```sh
   sha256sum profiles/devices/<device>/vmlinux-training out/arch/arm64/boot/vmlinux
   ```

2. **Not stripped.** `file vmlinux`, `llvm-nm vmlinux | wc -l` — if symbols are
   gone, no amount of flags helps. Rebuild; do not run `strip` on `vmlinux`.

3. **Real samples.** On the host:

   ```sh
   perf report --stdio -i perf-game.data | head -30
   ```

   Mostly `[unknown]` there ⇒ the perf file has no usable addresses/PID; mostly
   `[kernel.kallsyms]`/symbols ⇒ conversion should work.

4. **Source drift.** If the training kernel was rebuilt after collection (new
   `vmlinux` hash), line tables moved and most samples drop. Re-collect.

5. **Wrong profiler mode.** SPE data needs `--profiler=perf_spe`; the default
   (LBR/perf) parser will silently match very little.

6. **Hot code is in modules.** There are none on this device for the paths you
   care about, but if the sampled code is in a module, that module's binary is
   needed too.

Try one session alone (game only) before merging; a bad input file can poison
the merge statistics.

---

## `create_llvm_prof` errors

| Message | Cause |
|---|---|
| `Couldn't read profile` | truncated/`perf.data` from a different format, or file still being written |
| `Binary is not a valid ELF` | passed `Image.gz-dtb` instead of `vmlinux` |
| `Unknown profiler` | autofdo too old for `perf_spe` (need ≥ v0.20) |
| `No samples matched` | see previous section |
| crash / assert on huge files | split the session, convert per file, merge `.afdo` afterwards |

Use `--format=extbinary`; it is what the kernel Makefile expects and it
compresses much better than text.

---

## Build failures

### `selects non-existing symbol PID_IN_CONTEXTIDR`

Expected on this 4.19 tree. Kconfig prints a warning and continues; the SPE
driver works, but samples carry no PID, so `perf record -p <pid>` is not usable.
Either ignore it and profile system-wide, or backport
`CONFIG_PID_IN_CONTEXTIDR` (writes the PID into `CONTEXTIDR_EL1` on context
switch) and re-enable it.

### `--lto-sample-profile` / `-fprofile-sample-use` unknown

Toolchain too old. AutoFDO needs **LLVM 17+**, and the flags are ignored by
older Clangs (or rejected by older LLDs). Verify the compiler actually invoked
by the build:

```sh
make O=out ... V=1 2>&1 | grep -m1 "clang"
```

`build.env`'s `CLANG_SOURCE` is a moving release; check its `clang --version`
and keep that exact toolchain for both builds.

### ThinLTO link is killed (OOM)

Expected on 4.19 with LTO. Reduce jobs (`-j4`), close other builds, ensure
≥16 GiB RAM and swap. This is one reason the training build is non-LTO.

### Training build with `CONFIG_LTO_CLANG=n` still links slowly / fails

`CONFIG_THINLTO` depends on `CONFIG_LTO_CLANG`; if you only set `THINLTO=n` but
left LTO on, you get full `-flto` by default. Set both explicitly.

### Profile build produces a kernel that bootloops

- Profile built from a different commit/config than the source being compiled.
- CFI (or shadow call stack) enabled in one build and not the other; keep them
  identical.
- Propeller enabled with a stale/mismatched prefix → basic-block layout points
  at the wrong locations.

Bisect by building AutoFDO-only first, then adding Propeller.

---

## The optimized kernel is not faster

Profile quality, not compiler magic, drives the result:

- Training workload does not resemble the target workload (benchmarks ≠ UI).
- Sessions too short (`< 10 min`) or dominated by idle/thermal throttling.
- Mixed profiles where one session contributed almost all samples.
- Hot functions are called from modules or firmware paths not covered.
- Profile applied to an unrelated kernel version → relative line numbers drift,
  matches fall off silently.

Compare with `perf stat` and `llvm-profdata show` coverage, not with feelings.
