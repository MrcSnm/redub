#!/usr/bin/env bash
# Regression tests for the audit findings. Each test asserts the correct
# behavior, so a FAIL means the bug is still there.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 2

if [ -n "${REDUB:-}" ]; then
    :
elif [ -x build/redub.exe ]; then
    REDUB="$ROOT/build/redub.exe"
elif [ -x build/redub ]; then
    REDUB="$ROOT/build/redub"
elif command -v redub >/dev/null 2>&1; then
    REDUB="$(command -v redub)"
else
    echo "redub binary not found. Build it or set REDUB=/path/to/redub"
    exit 2
fi

WINDOWS=0
EXE=""
if command -v cmd.exe >/dev/null 2>&1 || uname -s 2>/dev/null | grep -qiE 'mingw|msys|cygwin'; then
    WINDOWS=1
    EXE=".exe"
fi

if command -v timeout >/dev/null 2>&1; then
    HAVE_TIMEOUT=1
    run_limited() { local secs=$1; shift; timeout "$secs" "$@"; }
else
    HAVE_TIMEOUT=0
    run_limited() { shift; "$@"; }
fi

mkdir -p build
WORK="$(mktemp -d "$ROOT/build/regression.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

SUFFIX=$$
PASSED=0
SKIPPED=0
FAILED=0
FAILED_NAMES=()

pass()  { PASSED=$((PASSED + 1));  printf 'PASS  %s\n' "$1"; }
skip()  { SKIPPED=$((SKIPPED + 1)); printf 'SKIP  %s: %s\n' "$1" "$2"; }
fail()  { FAILED=$((FAILED + 1)); FAILED_NAMES+=("$1"); printf 'FAIL  %s: %s\n' "$1" "$2"; }
detail(){ tr '\n' ' ' < "$1" | cut -c1-240; }

redub_in() {
    local dir=$1 secs=$2 log=$3
    shift 3
    ( cd "$dir" && run_limited "$secs" "$REDUB" "$@" ) >"$log" 2>&1
}

artifact() {
    local dir=$1 name=$2
    if [ -f "$dir/build/$name.exe" ]; then
        echo "$dir/build/$name.exe"
    elif [ -f "$dir/build/$name" ]; then
        echo "$dir/build/$name"
    fi
}

winpath() {
    if command -v wslpath >/dev/null 2>&1; then
        wslpath -w "$1"
    elif command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$1"
    else
        echo "$1"
    fi
}

redub_with_dub_home() {
    local dir=$1 home=$2 log=$3
    shift 3
    if [ "$WINDOWS" -eq 1 ]; then
        local wdir whome wredub bat
        wdir="$(winpath "$dir")"
        whome="$(winpath "$home")"
        wredub="$(winpath "$REDUB")"
        bat="$dir/run_redub.bat"
        printf '@echo off\r\nset "DUB_HOME=%s"\r\ncd /d "%s"\r\n"%s" %s\r\n' \
            "$whome" "$wdir" "$wredub" "$*" > "$bat"
        cmd.exe /c "$(winpath "$bat")" >"$log" 2>&1
    else
        ( cd "$dir" && DUB_HOME="$home" "$REDUB" "$@" ) >"$log" 2>&1
    fi
}

test_cache_custom_source_paths()
{
    local name="cachetest$SUFFIX"
    local d="$WORK/cache"
    local log="$WORK/cache.log"
    mkdir -p "$d/src" "$d/third_party"
    printf '%s\n' '{"name":"'"$name"'","sourcePaths":["src"],"importPaths":["third_party"],"targetPath":"build"}' > "$d/dub.json"
    printf '%s\n' 'import std.stdio; void main(){writeln("v1");}' > "$d/src/main.d"
    printf '%s\n' 'module dummy;' > "$d/third_party/dummy.d"

    if ! redub_in "$d" 120 "$log" build --force; then
        fail cache_custom_source_paths "first build failed: $(detail "$log")"
        return
    fi

    local exe
    exe="$(artifact "$d" "$name")"
    if [ -z "$exe" ]; then
        fail cache_custom_source_paths "artifact not found"
        return
    fi
    chmod +x "$exe" 2>/dev/null || true
    local first
    first="$("$exe" 2>&1 | tr -d '\r')"
    if [ "$first" != "v1" ]; then
        fail cache_custom_source_paths "first build printed '$first', expected 'v1'"
        return
    fi

    printf '%s\n' 'import std.stdio; void main(){writeln("v2");}' > "$d/src/main.d"
    if ! redub_in "$d" 120 "$log" build; then
        fail cache_custom_source_paths "second build failed: $(detail "$log")"
        return
    fi

    local second
    second="$("$exe" 2>&1 | tr -d '\r')"
    if [ "$second" = "v2" ]; then
        pass cache_custom_source_paths
    else
        fail cache_custom_source_paths "edited source was ignored; binary still prints '$second' ($(detail "$log"))"
    fi
}

