# AutoFDO workflow for MT6768

Step-by-step guide from a clean kernel tree to a profile-optimized kernel.
Read [`DESIGN.md`](DESIGN.md) once; it explains *why* the two builds differ.

> **Automation:** stages 1, 4 and 5 are implemented by [`../build.sh`](../build.sh)
> and `.github/workflows/build-kernel.yml`. The manual commands below are the
> reference those scripts execute and are worth reading once, especially when a
> build fails. `build.sh --stage profiler|optimized` verifies the resulting
> `.config` so a mistyped symbol cannot silently produce the wrong build.

- Target tree: [`mt6768-S/android_kernel_xiaomi_mt6768`](https://github.com/mt6768-S/android_kernel_xiaomi_mt6768) (Linux 4.19, `vendor/mt6768_defconfig`)
- Arch: arm64 (Cortex-A75/A55)
- Compiler: Clang/LLD 17+ (19+ for Propeller)
- Sampler: ARM SPE (`arm_spe_0`)

| Stage | Where | Output |
|---|---|---|
| 1. Profiling kernel | host | bootable image + unstripped `vmlinux` |
| 2. Verification | device | `kpti=off`, `arm_spe_0` present |
| 3. Training | device | `perf-*.data` |
| 4. Conversion | host | `*.afdo` |
| 5. Production kernel | host | optimized image |
| 6. Validation | host + device | layout/coverage checks |

---

## 0. Prerequisites

### Host

- Linux x86_64, ~16 GiB RAM, ~40 GiB disk (LTO builds are memory hungry).
- `git`, `curl`, `python3`, `perf` (host copy only for inspection), `zstd`.
- Clang toolchain from `build.env` (`CLANG_SOURCE`), unpacked and on `PATH`:

  ```sh
  clang --version
  ld.lld --version
  llvm-profdata --version
  ```

  AutoFDO requires LLVM 17+; Propeller requires LLVM 19+.

- Profile tools:

  ```sh
  # google/autofdo, v0.30.1 or newer (SPE support: v0.20+)
  create_llvm_prof --version
  ```

  `llvm-profgen` (LLVM 19+) is an alternative but the SPE path in this project
  is documented against `create_llvm_prof`.

### Device

- Unlocked bootloader, ability to flash `boot`/`dtbo` (or the AnyKernel3 zip
  produced by `build.env` settings), and a root shell (`adb root` or `su`).
- An `arm64` `perf` binary. AOSP's `perf` from the matching platform works;
  push it to `/data/local/tmp/perf` and `chmod +x`.
- Battery above ~50% and thermal headroom — throttling skews the profile.

> **Sanity check before you invest time:** SPE must be present in hardware,
> enabled in the DT, and allowed by the kernel. Section 2 verifies this. If
> `arm_spe_0` never appears, stop and read
> [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#arm_spe_0-is-missing) — there is no
> sample source and no profile without it.

---

## Patch stack

The 4.19 tree predates upstream AutoFDO, so these backports are required. They
are already carried by the `mt6768-S` tree at the commit pinned in `build.env`;
apply them in this order on a clean tree.

| # | Commit | Purpose |
|---|---|---|
| 1 | [BACKPORT: Makefile: Add AutoFDO support for Clang build](https://github.com/mt6768-S/android_kernel_xiaomi_mt6768/commit/a51ce57f1603e18be3b00dfda745439832f02641) | `CONFIG_AUTOFDO_CLANG`, `-gmlt`, `CLANG_AUTOFDO_PROFILE`, LTO sample-profile flags |
| 2 | [BACKPORT: vmlinux: Adjust symbol ordering in text output section and add markers](https://github.com/mt6768-S/android_kernel_xiaomi_mt6768/commit/3f2b12560619306d23de29bd13e1a9b11bb53b29) | `.text.hot` / `.text.unlikely` ordering, `__hot_text_*` markers |
| 3 | [AutoFDO: Enable `-ffunction-sections` for the AutoFDO build](https://github.com/mt6768-S/android_kernel_xiaomi_mt6768/commit/9b8063ef058698936de6127928bec65b2041cb74) | per-function sections when a profile is used |
| 4 | [AutoFDO: Enable machine function split optimization](https://github.com/mt6768-S/android_kernel_xiaomi_mt6768/commit/1cdcf552317906d40e925afe1e4698ae8155eacd) | hot/cold splitting (`-fsplit-machine-functions`) |
| 5 | [AutoFDO: Add arm64 support](https://github.com/mt6768-S/android_kernel_xiaomi_mt6768/commit/3e782ab7ec0b68df1dd0e92c9e0e995a0b6ae7bc) | `ARCH_SUPPORTS_AUTOFDO_CLANG` on arm64 |
| 6 | [arch: Add helper Kconfig for arm64 spe profiler](https://github.com/mt6768-S/android_kernel_xiaomi_mt6768/commit/63a85f77d12ebdd33c67d9c63edd26342e799f82) | `CONFIG_AUTOFDO_CLANG_PROFILER_ARM64_SPE` → selects `ARM_SPE_PMU`, `PID_IN_CONTEXTIDR`, appends `kpti=off` |
| 7 | [Add Propeller configuration for kernel build](https://github.com/mt6768-S/android_kernel_xiaomi_mt6768/commit/63a85f77d12ebdd33c67d9c63edd26342e799f82) | `CONFIG_PROPELLER_CLANG`, `.llvm_bb_addr_map` |
| 8 | [arch/arm64: Enable AUTOFDO_CLANG](https://github.com/mt6768-S/android_kernel_xiaomi_mt6768/commit/bedbd08bab07bf0c12695423711d1e3bd947f3fd) | `CONFIG_AUTOFDO_CLANG=y` in the defconfig |
| 9 | [CONFIG_PROPELLER_CLANG=y](https://github.com/mt6768-S/android_kernel_xiaomi_mt6768/commit/0e882cae3bd21c071b3a4ea415c3ee7d4e212c39) | `CONFIG_PROPELLER_CLANG=y` in the defconfig |

If you build from a different tree/branch, verify each patch is present before
blaming the profile:

```sh
grep -n "AUTOFDO" Makefile arch/Kconfig arch/arm64/Kconfig
grep -n "ARM64_SPE\|PROPELLER" arch/Kconfig
```

> Commits 8 and 9 flip both features on *in the defconfig*, i.e. the default
> build is a production-style LTO+AutoFDO kernel. The profiling build therefore
> has to start from the defconfig and then change options explicitly — which is
> what `helpers/cc.py` does below.

---

## 1. Build the profiling kernel

The goal: LTO off, AutoFDO enabled (so `-gmlt` is emitted), SPE helpers on,
no profile to consume.

```sh
make O=out ARCH=arm64 vendor/mt6768_defconfig

python3 helpers/cc.py \
    CONFIG_LTO_CLANG=n \
    CONFIG_THINLTO=n \
    CONFIG_AUTOFDO_CLANG=y \
    CONFIG_AUTOFDO_CLANG_PROFILER_ARM64_SPE=y \
    CONFIG_DEBUG_INFO=n
```

`helpers/cc.py` edits `out/.config` in place and appends missing symbols.
Run it *after* `defconfig`, never before.

Optional hardening knobs — keep them **identical** in both builds:

```sh
python3 helpers/cc.py CONFIG_CFI_CLANG=y CONFIG_SHADOW_CALL_STACK=y
```

Keep `CONFIG_KALLSYMS_ALL=y` (already in the defconfig) so the profile tools see
full symbol names; enable `CONFIG_IKCONFIG`/`CONFIG_IKCONFIG_PROC` if you want
to dump the running config on the device.
`CONFIG_DEBUG_INFO=n` is fine: `CONFIG_AUTOFDO_CLANG` adds `-gmlt`, which is all
`create_llvm_prof` needs — provided you keep the unstripped `vmlinux`.

Build:

```sh
make O=out ARCH=arm64 -j"$(nproc)" \
    LLVM=1 LLVM_IAS=1 \
    CROSS_COMPILE=aarch64-linux-gnu- \
    CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
    CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
```

`.env` reference: `build.env` holds `KERNEL_SOURCE`, `CLANG_SOURCE`, the
`EXTRA_CMDS`, KernelSU/NoMount/AnyKernel3 toggles.

Archive the training binary immediately — the profile is only valid against it:

```sh
mkdir -p profiles/devices/<device>/
cp out/arch/arm64/boot/vmlinux  profiles/devices/<device>/vmlinux-training
cp out/.config                  profiles/devices/<device>/config-training
sha256sum out/arch/arm64/boot/vmlinux | tee \
    profiles/devices/<device>/vmlinux-training.sha256
```

`Image.gz-dtb` is bootable but **useless** for profile conversion — it has no
symbol table. Always keep `arch/arm64/boot/vmlinux`.

---

## 2. Flash and verify

Flash the training image (AnyKernel3 zip with `USE_ANYKERNEL3=true`, or
`fastboot flash boot` — device dependent), boot, and check:

```sh
adb shell 'cat /proc/cmdline'
# ... kpti=off ...          <- appended by CONFIG_AUTOFDO_CLANG_PROFILER_ARM64_SPE

adb shell 'dmesg | grep -iE "spe|kpti"'
# arm_spe_pmu ... : probed
# Kernel/User page tables isolation: disabled

adb shell 'ls /sys/bus/event_source/devices/'
# arm_spe_0                 <- the sampler must be here

adb shell 'cat /sys/bus/event_source/devices/arm_spe_0/format/*'
# branch_filter, min_latency, jitter, pa_enable, ...

adb shell 'grep -i spe /proc/interrupts'   # per-CPU PPI counters
```

Also confirm the *right* kernel is running:

```sh
adb shell 'uname -a'
adb shell 'zcat /proc/config.gz | grep -E "AUTOFDO|LTO|SPE"'   # if IKCONFIG=y
```

If `arm_spe_0` is absent, do not proceed: a `perf record` against it fails, and
there is no fallback sampler in this tree. See
[`SPE-BRINGUP.md`](SPE-BRINGUP.md) for the DT/PPI/hardware checklist and
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#arm_spe_0-is-missing).

> `kpti=off` is mandatory: `arm_spe_pmu` refuses to probe when the kernel is
> mapped at EL0 (`drivers/perf/arm_spe_pmu.c` returns `-EPERM`), because the SPE
> AUX buffer would fault. Never ship this config.

---

## 3. Collect samples

Three workloads, because a profile is only as representative as its training
data. Run them on a warm, idle device, one session per file, and keep the
screen state / thermal state comparable to real use.

| Workload | Duration | What it captures |
|---|---|---|
| `boot` | ~120 s after reboot | init, service startup, first-launch paths |
| `daily` | 30–60 min | UI, browsing, messaging, camera, background sync |
| `game` | 20–30 min | sustained GPU/CPU load, scheduler and ioctl hot paths |

Raw commands (the `collector/*.sh` wrappers will encode exactly these once
implemented):

```sh
adb shell '/data/local/tmp/perf record -e arm_spe_0/branch_filter=1/ -a -N -c 500009 \
           -o /data/local/tmp/perf-boot.data -- sleep 120'

adb shell '/data/local/tmp/perf record -e arm_spe_0/branch_filter=1/ -a -N -c 500009 \
           -o /data/local/tmp/perf-daily.data -- sleep 2400'

adb shell '/data/local/tmp/perf record -e arm_spe_0/branch_filter=1/ -a -N -c 500009 \
           -o /data/local/tmp/perf-game.data -- sleep 1800'
```

Notes:

- `-a` is used for every profile here: it covers all CPUs and all processes,
  which is what the kernel's own hot paths need. This tree has
  `CONFIG_PID_IN_CONTEXTIDR` and the training build enables it, so `-p <pid>`
  also works when you want to isolate one app — but do not use `-p` for the
  boot/daily profiles, where most of the interesting work is spread across
  processes.
- `-c 500009`: a prime-ish sampling period, as recommended upstream. Lower =
  more samples = larger files and more overhead.
- `-N` skips the build-id cache work; the profile only needs kernel symbols
  from `vmlinux`, and this keeps the files smaller and collection cheaper.
- `branch_filter=1` restricts SPE to branch records, which is what the branch
  profile wants. Drop it if you also want latency/load-store records.
- Verify the file is non-trivial before pulling: `ls -l` should be tens of MB
  for 20+ minutes of load, and `perf report --stdio -i file | head` should show
  symbols.

Pull everything:

```sh
adb pull /data/local/tmp/perf-boot.data  profiles/devices/<device>/
adb pull /data/local/tmp/perf-daily.data profiles/devices/<device>/
adb pull /data/local/tmp/perf-game.data  profiles/devices/<device>/
```

Keep the raw `perf.data` files until the final build is validated; conversion
parameters often need a second attempt.

---

## 4. Generate the AutoFDO profile

Convert each session against the **training** `vmlinux` (the one you archived in
step 1), with the same machine/endianness assumptions:

```sh
create_llvm_prof \
    --binary=profiles/devices/<device>/vmlinux-training \
    --profile=profiles/devices/<device>/perf-game.data \
    --profiler=perf_spe \
    --format=extbinary \
    --out=profiles/devices/<device>/mt6768-game.afdo
```

Repeat for `boot` and `daily`, then merge:

```sh
llvm-profdata merge -o profiles/devices/<device>/mt6768.afdo \
    profiles/devices/<device>/mt6768-boot.afdo \
    profiles/devices/<device>/mt6768-daily.afdo \
    profiles/devices/<device>/mt6768-game.afdo
```

Sanity check:

```sh
llvm-profdata show --all-functions profiles/devices/<device>/mt6768.afdo | head -40
ls -lh profiles/devices/<device>/mt6768.afdo
```

A profile covering only a handful of functions means the samples did not match
the binary (wrong `vmlinux`, stripped symbols, or a build from a different
commit) — see [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#the-profile-is-empty-or-has-almost-no-functions).

Weighting the merge (optional): if gaming matters more than boot, merge twice

```sh
llvm-profdata merge -o mt6768-weight.afdo mt6768-game.afdo mt6768-game.afdo mt6768-daily.afdo
```

`llvm-profdata` should come from the same LLVM major version as the Clang that
will consume the profile. Mismatched versions usually still read the file, but
`extbinary` is not a stable cross-version format in every direction.

---

## 5. Build the production kernel

Now switch the *same* tree to LTO + profile use. Everything else that affects
codegen must stay as it was in step 1.

```sh
python3 helpers/cc.py \
    CONFIG_LTO_CLANG=y \
    CONFIG_THINLTO=y \
    CONFIG_AUTOFDO_CLANG=y \
    CONFIG_AUTOFDO_CLANG_PROFILER_ARM64_SPE=n
```

On this 4.19 tree ThinLTO is `CONFIG_THINLTO` (default `y` when
`CONFIG_LTO_CLANG=y`). Newer trees spell it `CONFIG_LTO_CLANG_THIN`.

> **Clean between stages.** Object files built without LTO cannot be reused in
> an LTO link. Run `make O=out clean` (or use a separate `O=out-training`
> directory) after flipping `CONFIG_LTO_CLANG`; otherwise the production build
> either fails in `ld.lld` or silently links stale non-LTO objects.

Build with the profile:

```sh
make O=out ARCH=arm64 -j"$(nproc)" \
    LLVM=1 LLVM_IAS=1 \
    CROSS_COMPILE=aarch64-linux-gnu- \
    CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
    CROSS_COMPILE_COMPAT=arm-linux-gnueabi- \
    CLANG_AUTOFDO_PROFILE="$PWD/profiles/devices/<device>/mt6768.afdo"
```

What the Makefile does with those switches:

| Switch | Effect |
|---|---|
| `CONFIG_AUTOFDO_CLANG=y` | `-gmlt` if no debug info; enables LTO-side FS discriminators |
| `CLANG_AUTOFDO_PROFILE=...` | `-fprofile-sample-use=<afdo>` per TU, `--lto-sample-profile=<afdo>` at link |
| implicit with profile | `-ffunction-sections`, `-fsplit-machine-functions` |
| `CONFIG_THINLTO=y` | `-flto=thin`, `--thinlto-cache-dir` |

Propeller (optional, second profiling round — see
[`DESIGN.md`](DESIGN.md#5-propeller)):

```sh
python3 helpers/cc.py CONFIG_PROPELLER_CLANG=y
make ... \
    CLANG_AUTOFDO_PROFILE="$PWD/.../mt6768.afdo" \
    CLANG_PROPELLER_PROFILE_PREFIX="$PWD/profiles/devices/<device>/propeller"
```

`<prefix>_cc_profile.txt` and `<prefix>_ld_profile.txt` must exist; generate
them with `create_llvm_prof --format=propeller` from a *second* sampling round
on the AutoFDO-optimized kernel (upstream documents the full loop).

---

## 6. Validate

### Build actually consumed the profile

```sh
grep -rl "fprofile-sample-use" out --include=*.cmd | head
grep -rl "lto-sample-profile"  out --include=*.cmd | head
```

If the flags are missing, `CLANG_AUTOFDO_PROFILE` was not exported to the
sub-make or the profile path does not exist (make would warn).

### Layout looks profiled

```sh
grep -E "__hot_text_(start|end)|__unlikely_text_(start|end)|__split_text_(start|end)" out/System.map

# Propeller only:
llvm-objdump -h out/arch/arm64/boot/vmlinux | grep llvm_bb_addr_map
```

The `.text.*` input sections are folded into the `.text` output section by the
linker script, so `objdump -h` will *not* list them separately — use the markers
instead. `__hot_text_end > __hot_text_start` by a meaningful margin means hot
code was actually grouped; an empty range means the profile never reached the
compiler. Cold code should land in the `__unlikely_text_*` range and, with
machine-function-splitting, in `__split_text_*`.

### Runtime

- Boot the production image, confirm `kpti=off` is **gone** from `/proc/cmdline`.
- Run the same workloads you trained on; compare against the training build
  (frame timing, `perf stat`, or simply boot time and app launch latency).
- Watch for boot loops or CFI failures: that usually means the profile was
  built from a different source revision than the binary.

### Record provenance

```sh
git -C <kernel> rev-parse HEAD > profiles/devices/<device>/KERNEL_COMMIT
clang --version | head -1        > profiles/devices/<device>/CLANG_VERSION
sha256sum profiles/devices/<device>/mt6768.afdo
```

See [`profiles/README.md`](../profiles/README.md) for the layout contract.
