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