test_test_command_forwards_args()
{
    local name="testargs$SUFFIX"
    local d="$WORK/testargs"
    local log="$WORK/testargs.log"
    mkdir -p "$d/source"
    printf '%s\n' '{"name":"'"$name"'","targetPath":"build"}' > "$d/dub.json"
    cat > "$d/source/app.d" <<'D'
import std.stdio;
void main(string[] args)
{
    foreach (a; args)
        if (a == "--filter=bar")
        {
            writeln("GOT_FILTER");
            return;
        }
    writeln("NO_FILTER");
}
D

    redub_in "$d" 120 "$log" test -- --filter=bar
    if grep -q 'GOT_FILTER' "$log"; then
        pass test_test_command_forwards_args
    else
        fail test_test_command_forwards_args "the test binary did not receive --filter=bar ($(detail "$log"))"
    fi
}

test_config_platform_crash()
{
    local name="cfgtest$SUFFIX"
    local d="$WORK/config"
    local log="$WORK/config.log"
    mkdir -p "$d/source"
    cat > "$d/dub.json" <<JSON
{"name":"$name","targetPath":"build","configurations":[
  {"name":"mac","platforms":["osx"],"sourcePaths":["source"]},
  {"name":"unittest","sourcePaths":["source"]}
]}
JSON
    printf '%s\n' 'void main(){}' > "$d/source/app.d"

    redub_in "$d" 120 "$log" build --config mac
    local status=$?
    if grep -qE 'ArrayIndexError|out of bounds' "$log"; then
        fail config_platform_crash "crashed instead of reporting an incompatible configuration ($(detail "$log"))"
    elif [ "$status" -eq 0 ]; then
        fail config_platform_crash "built a configuration that does not match the platform"
    else
        pass config_platform_crash
    fi
}

test_copy_files_no_match()
{
    local name="globtest$SUFFIX"
    local d="$WORK/glob"
    local log="$WORK/glob.log"
    mkdir -p "$d/source" "$d/assets"
    printf '%s\n' '{"name":"'"$name"'","targetPath":"build","copyFiles":["assets/*.png"]}' > "$d/dub.json"
    printf '%s\n' 'void main(){}' > "$d/source/app.d"
    printf 'x' > "$d/assets/readme.txt"

    if [ "$HAVE_TIMEOUT" -eq 0 ]; then
        skip copy_files_no_match "timeout command not available"
        return
    fi

    redub_in "$d" 20 "$log" build
    local status=$?
    if [ "$status" -eq 124 ]; then
        fail copy_files_no_match "build hung when copyFiles glob matched no files"
    elif [ "$status" -eq 0 ]; then
        pass copy_files_no_match
    else
        fail copy_files_no_match "build failed with status $status ($(detail "$log"))"
    fi
}

test_unused_key_warning()
{
    local name="unusedtest$SUFFIX"
    local d="$WORK/unused"
    local log="$WORK/unused.log"
    mkdir -p "$d/source"
    printf '%s\n' '{"name":"'"$name"'","targetPath":"build","sourcePath":["source"]}' > "$d/dub.json"
    printf '%s\n' 'void main(){}' > "$d/source/app.d"

    redub_in "$d" 120 "$log" build --force
    if grep -qiE 'unused keys|sourcePath' "$log"; then
        pass unused_key_warning
    else
        fail unused_key_warning "typo 'sourcePath' was silently ignored ($(detail "$log"))"
    fi
}

