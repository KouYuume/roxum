#!/usr/bin/env bash
# Writes the musl startup object and C library a Roc musl target links
# (crt1.o, libc.a) into a platform's target directory. Both come from the musl
# that Zig bundles, so they match the Zig that builds the host.
#
# Zig 0.16 reimplements part of libc in Zig (lib/zig/c.zig, "zigc") and leaves
# those functions out of its musl libc.a; a Zig executable gets them from its
# own compilation unit. A Roc app is linked by Roc, so zigc is compiled here and
# added to libc.a.
#   tools/musl-runtime.sh [--strip] <roc-target> <output-directory>
# --strip builds them without debug information (release bundles).
# Targets other than musl need no runtime files; the script does nothing.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Never empty: bash 3.2 treats an empty array as unset under `set -u`.
build_flags=(-lc)
if [[ "${1:-}" == "--strip" ]]; then
    build_flags+=(-O ReleaseSmall -fstrip)
    shift
fi
roc_target="$1"
output_dir="$2"

case "$roc_target" in
    *musl) ;;
    *) exit 0 ;;
esac

zig_target="$("$script_dir/roc-target.sh" --zig "$roc_target")"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/roxum-musl-runtime.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

printf 'pub fn main() void {}\n' > "$work_dir/empty.zig"
# The linker line of an empty libc executable names the runtime files Zig built.
link_line="$(zig build-exe "${build_flags[@]}" -target "$zig_target" --verbose-link \
    -femit-bin="$work_dir/empty" "$work_dir/empty.zig" 2>&1)"

find_input() {
    local name="$1"
    local path
    path="$(tr ' ' '\n' <<< "$link_line" | grep "/$name\$" | head -n 1)"
    if [[ -z "$path" || ! -f "$path" ]]; then
        echo "zig did not report $name for $zig_target" >&2
        exit 1
    fi
    echo "$path"
}

zig_lib_dir="$(zig env | sed -n 's/^ *\.lib_dir = "\(.*\)",$/\1/p')"
zig build-obj "${build_flags[@]}" -target "$zig_target" -O ReleaseSmall -fPIC -fno-compiler-rt \
    -femit-bin="$work_dir/zigc.o" -Mroot="$zig_lib_dir/c.zig"

mkdir -p "$output_dir"
cp "$(find_input crt1.o)" "$output_dir/crt1.o"
cp "$(find_input libc.a)" "$work_dir/libc.a"
chmod u+w "$work_dir/libc.a"
zig ar rcs "$work_dir/libc.a" "$work_dir/zigc.o"
mv "$work_dir/libc.a" "$output_dir/libc.a"
