#!/usr/bin/env bash
#
# mayhem/build.sh — builds the sanitized Pcap++ fuzz harnesses (+ standalone reproducers) and the
# Packet++Test oracle. See the template header in the workflow repo for the env contract.
#
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"


# 1) Sanitized + instrumented project and the in-tree fuzzers (Tests/Fuzzers, the OSS-Fuzz harness set).
#    -fsanitize=fuzzer-no-link puts SanCov on the LIBRARY (not only the harness TU), unconditionally.
mkdir -p build
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o "$SRC/build/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$SRC/build/standalone_main.o"

# Always configure from a fresh cache: a re-run whose compiler path differs from the image build's
# (ccache masquerade dir vs plain clang) makes CMake drop its cache and silently re-enable the
# network-fetching Examples. Object files are kept, so the re-run stays incremental.
rm -f build/fuzz/CMakeCache.txt build/tests/CMakeCache.txt

# UBSan's `alignment` check is relaxed (ASan + the rest of UBSan stay on and halting): Packet++ casts raw
# packet bytes to header structs (e.g. igmp_header at IgmpLayer.cpp:31), which is benign on x86 and
# would otherwise abort on nearly every packet containing that layer, even the shipped seeds.
RELAX="-fno-sanitize=alignment"
FUZZ_FLAGS="-O1 $SANITIZER_FLAGS $RELAX -fsanitize=fuzzer-no-link $DEBUG_FLAGS"
cmake -S . -B build/fuzz \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS="$FUZZ_FLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_FLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS $RELAX $DEBUG_FLAGS $SRC/build/lsan_off.o" \
    -DPCAPPP_BUILD_FUZZERS=ON -DPCAPPP_BUILD_TESTS=OFF -DPCAPPP_BUILD_EXAMPLES=OFF
cmake --build build/fuzz -j"$MAYHEM_JOBS"

FUZZERS="FuzzTarget FuzzTargetNg FuzzTargetSnoop FuzzWriter FuzzWriterNg FuzzX509"
for f in $FUZZERS; do
    cp "build/fuzz/Tests/Fuzzers/$f" "/mayhem/$f"
done

# 2) Standalone (run-once) reproducers: the same harness sources, per-binary FILE_EXT defines as in
#    Tests/Fuzzers/CMakeLists.txt, linked against all static libs the fuzz build produced.
INCS=""
for d in Common++/header Packet++/header Pcap++/header 3rdParty/EndianPortable/include; do INCS="$INCS -I$SRC/$d"; done
LIBS="$(find build/fuzz -name '*.a' | sort | tr '\n' ' ')"
standalone() {  # <name> <src> <FILE_EXT> [extra -D]
    local name="$1" src="$2" ext="$3"; shift 3
    $CXX -std=c++17 -O1 $SANITIZER_FLAGS $RELAX $DEBUG_FLAGS -w -DFILE_EXT="\"$ext\"" "$@" $INCS \
        "$SRC/Tests/Fuzzers/$src" "$SRC/build/standalone_main.o" "$SRC/build/lsan_off.o" \
        -Wl,--start-group $LIBS -Wl,--end-group -lpcap -lpthread -o "/mayhem/$name-standalone"
}
standalone FuzzTarget       FuzzTarget.cpp .pcap
standalone FuzzTargetNg     FuzzTarget.cpp .pcapng
standalone FuzzTargetSnoop  FuzzTarget.cpp .snoop
standalone FuzzWriter       FuzzWriter.cpp .pcap -DNG_WRITER
standalone FuzzWriterNg     FuzzWriter.cpp .pcapng
standalone FuzzX509         FuzzX509.cpp   .der

# 3) The project's own Packet++ test suite with NORMAL flags (no sanitizers, no DWARF pin), in a
#    separate build dir; test.sh only RUNS it.
cmake -S . -B build/tests \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS" \
    -DPCAPPP_BUILD_TESTS=ON -DPCAPPP_BUILD_PCAPPP=OFF -DPCAPPP_BUILD_EXAMPLES=OFF -DPCAPPP_BUILD_FUZZERS=OFF
cmake --build build/tests -j"$MAYHEM_JOBS" --target Packet++Test