test_zip_slip()
{
    local out="$ROOT/build/zip_slip_test$EXE"
    local src="tests/regression/unit/zip_slip.d"
    local utils="package_suppliers/source/redub/libs/package_suppliers/utils.d"
    rm -f "$out"

    if command -v dmd >/dev/null 2>&1; then
        dmd -Ipackage_suppliers/source -of="$out" "$src" "$utils" >"$WORK/zip_build.log" 2>&1
    elif command -v ldc2 >/dev/null 2>&1; then
        ldc2 -I=package_suppliers/source -of="$out" "$src" "$utils" >"$WORK/zip_build.log" 2>&1
    elif [ "$WINDOWS" -eq 1 ] && cmd.exe /c "where dmd >nul 2>nul" >/dev/null 2>&1; then
        cmd.exe /c "dmd -Ipackage_suppliers\\source -of=build\\zip_slip_test.exe tests\\regression\\unit\\zip_slip.d package_suppliers\\source\\redub\\libs\\package_suppliers\\utils.d" >"$WORK/zip_build.log" 2>&1
    else
        skip zip_slip "no D compiler found"
        return
    fi

    if [ ! -f "$out" ]; then
        fail zip_slip "could not compile the unit test: $(detail "$WORK/zip_build.log")"
        return
    fi

    chmod +x "$out" 2>/dev/null || true
    "$out" >"$WORK/zip_run.log" 2>&1
    if [ $? -eq 0 ]; then
        pass zip_slip
    else
        fail zip_slip "$(detail "$WORK/zip_run.log")"
    fi
}

test_parallel_with_dependency_commands()
{
    local rootname="parroot$SUFFIX"
    local depname="dep$SUFFIX"
    local d="$WORK/parallel"
    local log="$WORK/parallel.log"
    mkdir -p "$d/source" "$d/dep/source"
    printf '%s\n' '{"name":"'"$rootname"'","targetPath":"build","dependencies":{"'"$depname"'":{"path":"dep"}}}' > "$d/dub.json"
    printf '%s\n' 'import '"$depname"'; void main(){foo();}' > "$d/source/app.d"
    printf '%s\n' '{"name":"'"$depname"'","targetPath":"build","preBuildCommands":["echo prebuild"]}' > "$d/dep/dub.json"
    printf '%s\n' 'module '"$depname"'; void foo(){}' > "$d/dep/source/dep.d"

    redub_in "$d" 120 "$log" build --force -v
    if grep -q 'full parallel' "$log"; then
        fail parallel_with_dependency_commands "auto picked full parallel although a dependency has preBuildCommands ($(grep 'Resolved:' "$log" | head -1))"
    else
        pass parallel_with_dependency_commands
    fi
}

test_assume_compiler_version()
{
    local name="assumetest$SUFFIX"
    local d="$WORK/assume"
    local log="$WORK/assume.log"
    mkdir -p "$d/source"
    printf '%s\n' '{"name":"'"$name"'","targetPath":"build"}' > "$d/dub.json"
    printf '%s\n' 'void main(){}' > "$d/source/app.d"

    local dc assumption
    if command -v dmd >/dev/null 2>&1 || { [ "$WINDOWS" -eq 1 ] && cmd.exe /c "where dmd >nul 2>nul" >/dev/null 2>&1; }; then
        dc=dmd
        assumption='dmd v[9.9.9] f[9.9.9]'
    elif command -v ldc2 >/dev/null 2>&1 || { [ "$WINDOWS" -eq 1 ] && cmd.exe /c "where ldc2 >nul 2>nul" >/dev/null 2>&1; }; then
        dc=ldc2
        assumption='ldc2 v[9.9.9] f[9.9.9]'
    else
        skip assume_compiler_version "no D compiler found"
        return
    fi

    redub_in "$d" 120 "$log" build --force --compiler="$dc" --assume-compiler "$assumption" -v
    if grep -q '9\.9\.9' "$log"; then
        pass assume_compiler_version
    else
        fail assume_compiler_version "the assumed version was ignored ($(grep 'Resolved:' "$log" | head -1))"
    fi
}

test_single_file_without_name()
{
    local name="hello$SUFFIX"
    local d="$WORK/single"
    local log="$WORK/single.log"
    mkdir -p "$d"
    cat > "$d/$name.d" <<'D'
/+ dub.json:
{
    "targetPath": "build"
}
+/
import std.stdio;
void main() { writeln("single"); }
D

    redub_in "$d" 120 "$log" build --single "$name.d"
    local status=$?
    if [ "$status" -eq 0 ]; then
        pass single_file_without_name
    else
        fail single_file_without_name "single-file recipe without a name was rejected ($(detail "$log"))"
    fi
}

test_target_name_environment()
{
    local name="appname$SUFFIX"
    local target="myapp$SUFFIX"
    local d="$WORK/envname"
    local log="$WORK/envname.log"
    mkdir -p "$d/source"
    printf '%s\n' '{"name":"'"$name"'","targetName":"'"$target"'","targetPath":"build","postBuildCommands":["echo DUB_TARGET_NAME=$DUB_TARGET_NAME"]}' > "$d/dub.json"
    printf '%s\n' 'void main(){}' > "$d/source/app.d"

    redub_in "$d" 120 "$log" build --force
    if grep -q "DUB_TARGET_NAME=$target" "$log"; then
        pass target_name_environment
    else
        fail target_name_environment "DUB_TARGET_NAME is not the targetName ($(grep 'DUB_TARGET_NAME' "$log" | head -1))"
    fi
}

