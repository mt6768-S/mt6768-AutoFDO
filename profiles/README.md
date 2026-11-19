# Profiles

Collected AutoFDO profiles plus the provenance needed to rebuild against them.

## Layout

```
profiles/
├── common/                      profiles not tied to one device/batch
│   └── <name>.afdo
└── devices/
    └── <codename>/              merlin | lancelot | selene
        ├── mt6768-boot.afdo
        ├── mt6768-daily.afdo
        ├── mt6768-game.afdo
        ├── mt6768.afdo          merged profile (the one you build with)
        ├── perf-*.data          raw samples (large; see retention)
        ├── vmlinux-training     binary used for conversion
        ├── vmlinux-training.sha256
        ├── config-training      out/.config of the training build
        ├── KERNEL_COMMIT
        ├── CLANG_VERSION
        └── propeller_*          optional Propeller profiles
```

Empty directories are tracked with `.empty`.

## Rules

1. **A `.afdo` is worthless without its `vmlinux`.** `create_llvm_prof` matches
   samples by symbol and relative line offset; the profile alone does not record
   which binary produced it. Always publish the pair (or at least
   `vmlinux-training.sha256`).
2. **One merge per training batch.** `mt6768.afdo` is the merged boot+daily+game
   profile. Keep the per-workload files so the merge can be re-weighted without
   re-collecting.
3. **Record the inputs.** `KERNEL_COMMIT` = `git rev-parse HEAD` of the kernel
   tree used for the training build, `CLANG_VERSION` = first line of
   `clang --version`. If either is missing, the profile is not reproducible.
4. **Do not mix commits.** A profile from commit A applied to commit B "usually"
   works and silently loses accuracy. Put it under the commit it was trained on,
   or regenerate.
5. **Device portability.** MT6768 profiles are expected to transfer between
   `merlin`/`lancelot`/`selene` when commit + Clang + config match. The device
   directory documents where the training data came from, it does not make the
   profile device-locked.
6. **Simpleperf conversion.** `simpleperf record` produces Android simpleperf
   data, not necessarily the host `perf.data` format expected by the AutoFDO
   converter. Keep the exact `vmlinux-training` used during collection and
   inspect/convert the samples with the matching simpleperf tooling (for
   example `simpleperf report-sample` or the documented `create_llvm_prof`
   simpleperf input path) before generating `.afdo`. Do not assume that a file
   merely named `perf-*.data` is directly convertible.
7. **Sampling provenance.** Record the kernel commit, Clang version, complete
   `.config`, event, frequency, workload, and collection timestamps beside each
   batch. A profile is only meaningful when its samples match the exact
   training binary; never apply samples collected from a different build.

## Retention

- `*.afdo` — keep (a few MB, cheap).
- `vmlinux-training` — keep for as long as the profile is referenced; it is the
  only way to re-convert or debug a bad match.
- `perf-*.data` — keep until the production build is validated, then archive
  out-of-tree. These are tens to hundreds of MB and do not belong in git history.

## Naming

```
mt6768-<workload>.afdo          per-session conversion
mt6768.afdo                     merged, build input
mt6768-<workload>-<yyyymmdd>.afdo   when re-training on the same device
```
