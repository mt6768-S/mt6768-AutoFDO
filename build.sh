#!/usr/bin/env bash
#
# build.sh — two-stage AutoFDO kernel builder for mt6768.
#
#   profiler   training kernel: LTO off, CONFIG_AUTOFDO_CLANG=y (emits -gmlt),
#              ARM SPE enabled, kpti=off. Produces the vmlinux that perf.data
#              must be converted against. Never ship this on a daily driver.
#
#   optimized  production kernel: ThinLTO on, CONFIG_AUTOFDO_CLANG=y and
#              CLANG_AUTOFDO_PROFILE=<profile>. Consumes the .afdo profile.
#
#
# Usage:
#   ./build.sh --stage profiler  --device selene
#   ./build.sh --stage optimized --device selene --profile profiles/devices/selene/mt6768.afdo
#
# Environment comes from build.env. build.env is authoritative.
#
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# logging
# ---------------------------------------------------------------------------
log()  { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn ]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }

trap 'die "failed at line $LINENO: $BASH_COMMAND"' ERR

# ---------------------------------------------------------------------------
# arguments
# ---------------------------------------------------------------------------
STAGE=""
DEVICE=""
PROFILE=""

usage() {
	cat <<'EOF'
Usage: ./build.sh --stage <profiler|optimized> --device <merlin|lancelot|selene>
                  [--profile <path/to/profile.afdo>]

  --stage     profiler  = training kernel (SPE, no LTO)
              optimized = production kernel (ThinLTO + AutoFDO profile)
  --device    device codename; selects arch/arm64/configs/vendor/<device>.config
  --profile   .afdo profile; also read from $CLANG_AUTOFDO_PROFILE
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--stage)   STAGE="${2:?--stage needs a value}"; shift 2 ;;
		--device)  DEVICE="${2:?--device needs a value}"; shift 2 ;;
		--profile) PROFILE="${2:?--profile needs a value}"; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown argument: $1 (try --help)" ;;
	esac
done

# ---------------------------------------------------------------------------
# env loading
# ---------------------------------------------------------------------------
load_env() {
	local file="$1"
	[ -f "$file" ] || return 0
	command -v python3 >/dev/null || die "python3 not found (needed to parse $file)"
	# helpers/env.py is the single parser shared with the CI workflow.
	eval "$(python3 "$REPO_ROOT/helpers/env.py" --format export "$file")"
}

load_env "$REPO_ROOT/build.env"

# ---------------------------------------------------------------------------
# defaults
# ---------------------------------------------------------------------------
WORKSPACE="${WORKSPACE:-$REPO_ROOT}"
KERNEL_WORKSPACE="${KERNEL_WORKSPACE:-$WORKSPACE/kernel_workspace}"
KERNEL_DIR="${KERNEL_DIR:-$KERNEL_WORKSPACE/android-kernel}"
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-$KERNEL_WORKSPACE/clang}"
ANYKERNEL_DIR="${ANYKERNEL_DIR:-$KERNEL_WORKSPACE/AnyKernel3}"
PROFILER_CACHE_DIR="${PROFILER_CACHE_DIR:-$KERNEL_WORKSPACE/profiler-cache}"
DIST_DIR="${DIST_DIR:-$KERNEL_WORKSPACE/dist}"
INTEGRATION_FRAGMENT="$KERNEL_DIR/kbuild-integrations.config"

KERNEL_CONFIG_BASE="${KERNEL_CONFIG_BASE:-vendor/mt6768_defconfig}"
KERNEL_CONFIG_FRAGMENT_DIR="${KERNEL_CONFIG_FRAGMENT_DIR:-vendor}"
ENABLE_CCACHE="${ENABLE_CCACHE:-true}"
HAS_SPE="${HAS_SPE:-false}"

KERNEL_ARCH="${KERNEL_ARCH:-arm64}"
KERNEL_IMAGE_NAME="${KERNEL_IMAGE_NAME:-Image.gz-dtb}"
KERNEL_DTB_NAME="${KERNEL_DTB_NAME:-mt6768.dtb}"
EXTRA_CMDS="${EXTRA_CMDS:-LLVM=1 LLVM_IAS=1 CROSS_COMPILE=aarch64-linux-gnu-}"