test_environment_cycle()
{
    local name="envcycle$SUFFIX"
    local d="$WORK/envcycle"
    local log="$WORK/envcycle.log"
    mkdir -p "$d/source"
    printf '%s\n' '{"name":"'"$name"'","targetPath":"build","environments":{"A":"$A"},"dflags":["-version=FOO$A"]}' > "$d/dub.json"
    printf '%s\n' 'void main(){}' > "$d/source/app.d"

    if [ "$HAVE_TIMEOUT" -eq 0 ]; then
        skip environment_cycle "timeout command not available"
        return
    fi

    redub_in "$d" 10 "$log" build
    local status=$?
    if [ "$status" -eq 124 ]; then
        fail environment_cycle "environment variable A=\$A made redub hang"
    else
        pass environment_cycle
    fi
}

test_posix_native_link_flags()
{
    local name="linktest$SUFFIX"
    local d="$WORK/link"
    local log="$WORK/link.log"
    mkdir -p "$d/source"
    printf '%s\n' '{"name":"'"$name"'","language":"C","targetType":"executable","libs":["m"],"targetPath":"build"}' > "$d/dub.json"
    cat > "$d/source/main.c" <<'C'
#include <math.h>
int main(void) { return (int)sqrt(4.0) - 2; }
C

    if [ "$WINDOWS" -eq 1 ]; then
        skip posix_native_link_flags "Windows host; the bug is in the POSIX link command"
        return
    fi
    if ! command -v gcc >/dev/null 2>&1; then
        skip posix_native_link_flags "gcc not found"
        return
    fi

    redub_in "$d" 120 "$log" build --force --c-compiler=gcc -v
    local status=$?
    if [ "$status" -ne 0 ]; then
        fail posix_native_link_flags "C build failed; inspect the link command ($(detail "$log"))"
    elif grep -q -- '-L-lm' "$log"; then
        fail posix_native_link_flags "link command used DMD's -L prefix in a native gcc link ($(grep -- '-L-lm' "$log" | head -1))"
    else
        pass posix_native_link_flags
    fi
}

test_parallel_environment()
{
    local name="parcheck$SUFFIX"
    local d="$WORK/parenv"
    local log="$WORK/parenv.log"
    mkdir -p "$d/source"
    printf '%s\n' '{"name":"'"$name"'","targetPath":"build","postBuildCommands":["echo DUB_PARALLEL_BUILD=$DUB_PARALLEL_BUILD"]}' > "$d/dub.json"
    printf '%s\n' 'void main(){}' > "$d/source/app.d"

    redub_in "$d" 120 "$log" build --force
    if grep -q 'DUB_PARALLEL_BUILD=TRUE' "$log"; then
        pass parallel_environment
    else
        fail parallel_environment "DUB_PARALLEL_BUILD was not TRUE for an enabled parallel build ($(detail "$log"))"
    fi
}

test_platform_filter_typo()
{
    local name="cfgtpy$SUFFIX"
    local d="$WORK/cfgtypo"
    local log="$WORK/cfgtypo.log"
    mkdir -p "$d/source"
    printf '%s\n' '{"name":"'"$name"'","targetPath":"build","configurations":[{"name":"typo","platforms":["window"],"sourcePaths":["source"]},{"name":"unittest","sourcePaths":["source"]}]}' > "$d/dub.json"
    printf '%s\n' 'void main(){}' > "$d/source/app.d"

    redub_in "$d" 120 "$log" build --config typo
    local status=$?
    if grep -qE 'ArrayIndexError|out of bounds' "$log"; then
        fail platform_filter_typo "crashed instead of reporting the incompatible configuration ($(detail "$log"))"
    elif [ "$status" -eq 0 ]; then
        fail platform_filter_typo "a typo in 'platforms' selected the configuration anyway"
    elif grep -qiE "incompatible|wasn't found" "$log"; then
        pass platform_filter_typo
    else
        fail platform_filter_typo "unexpected error: $(detail "$log")"
    fi
}

