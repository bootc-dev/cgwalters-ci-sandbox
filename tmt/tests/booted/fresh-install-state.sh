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

# Extract the logical image names from the public image-list JSON.  Keep this
# deliberately strict: an empty list would otherwise turn a bound-image test
# into a successful no-op, and jq errors must reach the caller.
fresh_install_lbi_image_list() {
    local json=$1
    local output=$2

    test -s "$json" || {
        printf 'fresh-install: image-list JSON is empty: %s\n' "$json" >&2
        return 1
    }
    jq -r '.[] | select(.image_type == "logical") | .image' "$json" >"$output"
    test -s "$output" || {
        printf 'fresh-install: no logical images in: %s\n' "$json" >&2
        return 1
    }
}

# Confirm that a stored-LBI preflight failed because one of the declared
# images is absent from local containers-storage.  Proxy diagnostics include
# the storage driver (for example, `[overlay@...]`) and declaration ordering is
# unspecified, so neither is part of this contract.
fresh_install_lbi_missing_image_error() {
    local log=$1
    local images=$2
    local image

    test -s "$log" || {
        printf 'fresh-install: missing stored-LBI diagnostic: %s\n' "$log" >&2
        return 1
    }
    grep -F 'does not resolve to an image ID' "$log" >/dev/null || {
        printf 'fresh-install: stored-LBI diagnostic lacks image-ID resolution failure\n' >&2
        return 1
    }
    if grep -Eiq 'Fetching bound image:|network|UKI|No space left|disk error' "$log"; then
        printf 'fresh-install: stored-LBI diagnostic reports a non-local-resolution failure\n' >&2
        return 1
    fi
    while IFS= read -r image; do
        if grep -F "$image" "$log" >/dev/null; then
            printf 'fresh-install: stored-LBI missing local image=%s\n' "$image"
            return 0
        fi
    done <"$images"
    printf 'fresh-install: stored-LBI diagnostic names no declared logical image\n' >&2
    return 1
}

fresh_install_selinux_type() {
    local path=$1
    local context

    test -e "$path" || {
        printf 'fresh-install: SELinux path does not exist: %s\n' "$path" >&2
        return 1
    }
    context=$(getfattr --only-values -n security.selinux "$path")
    test -n "$context" || {
        printf 'fresh-install: SELinux context is empty: %s\n' "$path" >&2
        return 1
    }
    printf '%s\n' "$context" | cut -d: -f3
}

# Check both the store root and its representative image metadata directory.
fresh_install_lbi_assert_storage_labels() {
    local base=$1
    local target=$2
    local path
    local base_type
    local target_type

    for path in . overlay-images; do
        base_type=$(fresh_install_selinux_type "$base/$path")
        target_type=$(fresh_install_selinux_type "$target/$path")
        test "$base_type" = "$target_type" || {
            printf 'fresh-install: SELinux type mismatch %s (%s != %s)\n' \
                "$path" "$base_type" "$target_type" >&2
            return 1
        }
    done
    test -f "$target/.bootc_labeled" || {
        printf 'fresh-install: missing bootc label stamp: %s/.bootc_labeled\n' "$target" >&2
        return 1
    }
}

# libselinux 3.11 treats a read-only selinuxfs mount as disabled.  The nested
# installer shares this guest's privileged mount namespace, so bind the guest
# selinuxfs read-write only for the enforcement fixture; this does not change
# policy or enforcement state.
fresh_install_lbi_selinux_mount_args() {
    local enabled=$1
    local -n args=$2

    args=()
    if test "$enabled" = 1; then
        args=(-v /sys/fs/selinux:/sys/fs/selinux:rw)
    fi
}
