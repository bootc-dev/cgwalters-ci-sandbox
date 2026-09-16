#!/usr/bin/env bash
set -euo pipefail

helper=${1:?path to fresh-install-state.sh}
# shellcheck disable=SC1090
source "$helper"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

check_mutation() {
    local name=$1
    local target=$tmp/$name/target
    local outside=$tmp/$name/outside
    local before=$tmp/$name/before
    local after=$tmp/$name/after
    mkdir -p "$target/boot" "$target/ostree" "$outside"
    printf '%s\n' unchanged >"$outside/tmt-state"
    printf '%s\n' before >"$target/ostree/state"
    fresh_install_snapshot "$target" >"$before"
    fresh_install_snapshot_files "$outside" >>"$before"
    printf '%s\n' changed >"$target/ostree/state"
    fresh_install_snapshot "$target" >"$after"
    fresh_install_snapshot_files "$outside" >>"$after"
    if cmp -s "$before" "$after"; then
        printf 'snapshot failed to detect %s state mutation\n' "$name" >&2
        exit 1
    fi
}

# OSTree installations do not have a state directory.
check_mutation ostree

# Composefs installations do have state, and it is included when present.
name=composefs
target=$tmp/$name/target
outside=$tmp/$name/outside
before=$tmp/$name/before
after=$tmp/$name/after
mkdir -p "$target/boot" "$target/state" "$target/composefs" "$outside"
printf '%s\n' before >"$target/state/deployment"
printf '%s\n' unchanged >"$outside/tmt-state"
fresh_install_snapshot "$target" >"$before"
fresh_install_snapshot_files "$outside" >>"$before"
printf '%s\n' changed >"$target/state/deployment"
fresh_install_snapshot "$target" >"$after"
fresh_install_snapshot_files "$outside" >>"$after"
if cmp -s "$before" "$after"; then
    printf 'snapshot failed to detect composefs state mutation\n' >&2
    exit 1
fi

# Files outside the target are part of the regression boundary too.
fresh_install_snapshot "$target" >"$before"
fresh_install_snapshot_files "$outside" >>"$before"
printf '%s\n' changed >"$outside/tmt-state"
fresh_install_snapshot "$target" >"$after"
fresh_install_snapshot_files "$outside" >>"$after"
if cmp -s "$before" "$after"; then
    printf 'snapshot failed to detect outside-target mutation\n' >&2
    exit 1
fi

# Invalid fixtures fail explicitly instead of turning a missing tree into an
# empty snapshot.
if fresh_install_snapshot "$tmp/missing" 2>"$tmp/error"; then
    exit 1
fi
grep -F 'not a directory' "$tmp/error" >/dev/null

# The production mapping must preserve /var/tmp/tmt as target /var/tmp/tmt,
# rather than inventing a sibling workdir name.
source_var=$tmp/source-var
target_var=$tmp/target-var
mkdir -p "$source_var/lib/tmt" "$source_var/tmp/tmt"
printf '%s\n' lib >"$source_var/lib/tmt/file"
printf '%s\n' tmp >"$source_var/tmp/tmt/file"
fresh_install_preserve_tmt_state "$target_var" "$source_var"
test -f "$target_var/lib/tmt/file"
test -f "$target_var/tmp/tmt/file"
test ! -e "$target_var/tmt-workdir"

# Logical-image extraction selects the documented snake_case field, rejects an
# empty selection, and does not hide malformed JSON errors from its caller.
images_json=$tmp/images.json
images_list=$tmp/images.list
printf '%s\n' '[{"image":"example.invalid/lbi:latest","image_type":"logical"},{"image":"localhost/bootc","image_type":"unified"}]' >"$images_json"
fresh_install_lbi_image_list "$images_json" "$images_list"
test "$(cat "$images_list")" = example.invalid/lbi:latest

printf '%s\n' '[{"image":"localhost/bootc","image_type":"unified"}]' >"$images_json"
if fresh_install_lbi_image_list "$images_json" "$images_list" 2>"$tmp/error"; then
    exit 1
fi
grep -F 'no logical images' "$tmp/error" >/dev/null

printf '%s\n' '{not json' >"$images_json"
if fresh_install_lbi_image_list "$images_json" "$images_list" 2>"$tmp/error"; then
    exit 1
fi
grep -F 'parse error' "$tmp/error" >/dev/null

# Stored-LBI errors vary by storage driver and declaration iteration order.
# The production matcher accepts those variations, but rejects failures that
# happen to mention an image while actually reporting a network, UKI, or disk
# problem.
lbi_images=$tmp/lbi-images
lbi_log=$tmp/lbi.log
printf '%s\n' quay.io/curl/curl:latest quay.io/curl/curl-base:latest >"$lbi_images"
printf '%s\n' '[overlay@/var/lib/containers/storage]quay.io/curl/curl-base:latest does not resolve to an image ID' >"$lbi_log"
fresh_install_lbi_missing_image_error "$lbi_log" "$lbi_images"
printf '%s\n' 'quay.io/curl/curl:latest does not resolve to an image ID' >"$lbi_log"
fresh_install_lbi_missing_image_error "$lbi_log" "$lbi_images"

for error in \
    'Fetching bound image: quay.io/curl/curl:latest does not resolve to an image ID' \
    'network unavailable: quay.io/curl/curl:latest does not resolve to an image ID' \
    'UKI generation failed for quay.io/curl/curl:latest does not resolve to an image ID' \
    'disk error for quay.io/curl/curl:latest does not resolve to an image ID'; do
    printf '%s\n' "$error" >"$lbi_log"
    if fresh_install_lbi_missing_image_error "$lbi_log" "$lbi_images" 2>"$tmp/error"; then
        exit 1
    fi
    grep -F 'non-local-resolution failure' "$tmp/error" >/dev/null
done

# Exercise the production label helper with a command mock: it compares both
# required paths and requires the post-write label stamp.
label_base=$tmp/label-base
label_target=$tmp/label-target
mkdir -p "$label_base/overlay-images" "$label_target/overlay-images"
touch "$label_target/.bootc_labeled"
getfattr() {
    case "${4:?path}" in
        *label-target-bad*) printf '%s' 'system_u:object_r:default_t:s0' ;;
        *) printf '%s' 'system_u:object_r:container_file_t:s0' ;;
    esac
}
fresh_install_lbi_assert_storage_labels "$label_base" "$label_target"
label_target_bad=$tmp/label-target-bad
mkdir -p "$label_target_bad/overlay-images"
touch "$label_target_bad/.bootc_labeled"
if fresh_install_lbi_assert_storage_labels "$label_base" "$label_target_bad"; then
    exit 1
fi

# The SELinux mount is opt-in and has exactly the guest-local rw bind required
# by libselinux.  In particular, no relabel (`:z`/`:Z`) option is added.
selinux_args=(unexpected)
fresh_install_lbi_selinux_mount_args 0 selinux_args
test "${#selinux_args[@]}" = 0
fresh_install_lbi_selinux_mount_args 1 selinux_args
test "${#selinux_args[@]}" = 2
test "${selinux_args[0]}" = -v
test "${selinux_args[1]}" = /sys/fs/selinux:/sys/fs/selinux:rw