test_find_executable_skips_directory()
{
    local name="pathtest$SUFFIX"
    local d="$WORK/findexec"
    local log="$WORK/findexec.log"
    mkdir -p "$d/bin" "$d/proj/source"
    if [ "$WINDOWS" -eq 1 ]; then
        mkdir -p "$d/bin/dmd.exe"
    else
        mkdir -p "$d/bin/dmd"
    fi
    printf '%s\n' '{"name":"'"$name"'","targetPath":"build"}' > "$d/proj/dub.json"
    printf '%s\n' 'void main(){}' > "$d/proj/source/app.d"

    ( cd "$d/proj" && PATH="$d/bin:$PATH" run_limited 120 "$REDUB" build --force ) >"$log" 2>&1
    if [ "$?" -eq 0 ]; then
        pass find_executable_skips_directory
    else
        fail find_executable_skips_directory "a directory named like the compiler broke PATH lookup ($(detail "$log"))"
    fi
}

test_compiler_semver_range()
{
    local name="compver$SUFFIX"
    local d="$WORK/compver"
    local log="$WORK/compver.log"
    mkdir -p "$d/source"
    printf '%s\n' '{"name":"'"$name"'","targetPath":"build"}' > "$d/dub.json"
    printf '%s\n' 'void main(){}' > "$d/source/app.d"

    local dc req
    if command -v dmd >/dev/null 2>&1 || { [ "$WINDOWS" -eq 1 ] && cmd.exe /c "where dmd >nul 2>nul" >/dev/null 2>&1; }; then
        dc=dmd
        req='~>2.0'
    elif command -v ldc2 >/dev/null 2>&1 || { [ "$WINDOWS" -eq 1 ] && cmd.exe /c "where ldc2 >nul 2>nul" >/dev/null 2>&1; }; then
        dc=ldc2
        req='~>1.0'
    else
        skip compiler_semver_range "no D compiler found"
        return
    fi

    redub_in "$d" 120 "$log" build --force --compiler="$dc@$req"
    if [ "$?" -eq 0 ]; then
        pass compiler_semver_range
    else
        fail compiler_semver_range "a semver range in --compiler was rejected ($(detail "$log"))"
    fi
}

test_root_target_name_environment()
{
    local name="rootname$SUFFIX"
    local target="myroot$SUFFIX"
    local d="$WORK/rootname"
    local log="$WORK/rootname.log"
    mkdir -p "$d/source"
    printf '%s\n' '{"name":"'"$name"'","targetName":"'"$target"'","targetPath":"build","postBuildCommands":["echo DUB_ROOT_PACKAGE_TARGET_NAME=$DUB_ROOT_PACKAGE_TARGET_NAME"]}' > "$d/dub.json"
    printf '%s\n' 'void main(){}' > "$d/source/app.d"

    redub_in "$d" 120 "$log" build --force
    if grep -q "DUB_ROOT_PACKAGE_TARGET_NAME=$target" "$log"; then
        pass root_target_name_environment
    else
        fail root_target_name_environment "DUB_ROOT_PACKAGE_TARGET_NAME is not the root targetName ($(grep 'DUB_ROOT_PACKAGE_TARGET_NAME' "$log" | head -1))"
    fi
}

test_parallel_leaves_up_to_date()
{
    local name="leaves$SUFFIX"
    local d="$WORK/leaves"
    local log="$WORK/leaves.log"
    mkdir -p "$d/source"
    printf '%s\n' '{"name":"'"$name"'","targetPath":"build"}' > "$d/dub.json"
    printf '%s\n' 'void main(){}' > "$d/source/app.d"

    if ! redub_in "$d" 120 "$log" build --force; then
        fail parallel_leaves_up_to_date "setup build failed: $(detail "$log")"
        return
    fi

    redub_in "$d" 20 "$WORK/leaves2.log" build --parallel=leaves
    local status=$?
    if [ "$status" -eq 124 ]; then
        fail parallel_leaves_up_to_date "build hung on an up-to-date project with --parallel=leaves"
    elif [ "$status" -eq 0 ]; then
        pass parallel_leaves_up_to_date
    else
        fail parallel_leaves_up_to_date "exit $status with no useful output ($(detail "$WORK/leaves2.log"))"
    fi
}

