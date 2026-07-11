#!/usr/bin/env bash
# velvet/mayhem/build.sh — build the Mayhem fuzz target `velveth` (a libFuzzer harness around velvet's
# sequence-file parser) plus the real velveth/velvetg binaries for the functional test suite.
#
# velvet is a plain C make-based project (dzerbino/velvet): velveth hashes/imports sequence files,
# velvetg builds the de Bruijn graph. The attack surface for a sequence file (FASTA/FASTQ) is the
# kseq.h reader driven by readFastXFile() in src/readSet.c.
#
# WHY A HARNESS (not the velveth driver directly): the velveth CLI does heavy, stateful filesystem
# work on a FIXED output directory per exec (opendir/mkdir/remove + an APPENDING <outdir>/Log + the
# splay-table hashing). Mayhem drives the same command thousands of times against the same outdir and
# cannot clear it between execs, so even the trivial default test case (a buffer of 'A's) tripped
# Mayhem's per-exec timeout. The harness (mayhem/fuzz_velveth.c) fuzzes the EXACT kseq parser
# in-process with no outdir, no hashing, and no global state — microseconds per exec — so the default
# test case and the seeds finish well under the timeout while the real parser is still driven.
# We keep the Mayhem target name `velveth`.
#
# zlib: velvet's Makefile links -lz by default (BUNDLEDZLIB unset), so we rely on the system
# libz (zlib1g-dev installed in the Dockerfile) rather than the bundled third-party/zlib-1.2.3.
# MAXKMERLENGTH / CATEGORIES are left at their Makefile defaults (31 / 2).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the ENV, overridable. SANITIZER_FLAGS uses `=` (not `:=`) so an explicit empty
# value (--build-arg SANITIZER_FLAGS=) is honored → no-sanitizer build (natural crash).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

# ---- 1) The Mayhem fuzz target: a libFuzzer harness named `velveth` --------------------------------
# mayhem/fuzz_velveth.c #includes src/kseq.h and drives kseq_read() over the fuzz input exactly as
# readFastXFile() in src/readSet.c does. It is sanitized AND linked with the fuzzing engine, so the
# parser is instrumented and Mayhem iterates it in-process (no outdir, no hashing, no global state).
# ASan halts on the first finding; abort_on_error=1 makes that an abort Mayhem records as a crash.
make clean >/dev/null 2>&1 || true
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE -m64 -I"$SRC/src" \
    "$SRC/mayhem/fuzz_velveth.c" -o "$SRC/velveth"
echo "build.sh: built libFuzzer target velveth at $SRC/velveth"

# ---- 2) Functional test suite: build the REAL velveth/velvetg with the project's NORMAL flags ------
# velvet's own test suite (tests/run-tests.sh) golden-diffs velveth output against committed
# Sequences.31 / Roadmaps.31 — an honest behavioral oracle. Build a clean (un-sanitized) pair of the
# real binaries under mayhem/test-bin/ so test.sh runs the project as upstream ships it. velvet's
# Makefile writes velveth/velvetg into $SRC, so move them aside afterwards to keep the fuzz target.
# `make velveth velvetg` builds exactly the two assembler binaries (skips the pdflatex `doc` target).
mkdir -p "$SRC/mayhem/test-bin"
mv -f "$SRC/velveth" "$SRC/mayhem/velveth.fuzz"   # stash the fuzz target; make would overwrite it
make -j"$MAYHEM_JOBS" velveth velvetg CC="$CC" CFLAGS="$DEBUG_FLAGS"
cp -f "$SRC/velveth" "$SRC/mayhem/test-bin/velveth"
cp -f "$SRC/velvetg" "$SRC/mayhem/test-bin/velvetg"

# ---- 3) Restore the fuzz target at $SRC/velveth (make wrote the real velveth there) ----------------
make clean >/dev/null 2>&1 || true
mv -f "$SRC/mayhem/velveth.fuzz" "$SRC/velveth"

echo "build.sh: fuzz target velveth at $SRC; clean test binaries at $SRC/mayhem/test-bin"