[ -n "$PROFILE" ] || PROFILE="${CLANG_AUTOFDO_PROFILE:-}"

# ---------------------------------------------------------------------------
# validation
# ---------------------------------------------------------------------------
case "$STAGE" in
	profiler|optimized) ;;
	"") die "missing --stage (profiler|optimized)" ;;
	*)  die "invalid --stage: $STAGE" ;;
esac

[ -n "$DEVICE" ] || die "missing --device (merlin|lancelot|selene)"

if [ "$STAGE" = "optimized" ]; then
	[ -n "$PROFILE" ] || die "optimized stage needs --profile or CLANG_AUTOFDO_PROFILE"
	[ -f "$PROFILE" ] || die "profile not found: $PROFILE"
	PROFILE="$(cd "$(dirname "$PROFILE")" && pwd)/$(basename "$PROFILE")"
	[ -s "$PROFILE" ] || die "profile is empty: $PROFILE"
fi

command -v make >/dev/null || die "make not found"
command -v git  >/dev/null || die "git not found"
command -v curl >/dev/null || die "curl not found (needed for KernelSU/NoMount setup)"
command -v clang >/dev/null || die "clang not found in PATH (set TOOLCHAIN_DIR)"

mkdir -p "$KERNEL_WORKSPACE" "$DIST_DIR"

# ---------------------------------------------------------------------------
# toolchain
# ---------------------------------------------------------------------------
if [ -d "$TOOLCHAIN_DIR/bin" ]; then
	export PATH="$TOOLCHAIN_DIR/bin:$PATH"
fi

CLANG_MAJOR="$(clang --version | head -n1 | grep -oE '[0-9]+' | head -n1 || true)"
[ -n "$CLANG_MAJOR" ] || die "could not parse clang version"
# CONFIG_AUTOFDO_CLANG depends on CLANG_VERSION >= 170000.
[ "$CLANG_MAJOR" -ge 17 ] || die "AutoFDO needs Clang >= 17 (found $CLANG_MAJOR)"
if [ "$CLANG_MAJOR" -lt 19 ]; then
	warn "Clang $CLANG_MAJOR: Propeller (>= 19) unavailable; AutoFDO itself is fine."
fi

log "stage=$STAGE device=$DEVICE"
log "clang: $(clang --version | head -n1)"

# ---------------------------------------------------------------------------
# source
# ---------------------------------------------------------------------------
fetch_kernel() {
	[ -d "$KERNEL_DIR/.git" ] && return 0
	step "Cloning $KERNEL_SOURCE @ $KERNEL_SOURCE_BRANCH"
	mkdir -p "$(dirname "$KERNEL_DIR")"
	git init -q "$KERNEL_DIR"
	git -C "$KERNEL_DIR" remote add origin "$KERNEL_SOURCE"
	if ! git -C "$KERNEL_DIR" fetch --depth=1 -q origin "$KERNEL_SOURCE_BRANCH"; then
		git -C "$KERNEL_DIR" fetch --depth=1 -q origin
		git -C "$KERNEL_DIR" cat-file -e "${KERNEL_SOURCE_BRANCH}^{commit}" 2>/dev/null \
			|| die "cannot fetch $KERNEL_SOURCE_BRANCH from $KERNEL_SOURCE"
	fi
	git -C "$KERNEL_DIR" -c advice.detachedHead=false checkout -q FETCH_HEAD
}

# The upstream integration projects distribute their kernel integration as
# setup scripts.  Run those scripts from the kernel root; both scripts modify
# the tree in place and accept a branch/tag/commit as their sole argument.
download_ksu() {
	[ "${ENABLE_KERNELSU:-false}" = "true" ] || return 0
	local source="${KERNELSU_SETUP_SOURCE:-https://raw.githubusercontent.com/backslashxx/KernelSU/master/kernel/setup.sh}"
	local tag="${KERNELSU_TAG:-master}"
	step "Installing KernelSU ($tag)"
	[ -n "$source" ] || die "KERNELSU_SETUP_SOURCE is empty"
	(
		cd "$KERNEL_DIR"
		curl -fsSL --retry 3 "$source" | sh -s -- "$tag"
	)
}