test_meta_package_with_dependencies()
{
    local rootname="metaroot$SUFFIX"
    local metaname="meta$SUFFIX"
    local realname="real$SUFFIX"
    local d="$WORK/meta"
    local log="$WORK/meta.log"
    mkdir -p "$d/source" "$d/meta" "$d/real/source"
    printf '%s\n' '{"name":"'"$rootname"'","targetPath":"build","dependencies":{"'"$metaname"'":{"path":"meta"}}}' > "$d/dub.json"
    printf '%s\n' 'void main(){}' > "$d/source/app.d"
    printf '%s\n' '{"name":"'"$metaname"'","targetType":"none","dependencies":{"'"$realname"'":{"path":"../real"}}}' > "$d/meta/dub.json"
    printf '%s\n' '{"name":"'"$realname"'","targetPath":"build"}' > "$d/real/dub.json"
    printf '%s\n' 'module '"$realname"'; void foo(){}' > "$d/real/source/$realname.d"

    redub_in "$d" 120 "$log" build --force
    local status=$?
    if grep -q "can't be independent when having dependencies" "$log"; then
        fail meta_package_with_dependencies "meta package with dependencies crashed the build ($(detail "$log"))"
    elif [ "$status" -eq 0 ]; then
        pass meta_package_with_dependencies
    else
        fail meta_package_with_dependencies "exit $status: $(detail "$log")"
    fi
}

test_missing_source_path()
{
    local rootname="missroot$SUFFIX"
    local depname="missdep$SUFFIX"
    local d="$WORK/missing"
    local log="$WORK/missing.log"
    mkdir -p "$d/source" "$d/dep"
    printf '%s\n' '{"name":"'"$rootname"'","targetPath":"build","dependencies":{"'"$depname"'":{"path":"dep"}}}' > "$d/dub.json"
    printf '%s\n' 'void main(){}' > "$d/source/app.d"
    printf '%s\n' '{"name":"'"$depname"'","targetPath":"build","sourcePaths":["generated"]}' > "$d/dep/dub.json"

    redub_in "$d" 120 "$log" build --force
    local status=$?
    if grep -q "Internal Error" "$log"; then
        fail missing_source_path "missing sourcePaths produced an internal error ($(detail "$log"))"
    elif [ "$status" -eq 0 ]; then
        pass missing_source_path
    else
        fail missing_source_path "exit $status: $(detail "$log")"
    fi
}

test_breadth_empty_directory()
{
    local name="breadth$SUFFIX"
    local d="$WORK/breadth"
    local log="$WORK/breadth.log"
    mkdir -p "$d/source/empty"
    printf '%s\n' '{"name":"'"$name"'","targetPath":"build"}' > "$d/dub.json"
    printf '%s\n' 'void main(){}' > "$d/source/app.d"

    redub_in "$d" 120 "$log" build --force --breadth
    local status=$?
    if [ "$status" -eq 0 ]; then
        pass breadth_empty_directory
    else
        fail breadth_empty_directory "exit $status on a source tree with an empty subdirectory ($(detail "$log"))"
    fi
}

test_source_paths_prefix_collision()
{
    local name="prefix$SUFFIX"
    local d="$WORK/prefix"
    local log="$WORK/prefix.log"
    mkdir -p "$d/source" "$d/source_extra"
    printf '%s\n' '{"name":"'"$name"'","targetPath":"build","sourcePaths":["source","source_extra"]}' > "$d/dub.json"
    printf '%s\n' 'void main(){}' > "$d/source/app.d"
    printf '%s\n' 'module extra; void extra(){}' > "$d/source_extra/extra.d"

    redub_in "$d" 120 "$log" build --force
    local exe
    exe="$(artifact "$d" "$name")"
    if [ -n "$exe" ]; then
        pass source_paths_prefix_collision
    else
        fail source_paths_prefix_collision "the valid 'source' directory was pruned by 'source_extra' ($(detail "$log"))"
    fi
}

test_amd64_platform_filter()
{
    local name="amd$SUFFIX"
    local d="$WORK/amd"
    local log="$WORK/amd.log"
    local arch
    arch="$(uname -m 2>/dev/null || true)"
    if [ "$arch" != "x86_64" ] && [ "$arch" != "amd64" ]; then
        skip amd64_platform_filter "host is not x86_64 ($arch)"
        return
    fi
    mkdir -p "$d/source"
    printf '%s\n' '{"name":"'"$name"'","targetPath":"build","configurations":[{"name":"amd","platforms":["amd64"],"sourcePaths":["source"]}]}' > "$d/dub.json"
    printf '%s\n' 'void main(){}' > "$d/source/app.d"

    redub_in "$d" 120 "$log" build --force --config amd
    local status=$?
    if grep -q "No appropriate switch clause found for architecture" "$log"; then
        fail amd64_platform_filter "valid amd64 filter threw ($(detail "$log"))"
    elif [ "$status" -eq 0 ]; then
        pass amd64_platform_filter
    else
        fail amd64_platform_filter "exit $status: $(detail "$log")"
    fi
}

