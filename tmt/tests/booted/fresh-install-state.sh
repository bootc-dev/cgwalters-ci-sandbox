#!/usr/bin/env bash

# Keep the offline-status fixture small and explicit: image payloads are not
# part of the snapshot, but metadata changes must be visible.
fresh_install_snapshot() {
    local target=$1
    local path
    local -a paths=()

    test -d "$target" || {
        printf 'fresh-install: snapshot target is not a directory: %s\n' "$target" >&2
        return 1
    }
    test -n "$(find "$target" -mindepth 1 -maxdepth 1 -print -quit)" || {
        printf 'fresh-install: snapshot target is empty: %s\n' "$target" >&2
        return 1
    }
    for path in boot state ostree composefs; do
        test -d "$target/$path" && paths+=("$target/$path")
    done
    ((${#paths[@]} > 0)) || {
        printf 'fresh-install: no relevant state directories under %s\n' "$target" >&2
        return 1
    }

    find "${paths[@]}" -xdev \
        -printf '%y %m %u %g %s %T@ %C@ %p\n' | sort
    find "${paths[@]}" -xdev -type f -size -1M -print0 \
        | sort -z | xargs -0r sha256sum
}

# Snapshot explicitly named trees outside the installed target.  This is used
# for the guest-local tmt trees, which must not be changed by an offline query.
fresh_install_snapshot_files() {
    local path
    for path in "$@"; do
        test -e "$path" || continue
        find "$path" -xdev \
            -printf '%y %m %u %g %s %T@ %C@ %p\n'
        find "$path" -xdev -type f -size -1M -print0 \
            | sort -z | xargs -0r sha256sum
    done
}

fresh_install_preserve_tmt_state() {
    local var=$1
    local source_var=${2:-/var}
    mkdir -p "$var/lib" "$var/tmp"
    cp -a "$source_var/lib/tmt" "$var/lib/"
    cp -a "$source_var/tmp/tmt" "$var/tmp/"
}