download_nomount() {
	[ "${ENABLE_NOMOUNT:-false}" = "true" ] || return 0
	local source="${NOMOUNT_SETUP_SOURCE:-https://raw.githubusercontent.com/maxsteeel/nomount/refs/heads/dev/kernel/setup.sh}"
	local tag="${NOMOUNT_TAG:-dev}"
	step "Installing NoMount ($tag)"
	[ -n "$source" ] || die "NOMOUNT_SETUP_SOURCE is empty"
	(
		cd "$KERNEL_DIR"
		curl -fsSL --retry 3 "$source" | sh -s -- "$tag"
	)
}


apply_spe_patch() {
	local dts="arch/arm64/boot/dts/mediatek/mt6768.dts"
	local patch="$REPO_ROOT/patches/0001-arm64-dts-mt6768-add-arm-spe-node.patch"
	[ "$STAGE" = "profiler" ] || return 0
	[ "$HAS_SPE" = "true" ] || { warn "SPE DT patch disabled"; return 0; }
	[ -f "$patch" ] || die "missing $patch"

	if grep -q 'statistical-profiling-extension-v1' "$KERNEL_DIR/$dts"; then
		log "SPE DT node already present"
		return 0
	fi
	step "Applying ARM SPE device-tree node"
	git -C "$KERNEL_DIR" apply --whitespace=nowarn "$patch" \
		|| die "SPE DT patch does not apply (tree moved upstream?)"
}

# ---------------------------------------------------------------------------
# configuration
# ---------------------------------------------------------------------------
cc_cmd() {
	if [ "$ENABLE_CCACHE" = "true" ] && command -v ccache >/dev/null 2>&1; then
		printf '%s' 'ccache clang'
	else
		printf '%s' 'clang'
	fi
}

gen_config() {
	local base="arch/arm64/configs/$KERNEL_CONFIG_BASE"
	local frag="arch/arm64/configs/$KERNEL_CONFIG_FRAGMENT_DIR/$DEVICE.config"
	local -a edits=()
	local -a ccarg=(CC="$(cc_cmd)")
	local line

	step "Generating .config ($DEVICE fragment)"
	cd "$KERNEL_DIR"
	[ -f "$base" ] || die "missing base config: $base"
	[ -f "$frag" ] || die "missing device fragment: $frag"
	rm -rf out
	mkdir -p out
	./scripts/kconfig/merge_config.sh -m -O out "$base" "$frag" >/dev/null

	# Integration scripts add their Kconfig symbols to this fragment.
	if [ -s "$INTEGRATION_FRAGMENT" ]; then
		while IFS= read -r line; do
			[ -n "$line" ] && edits+=("$line")
		done < <(grep -E '^CONFIG_[A-Za-z0-9_]+=[^[:space:]]+$' "$INTEGRATION_FRAGMENT" || true)
		log "integration flags: ${#edits[@]}"
	fi
	if [ "${ENABLE_NOMOUNT:-false}" = "true" ]; then
		edits+=("CONFIG_NOMOUNT=y")
	fi
	if [ "${ENABLE_KERNELSU:-false}" = "true" ]; then
		edits+=(
			"CONFIG_KSU=y"
			"CONFIG_KSU_EXTRAS=y"
			"CONFIG_KSU_TAMPER_SYSCALL_TABLE=y"
			"CONFIG_KSU_THRONE_TRACKER_ALWAYS_THREADED=y"
		)
	fi

	# Flags common to both stages.
	edits+=(
		"CONFIG_AUTOFDO_CLANG=y"
		"CONFIG_PROPELLER_CLANG=n"
		"CONFIG_CC_WERROR=n"
		"CONFIG_KALLSYMS_ALL=y"
	)

	# 3) Stage-specific flags. MT6768 does not have SPE support by default.
	if [ "$STAGE" = "profiler" ]; then
		edits+=(
			"CONFIG_LTO_CLANG=n"
			"CONFIG_LTO_NONE=y"
			"CONFIG_THINLTO=n"
			"CONFIG_CFI_CLANG=n"
			"CONFIG_PERF_EVENTS=y"
			"CONFIG_HW_PERF_EVENTS=y"
			"CONFIG_DEBUG_INFO=y",
			"CONFIG_FUNCTION_TRACER=y
			CONFIG_FUNCTION_GRAPH_TRACER=y"
		)
		[ "$HAS_SPE" = "y" ] && edits+=(
			"CONFIG_AUTOFDO_CLANG_PROFILER_ARM64_SPE=y"
			"CONFIG_ARM_SPE_PMU=y"
			"CONFIG_PID_IN_CONTEXTIDR=y"
		) || edits+=(
			"CONFIG_AUTOFDO_CLANG_PROFILER_ARM64_SPE=n"
			"CONFIG_ARM_SPE_PMU=n"
			"CONFIG_PID_IN_CONTEXTIDR=n"
		)
	else
		edits+=(
			"CONFIG_LTO_CLANG=y"
			"CONFIG_THINLTO=y"
		)
		[ "$HAS_SPE" = "y" ] || edits+=(
			"CONFIG_AUTOFDO_CLANG_PROFILER_ARM64_SPE=n"
			"CONFIG_ARM_SPE_PMU=n"
			"CONFIG_PID_IN_CONTEXTIDR=n"
		)
	fi

	python3 "$REPO_ROOT/helpers/cc.py" --config "$KERNEL_DIR/out/.config" "${edits[@]}"

	step "Resolving config with $(cc_cmd)"
	make -s O=out ARCH="$KERNEL_ARCH" "${ccarg[@]}" $EXTRA_CMDS olddefconfig
}