test_project_without_name()
{
    local d="$WORK/noname"
    local log="$WORK/noname.log"
    mkdir -p "$d/source"
    printf '%s\n' '{"targetPath":"build"}' > "$d/dub.json"
    printf '%s\n' 'void main(){}' > "$d/source/app.d"

    redub_in "$d" 120 "$log" build --force
    if grep -qi "must contain a 'name'" "$log"; then
        pass project_without_name
    else
        fail project_without_name "missing 'name' did not produce a clear error ($(detail "$log"))"
    fi
}

test_posix_c_dynamic_library()
{
    if [ "$WINDOWS" -eq 1 ] || [ "$(uname -s 2>/dev/null)" != "Linux" ]; then
        skip posix_c_dynamic_library "requires a Linux host"
        return
    fi
    if ! command -v gcc >/dev/null 2>&1; then
        skip posix_c_dynamic_library "gcc not found"
        return
    fi
    local name="cdyn$SUFFIX"
    local d="$WORK/cdyn"
    local log="$WORK/cdyn.log"
    mkdir -p "$d/source"
    printf '%s\n' '{"name":"'"$name"'","language":"C","targetType":"dynamicLibrary","targetPath":"build"}' > "$d/dub.json"
    printf '%s\n' 'int f(void){return 1;}' > "$d/source/f.c"

    redub_in "$d" 120 "$log" build --force --c-compiler=gcc
    local status=$?
    if [ "$status" -ne 0 ]; then
        fail posix_c_dynamic_library "gcc dynamic library build failed ($(detail "$log"))"
    elif [ -z "$(find "$d/build" -maxdepth 1 -name '*.so' -print -quit 2>/dev/null)" ]; then
        fail posix_c_dynamic_library "build succeeded but produced no .so"
    else
        pass posix_c_dynamic_library
    fi
}

test_path_with_spaces()
{
    if [ "$WINDOWS" -eq 1 ] || [ "$(uname -s 2>/dev/null)" != "Linux" ]; then
        skip path_with_spaces "requires a Linux host"
        return
    fi
    if ! command -v gcc >/dev/null 2>&1; then
        skip path_with_spaces "gcc not found"
        return
    fi
    local name="spaces$SUFFIX"
    local d="$WORK/path with space"
    local log="$WORK/spaces.log"
    mkdir -p "$d/source"
    printf '%s\n' '{"name":"'"$name"'","language":"C","targetType":"executable","targetPath":"build"}' > "$d/dub.json"
    printf '%s\n' 'int main(void){return 0;}' > "$d/source/main.c"

    redub_in "$d" 120 "$log" build --force --c-compiler=gcc
    if [ "$?" -eq 0 ]; then
        pass path_with_spaces
    else
        fail path_with_spaces "a project path containing spaces failed ($(detail "$log"))"
    fi
}

test_source_paths_nested()
{
    local name="nested$SUFFIX"
    local d="$WORK/nested"
    local log="$WORK/nested.log"
    mkdir -p "$d/source/sub"
    printf '%s\n' '{"name":"'"$name"'","targetPath":"build","sourcePaths":["source","source/sub"]}' > "$d/dub.json"
    printf '%s\n' 'void main(){}' > "$d/source/app.d"
    printf '%s\n' 'module sub; void sub(){}' > "$d/source/sub/sub.d"

    redub_in "$d" 120 "$log" build --force
    local exe
    exe="$(artifact "$d" "$name")"
    if [ -n "$exe" ] && ! grep -q "Path .*source was removed" "$log"; then
        pass source_paths_nested
    else
        fail source_paths_nested "the parent 'source' was removed instead of the nested 'source/sub' ($(detail "$log"))"
    fi
}

test_mini_regex_matches()
{
    local out="$ROOT/build/mini_regex_test$EXE"
    local src="tests/regression/unit/mini_regex.d"
    local impl="source/redub/misc/mini_regex.d"
    rm -f "$out"
    if command -v dmd >/dev/null 2>&1; then
        dmd -Isource -of="$out" "$src" "$impl" >"$WORK/mini_regex_build.log" 2>&1
    elif command -v ldc2 >/dev/null 2>&1; then
        ldc2 -I=source -of="$out" "$src" "$impl" >"$WORK/mini_regex_build.log" 2>&1
    elif [ "$WINDOWS" -eq 1 ] && cmd.exe /c "where dmd >nul 2>nul" >/dev/null 2>&1; then
        cmd.exe /c "dmd -Isource -of=build\\mini_regex_test.exe tests\\regression\\unit\\mini_regex.d source\\redub\\misc\\mini_regex.d" >"$WORK/mini_regex_build.log" 2>&1
    else
        skip mini_regex_matches "no D compiler found"
        return
    fi
    if [ ! -f "$out" ]; then
        fail mini_regex_matches "could not compile unit test: $(detail "$WORK/mini_regex_build.log")"
        return
    fi
    chmod +x "$out" 2>/dev/null || true
    "$out" >"$WORK/mini_regex_run.log" 2>&1
    if [ "$?" -eq 0 ]; then
        pass mini_regex_matches
    else
        fail mini_regex_matches "$(detail "$WORK/mini_regex_run.log")"
    fi
}

test_compiler_detection_cc()
{
    if [ "$WINDOWS" -eq 1 ] || [ "$(uname -s 2>/dev/null)" != "Linux" ]; then
        skip compiler_detection_cc "requires a Linux host"
        return
    fi
    if ! command -v cc >/dev/null 2>&1; then
        skip compiler_detection_cc "cc not found"
        return
    fi
    local name="ccdetect$SUFFIX"
    local d="$WORK/ccdetect"
    local log="$WORK/ccdetect.log"
    mkdir -p "$d/source"
    printf '%s\n' '{"name":"'"$name"'","language":"C","targetType":"executable","targetPath":"build"}' > "$d/dub.json"
    printf '%s\n' 'int main(void){return 0;}' > "$d/source/main.c"

    redub_in "$d" 120 "$log" build --force --c-compiler=cc
    if [ "$?" -eq 0 ]; then
        pass compiler_detection_cc
    else
        fail compiler_detection_cc "a valid 'cc' compiler was rejected ($(detail "$log"))"
    fi
}

test_target_with_subpackage()
{
    local name="subpkg$SUFFIX"
    local d="$WORK/subpkg"
    local log="$WORK/subpkg.log"
    mkdir -p "$d/home/dub/packages" "$d/pkg/subsrc" "$d/run"
    printf '%s\n' '{"name":"'"$name"'","version":"1.0.0","subPackages":[{"name":"sub","sourcePaths":["subsrc"]}],"targets":{"t":{"targetType":"executable"}}}' > "$d/pkg/dub.json"
    printf '%s\n' 'void main(){}' > "$d/pkg/subsrc/app.d"

    local pkgpath
    if [ "$WINDOWS" -eq 1 ]; then
        pkgpath="$(winpath "$d/pkg" | sed 's/\\/\\\\/g')"
    else
        pkgpath="$d/pkg"
    fi
    printf '%s\n' '[{"name":"'"$name"'","version":"1.0.0","path":"'"$pkgpath"'"}]' > "$d/home/dub/packages/local-packages.json"

    redub_with_dub_home "$d/run" "$d/home" "$log" build "$name:sub" --target=t --force
    local status=$?
    if grep -q "must contain a subPackages property since it has a subPackage" "$log"; then
        fail target_with_subpackage "target object was parsed with the subpackage still active ($(detail "$log"))"
    elif [ "$status" -eq 0 ]; then
        pass target_with_subpackage
    else
        fail target_with_subpackage "exit $status: $(detail "$log")"
    fi
}

test_cache_custom_source_paths
test_test_command_forwards_args
test_config_platform_crash
test_copy_files_no_match
test_unused_key_warning
test_zip_slip
test_parallel_with_dependency_commands
test_assume_compiler_version
test_parallel_environment
test_platform_filter_typo
test_find_executable_skips_directory
test_compiler_semver_range
test_posix_native_link_flags
test_single_file_without_name
test_target_name_environment
test_root_target_name_environment
test_environment_cycle
test_parallel_leaves_up_to_date
test_meta_package_with_dependencies
test_missing_source_path
test_breadth_empty_directory
test_source_paths_prefix_collision
test_source_paths_nested
test_amd64_platform_filter
test_project_without_name
test_posix_c_dynamic_library
test_path_with_spaces
test_mini_regex_matches
test_compiler_detection_cc
test_target_with_subpackage

printf '\n%d passed, %d failed, %d skipped\n' "$PASSED" "$FAILED" "$SKIPPED"
if [ "$FAILED" -ne 0 ]; then
    printf 'Failed: %s\n' "${FAILED_NAMES[*]}"
    exit 1
fi