cfg_is()  { grep -qx "CONFIG_$1=$2" "$KERNEL_DIR/out/.config"; }
cfg_off() { ! grep -qx "CONFIG_$1=[ym]" "$KERNEL_DIR/out/.config"; }

assert_config() {
	local bad=0 line
	local cfg="$KERNEL_DIR/out/.config"

	if [ "$STAGE" = "profiler" ] && [ "$HAS_SPE" = "y" ]; then
		cfg_is AUTOFDO_CLANG y                          || { warn "AUTOFDO_CLANG is not y"; bad=1; }
		cfg_is AUTOFDO_CLANG_PROFILER_ARM64_SPE y       || { warn "SPE helper is not y"; bad=1; }
		cfg_is ARM_SPE_PMU y                            || { warn "ARM_SPE_PMU is not y"; bad=1; }
		cfg_is PID_IN_CONTEXTIDR y                      || { warn "PID_IN_CONTEXTIDR is not y"; bad=1; }
		cfg_is LTO_NONE y                               || { warn "LTO_NONE is not y"; bad=1; }
		cfg_off LTO_CLANG                               || { warn "LTO_CLANG is enabled in the profiler build"; bad=1; }
		cfg_off THINLTO                                 || { warn "THINLTO is enabled in the profiler build"; bad=1; }
	else
		cfg_is AUTOFDO_CLANG y                          || { warn "AUTOFDO_CLANG is not y"; bad=1; }
		cfg_is LTO_CLANG y                              || { warn "LTO_CLANG is not y"; bad=1; }
		cfg_is THINLTO y                                || { warn "THINLTO is not y"; bad=1; }
		cfg_off AUTOFDO_CLANG_PROFILER_ARM64_SPE        || { warn "SPE helper must be off in production (it forces kpti=off)"; bad=1; }
		cfg_off PID_IN_CONTEXTIDR                       || { warn "PID_IN_CONTEXTIDR must be off in production"; bad=1; }
	fi
	cfg_off PROPELLER_CLANG || { warn "PROPELLER_CLANG is enabled but no propeller profile was supplied"; bad=1; }

	if [ "$bad" -ne 0 ]; then
		warn "relevant .config lines:"
		grep -E 'CONFIG_(LTO|THINLTO|AUTOFDO|ARM_SPE|PID_IN_CONTEXTIDR|CFI_CLANG|PROPELLER|KSU|NOMOUNT)' \
			"$cfg" >&2 || true
		die "config verification failed for the $STAGE stage"
	fi
	log "config verified for $STAGE stage"
}

# ---------------------------------------------------------------------------
# build + provenance
# ---------------------------------------------------------------------------
build_kernel() {
	local -a ccarg=(CC="$(cc_cmd)")
	local -a profile_arg=()
	[ "$STAGE" = "optimized" ] && profile_arg=("CLANG_AUTOFDO_PROFILE=$PROFILE")

	step "Compiling ($STAGE)"
	cd "$KERNEL_DIR"
	make -j"$(nproc)" O=out ARCH="$KERNEL_ARCH" "${ccarg[@]}" $EXTRA_CMDS "${profile_arg[@]}"

	local image="$KERNEL_DIR/out/arch/$KERNEL_ARCH/boot/$KERNEL_IMAGE_NAME"
	local dtb="$KERNEL_DIR/out/arch/$KERNEL_ARCH/boot/dts/mediatek/$KERNEL_DTB_NAME"
	[ -s "$image" ] || die "missing build output: $image"
	[ -s "$dtb" ] || die "missing DTB output: $dtb"
	[ -s "$KERNEL_DIR/out/vmlinux" ] || die "missing build output: out/vmlinux"
}

write_provenance() {
	local dest="$1"
	mkdir -p "$(dirname "$dest")"
	local image="$KERNEL_DIR/out/arch/$KERNEL_ARCH/boot/$KERNEL_IMAGE_NAME"
	{
		echo "STAGE=$STAGE"
		echo "DEVICE=$DEVICE"
		echo "KERNEL_COMMIT=$(git -C "$KERNEL_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
		echo "CLANG_VERSION=$(clang --version | head -n1)"
		echo "BUILD_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		echo "IMAGE_SHA256=$(sha256sum "$image" | cut -d' ' -f1)"
		echo "VMLINUX_SHA256=$(sha256sum "$KERNEL_DIR/out/vmlinux" | cut -d' ' -f1)"
		if [ -s "$INTEGRATION_FRAGMENT" ]; then
			echo "INTEGRATION=$(grep -E '^CONFIG_' "$INTEGRATION_FRAGMENT" | tr '\n' ' ')"
		fi
		if [ "$STAGE" = "optimized" ]; then
			echo "PROFILE=$PROFILE"
			echo "PROFILE_SHA256=$(sha256sum "$PROFILE" | cut -d' ' -f1)"
		fi
	} > "$dest"
	cat "$dest"
}

cache_profiler_outputs() {
	local dest="$PROFILER_CACHE_DIR/$DEVICE"
	step "Caching profiler artifacts in $dest"
	mkdir -p "$dest"
	cp -f "$KERNEL_DIR/out/vmlinux" "$dest/vmlinux"
	cp -f "$KERNEL_DIR/out/arch/$KERNEL_ARCH/boot/$KERNEL_IMAGE_NAME" "$dest/$KERNEL_IMAGE_NAME"
	cp -f "$KERNEL_DIR/out/.config" "$dest/config"
	cp -f "$KERNEL_DIR/out/arch/$KERNEL_ARCH/boot/dts/mediatek/$KERNEL_DTB_NAME" \
	"$dest/$KERNEL_DTB_NAME"
	write_provenance "$dest/provenance.env"
}

verify_cached_profiler() {
	local dest="$PROFILER_CACHE_DIR/$DEVICE"
	local need=("$dest/vmlinux" "$dest/$KERNEL_IMAGE_NAME" "$dest/provenance.env" "$dest/$KERNEL_DTB_NAME")
	local f
	for f in "${need[@]}"; do
		[ -s "$f" ] || die "profiler cache is incomplete (missing $f); clear the cache key and rebuild"
	done
	log "reusing cached profiler build: $(grep -h 'KERNEL_COMMIT=' "$dest/provenance.env")"
}

package_anykernel() {
	local image="$1" zip="$2" note="${3:-}"
	local dtb="$KERNEL_DIR/out/arch/$KERNEL_ARCH/boot/dts/mediatek/$KERNEL_DTB_NAME"

	step "Packaging $(basename "$zip")"

	if [ ! -d "$ANYKERNEL_DIR" ]; then
		git clone -q --depth=1 -b "${ANYKERNEL3_BRANCH:-master}" \
			"$ANYKERNEL3_SOURCE" "$ANYKERNEL_DIR" \
			|| die "cannot clone AnyKernel3 from $ANYKERNEL3_SOURCE"
	fi

	[ -s "$image" ] || die "missing kernel image: $image"
	[ -s "$dtb" ] || die "missing kernel DTB: $dtb"

	mkdir -p "$ANYKERNEL_DIR/dtb"

	cp -f "$image" "$ANYKERNEL_DIR/"
	cp -f "$dtb" "$ANYKERNEL_DIR/dtb/$KERNEL_DTB_NAME"

	if [ -n "$note" ]; then
		printf '%s\n' "$note" > "$ANYKERNEL_DIR/AUTOFDO-README.txt"
	fi

	rm -f "$zip"
	(
		cd "$ANYKERNEL_DIR"
		zip -q -r9 "$zip" . -x '*.git*' 'README.md'
	)

	[ -s "$zip" ] || die "zip was not created: $zip"

	log "Image: $(basename "$image")"
	log "DTB: dtb/$KERNEL_DTB_NAME"
	log "$(basename "$zip") ($(du -h "$zip" | cut -f1))"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
PROFILER_NOTE="AutoFDO training kernel ($DEVICE).

Flash this, boot it, and confirm the sampler before collecting:

  adb shell 'cat /proc/cmdline'                       # must contain kpti=off
  adb shell 'ls /sys/bus/event_source/devices/'       # must list arm_spe_0
  adb shell 'dmesg | grep -i spe'

Then collect with perf (NOT simpleperf):

  perf record -e arm_spe_0/branch_filter=1/ -a -N -c 500009 \\
              -o /data/local/tmp/perf.data -- sleep 1800

Do NOT use this kernel as a daily driver."

STAMP="$(date -u +%Y%m%d-%H%M)"
ARTIFACT_BASE="${DEVICE}-${STAGE}-${STAMP}"

# CI restores a cached profiler build when nothing that affects it changed.
if [ "$STAGE" = "profiler" ] && [ "${USE_CACHED_PROFILER:-false}" = "true" ]; then
	verify_cached_profiler
	IMAGE="$PROFILER_CACHE_DIR/$DEVICE/$KERNEL_IMAGE_NAME"
	package_anykernel "$IMAGE" "$DIST_DIR/$ARTIFACT_BASE.zip" "$PROFILER_NOTE"
	cp -f "$PROFILER_CACHE_DIR/$DEVICE/provenance.env" "$DIST_DIR/$ARTIFACT_BASE.provenance"
	step "Done (cached profiler)"
	ls -la "$DIST_DIR" | tail -n +2
	exit 0
fi

fetch_kernel
apply_spe_patch
download_ksu
download_nomount
gen_config
assert_config
build_kernel

IMAGE="$KERNEL_DIR/out/arch/$KERNEL_ARCH/boot/$KERNEL_IMAGE_NAME"

if [ "$STAGE" = "profiler" ]; then
	cache_profiler_outputs
	package_anykernel "$IMAGE" "$DIST_DIR/$ARTIFACT_BASE.zip" "$PROFILER_NOTE"
	cp -f "$KERNEL_DIR/out/vmlinux" "$DIST_DIR/$ARTIFACT_BASE.vmlinux"
	write_provenance "$DIST_DIR/$ARTIFACT_BASE.provenance"
else
	NOTE="AutoFDO optimized kernel ($DEVICE).

Profile: $(basename "$PROFILE")
Profile SHA-256: $(sha256sum "$PROFILE" | cut -d' ' -f1)
Kernel commit: $(git -C "$KERNEL_DIR" rev-parse HEAD 2>/dev/null || echo unknown)

This kernel is production-stage: ThinLTO + AutoFDO, no SPE, kpti stays on."
	package_anykernel "$IMAGE" "$DIST_DIR/$ARTIFACT_BASE.zip" "$NOTE"
	write_provenance "$DIST_DIR/$ARTIFACT_BASE.provenance"
fi

if [ -n "${GITHUB_ENV:-}" ]; then
	{
		echo "artifact=$ARTIFACT_BASE"
		echo "image=$IMAGE"
	} >> "$GITHUB_ENV"
fi

step "Done"
ls -la "$DIST_DIR" | tail -n +2
