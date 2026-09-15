# number: 51
# extra:
#   fresh_install_disk: true
#   skip_if_ostree: true
# tmt:
#   summary: Verify native fresh install logical bound image modes
#   duration: 45m
#   environment:
#     LBI_FRESH_INSTALL_MODE: stored
#     LBI_FRESH_INSTALL_UNIFIED_STORAGE: "0"
#     LBI_FRESH_INSTALL_SELINUX: "0"
#   adjust:
#     - when: native_lbi_fresh_install != true
#       enabled: false
#       because: this retains a VM and disk for runtime coordinator approval
#
# Run this test once per mode by overriding LBI_FRESH_INSTALL_MODE with stored,
# pull, or skip.  A fresh disk can only be selected once, so a TMT environment
# parameter is less error-prone than trying to install three disks in one run.
set -Eeuo pipefail

target=/var/mnt/bootc-native-lbi-fresh
mount_target=/mnt/installed
mode=${LBI_FRESH_INSTALL_MODE:-stored}
unified_storage=${LBI_FRESH_INSTALL_UNIFIED_STORAGE:-0}
selinux_enforcing=${LBI_FRESH_INSTALL_SELINUX:-0}
state_path=/var/lib/bootc-test-lbi/install.json
source booted/fresh-install-state.sh
phase=initialization

on_error() {
    local rc=$?
    trap - ERR
    printf 'native-lbi-fresh-install: ERROR phase=%s line=%s command=%q\n' \
        "$phase" "${BASH_LINENO[0]:-$LINENO}" "$BASH_COMMAND" >&2
    exit "$rc"
}
trap on_error ERR

case "$mode" in
    stored|pull|skip) ;;
    *) printf 'native-lbi-fresh-install: invalid mode: %s\n' "$mode" >&2; exit 2 ;;
esac
case "$unified_storage" in
    0|1) ;;
    *) printf 'native-lbi-fresh-install: invalid unified-storage fixture: %s\n' "$unified_storage" >&2; exit 2 ;;
esac
case "$selinux_enforcing" in
    0|1) ;;
    *) printf 'native-lbi-fresh-install: invalid SELinux fixture: %s\n' "$selinux_enforcing" >&2; exit 2 ;;
esac

if test "${TMT_REBOOT_COUNT:-0}" != 0; then
    phase=first-boot-verification
    test -f "$state_path"
    test "$(jq -r .mode "$state_path")" = "$mode"
    if test "$(jq -r .selinux_enforcing "$state_path")" = true; then
        test "$(getenforce)" = Enforcing
        podman images >/dev/null
        fresh_install_lbi_assert_storage_labels /var/lib/containers/storage /usr/lib/bootc/storage
    fi
    expected=$(jq -r '.config_ids[]?' "$state_path")
    private_root=$(mktemp -d /var/tmp/lbi-target-root.XXXXXX)
    private_runroot=$(mktemp -d /var/tmp/lbi-target-runroot.XXXXXX)
    trap 'rm -rf "$private_root" "$private_runroot"' EXIT
    actual=
    jq -r '.images[]' "$state_path" >"$private_root/images"
    while IFS= read -r image; do
        if podman --root "$private_root" --runroot "$private_runroot" \
            --storage-opt=additionalimagestore=/usr/lib/bootc/storage image exists "$image"; then
            podman --root "$private_root" --runroot "$private_runroot" \
                --storage-opt=additionalimagestore=/usr/lib/bootc/storage \
                image inspect --format '{{.Id}}' "$image" >>"$private_root/config-ids"
        fi
    done <"$private_root/images"
    if test -f "$private_root/config-ids"; then
        actual=$(sort -u "$private_root/config-ids")
    fi
    if test "$mode" = skip; then
        test -z "$actual"
        printf '%s\n' "native-lbi-fresh-install: mode=skip target-config-ids=none"
        exit 0
    fi
    test -n "$expected"
    test "$actual" = "$expected"
    printf '%s\n' "native-lbi-fresh-install: mode=$mode target-config-ids=$actual"
    exit 0
fi

mkdir -p "$target"
if mountpoint -q "$target" || mountpoint -q "$mount_target"; then
    printf 'fresh-install test path is already mounted\n' >&2
    exit 1
fi
work=$(mktemp -d /var/tmp/bootc-native-lbi-fresh.XXXXXX)
root_mounted=false
deployment_mounted=false
cleanup() {
    local rc=$?
    set +e
    if test "$deployment_mounted" = true && mountpoint -q "$mount_target"; then
        /usr/bin/bootc install unmount "$mount_target"
    fi
    if test "$root_mounted" = true && mountpoint -q "$target"; then
        umount "$target"
    fi
    if test "$rc" = 0; then
        rm -rf "$work"
    else
        printf 'native-lbi-fresh-install: retained failure workdir=%s\n' "$work" >&2
    fi
    return "$rc"
}
trap cleanup EXIT

# Discover the actual LBI declarations, rather than duplicating a public JSON
# schema with title-cased fields or assuming that the fixture never changes.
/usr/bin/bootc image list --type logical --format json >"$work/images.json"
fresh_install_lbi_image_list "$work/images.json" "$work/images.list"
mapfile -t images <"$work/images.list"
if test "$selinux_enforcing" = 1; then
    phase=source-selinux-enforcement
    test "$(getenforce)" = Enforcing
fi

# Export the candidate OS before checking its identity or invoking an
# installer.  This is intentionally the booted system's local export; it does
# not pull a replacement candidate and it must not populate default-store LBIs.
phase=candidate-os-export
/usr/bin/bootc image copy-to-storage

# The initial installation stores the fixture LBIs under bootc storage.  Make
# OCI archives from that known-local source so stored mode can populate only
# the guest default store.  Config IDs, unlike mutable tag manifests, remain a
# useful identity check across this archive round trip.
source_root=$(mktemp -d "$work/source-root.XXXXXX")
source_runroot=$(mktemp -d "$work/source-runroot.XXXXXX")
for image in "${images[@]}"; do
    archive="$work/$(printf '%s' "$image" | sha256sum | cut -d' ' -f1).oci"
    podman --root "$source_root" --runroot "$source_runroot" \
        --storage-opt=additionalimagestore=/usr/lib/bootc/storage \
        image inspect --format '{{.Id}}' "$image" >"$archive.id"
    podman --root "$source_root" --runroot "$source_runroot" \
        --storage-opt=additionalimagestore=/usr/lib/bootc/storage \
        save --format oci-archive -o "$archive" "$image"
    printf '%s\t%s\n' "$image" "$archive" >>"$work/archives"
done

# A fresh candidate OS export has no declared LBIs in its default storage.
# Do not delete tags here: the test must neither modify unrelated guest data
# nor mask a fixture that accidentally pre-populated the source store.
for image in "${images[@]}"; do
    if podman image exists "$image"; then
        printf 'native-lbi-fresh-install: LBI unexpectedly in default store: %s\n' "$image" >&2
        exit 1
    fi
done

install=(--composefs-backend --filesystem ext4 --bound-images="$mode")
if test "$selinux_enforcing" = 0; then
    install=(--disable-selinux "${install[@]}")
fi
bootloader=$(/usr/bin/bootc status --json | jq -er '.status.booted.composefs.bootloader')
install+=(--bootloader "$bootloader")
phase=candidate-identity
candidate_version=$(/usr/bin/bootc --version)
candidate_sha=$(sha256sum /usr/bin/bootc)
candidate_id=$(podman image inspect --format '{{.Id}}' localhost/bootc)
printf '%s\n' "native-lbi-fresh-install: candidate=localhost/bootc config-id=$candidate_id version=$candidate_version sha256=$candidate_sha"
if test "$unified_storage" = 1; then
    # This is the existing, hidden install option; it exercises the source
    # pull that can leave an early image-store label stamp before LBI copying.
    install+=(--experimental-unified-storage)
fi

# The candidate is always the local test image, and the installer binary must
# be the one it exports.  The missing-stored preflight is intentionally run
# without networking and without an additional image store; pull mode uses the
# same check before it is allowed to fetch from the registry.
missing_stored_preflight() {
    phase=stored-missing-preflight
    preflight_log="$work/missing-stored.log"
    if test -n "${TMT_TEST_DATA:-}"; then
        mkdir -p "$TMT_TEST_DATA"
        preflight_log="$TMT_TEST_DATA/missing-stored.log"
    fi
    if podman run --pull=never --rm --privileged --pid=host --security-opt label=type:unconfined_t \
        --network=none \
        -v /dev:/dev -v /var:/var localhost/bootc \
        /bin/sh -ec 'test "$(command -v bootc)" = /usr/bin/bootc; bootc --version; sha256sum /usr/bin/bootc; exec bootc install to-disk "$@"' bootc-install \
        --disable-selinux --composefs-backend --filesystem ext4 --bootloader "$bootloader" \
        --bound-images=stored /dev/vdb >"$preflight_log" 2>&1; then
        printf 'native-lbi-fresh-install: stored unexpectedly succeeded without LBIs\n' >&2
        exit 1
    fi
    printf '%s\n' "native-lbi-fresh-install: stored-preflight-log=$preflight_log"
    printf '%s\n' 'native-lbi-fresh-install: stored-preflight diagnostic (last 20 lines):'
    tail -n 20 "$preflight_log"
    fresh_install_lbi_missing_image_error "$preflight_log" "$work/images.list"
    root=$(lsblk --json --paths --output PATH,LABEL,TYPE /dev/vdb | jq -er \
        '[.. | objects | select(.type? == "part" and .label? == "root") | .path] | first')
    mount "$root" "$target"
    root_mounted=true
    for path in "$target/state/deploy" "$target/boot/loader/entries"; do
        test ! -d "$path" || test -z "$(find "$path" -mindepth 1 -print -quit)"
    done
    if test -e "$target/ostree/bootc/storage"; then
        private_root=$(mktemp -d "$work/preflight-root.XXXXXX")
        private_runroot=$(mktemp -d "$work/preflight-runroot.XXXXXX")
        for image in "${images[@]}"; do
            if podman --root "$private_root" --runroot "$private_runroot" \
                --storage-opt=additionalimagestore="$target/ostree/bootc/storage" image exists "$image"; then
                printf 'native-lbi-fresh-install: failed stored preflight populated target LBI: %s\n' "$image" >&2
                exit 1
            fi
        done
    fi
    umount "$target"
    root_mounted=false
    printf '%s\n' "native-lbi-fresh-install: stored-preflight=missing-local-lbi network=none"
}

if test "$mode" = stored || test "$mode" = pull; then
    missing_stored_preflight
    # The negative preflight intentionally formatted the fresh vdb.  Delegate
    # cleanup to the product's documented block-device guard rather than
    # reproducing wipefs/rereadpt behavior in this test.
    install+=(--wipe)
fi
if test "$mode" = stored; then
    phase=stored-archive-load
    while IFS=$'\t' read -r image archive; do
        podman load -i "$archive" >/dev/null
        test "$(podman image inspect --format '{{.Id}}' "$image")" = "$(cat "$archive.id")"
    done <"$work/archives"
fi

# Pull starts from the failed local-only lookup and is the sole mode with a
# networked installer.  Skip permits a unified OS-image cache but never an LBI.
network_args=(--network=none)
network=none
if test "$mode" = pull; then
    network_args=()
    network=enabled
fi
selinux_mount_args=()
fresh_install_lbi_selinux_mount_args "$selinux_enforcing" selinux_mount_args
phase="install-$mode"
podman run --pull=never --rm --privileged --pid=host --security-opt label=type:unconfined_t \
    -e LBI_FRESH_INSTALL_SELINUX="$selinux_enforcing" "${network_args[@]}" "${selinux_mount_args[@]}" \
    -v /dev:/dev -v /var:/var localhost/bootc \
    /bin/sh -ec 'test "$(command -v bootc)" = /usr/bin/bootc; if test "$LBI_FRESH_INSTALL_SELINUX" = 1; then unset BOOTC_SETENFORCE0_FALLBACK; printf "native-lbi-fresh-install: candidate-selinux="; getenforce; test "$(getenforce)" = Enforcing; fi; bootc --version; sha256sum /usr/bin/bootc; exec bootc install to-disk "$@"' bootc-install "${install[@]}" /dev/vdb
if test "$selinux_enforcing" = 1; then
    phase=post-install-selinux-enforcement
    test "$(getenforce)" = Enforcing
fi
printf '%s\n' "native-lbi-fresh-install: mode=$mode network=$network unified-storage=$unified_storage selinux-enforcing=$selinux_enforcing"

root=$(lsblk --json --paths --output PATH,LABEL,TYPE /dev/vdb | jq -er \
    '[.. | objects | select(.type? == "part" and .label? == "root") | .path] | first')
mount "$root" "$target"
root_mounted=true
phase=offline-target-mount
mkdir -p "$mount_target"
deployment_mounted=true
/usr/bin/bootc install mount --sysroot "$target" --writable "$mount_target"
mountpoint -q "$mount_target"
test -d "$mount_target/var"
var="$mount_target/var"
deployments=("$target"/state/deploy/*)
test "${#deployments[@]}" = 1
deployment_id=$(basename "${deployments[0]}")
test "${#deployment_id}" = 128
target_store="$target/ostree/bootc/storage"
test -d "$target_store"
if test "$selinux_enforcing" = 1; then
    # `images` initializes the standard default store without pulling.  Check
    # labels only after the installer has completed all image writes and its
    # parent/root relabel pass.
    podman images >/dev/null
    fresh_install_lbi_assert_storage_labels /var/lib/containers/storage "$target_store"
fi
phase=target-store-identity
private_root=$(mktemp -d "$work/root.XXXXXX")
private_runroot=$(mktemp -d "$work/runroot.XXXXXX")
target_ids=
for image in "${images[@]}"; do
    if podman --root "$private_root" --runroot "$private_runroot" \
        --storage-opt=additionalimagestore="$target_store" image exists "$image"; then
        podman --root "$private_root" --runroot "$private_runroot" \
            --storage-opt=additionalimagestore="$target_store" \
            image inspect --format '{{.Id}}' "$image" >>"$work/target-ids"
    fi
done
if test -f "$work/target-ids"; then
    target_ids=$(sort -u "$work/target-ids")
fi
if test "$mode" = skip; then
    test -z "$target_ids"
else
    test -n "$target_ids"
fi
jq -n --arg mode "$mode" --argjson selinux_enforcing "$([ "$selinux_enforcing" = 1 ] && printf true || printf false)" --argjson images "$(jq -R . <"$work/images.list" | jq -s .)" \
    --argjson config_ids "$(printf '%s\n' "$target_ids" | jq -R 'select(length > 0)' | jq -s .)" \
    '{mode: $mode, selinux_enforcing: $selinux_enforcing, images: $images, config_ids: $config_ids}' >"$work/install.json"
install -D -m 0600 "$work/install.json" "$var/lib/bootc-test-lbi/install.json"
printf '%s\n' "native-lbi-fresh-install: target-store=$target_store target-config-ids=${target_ids:-none}"
fresh_install_preserve_tmt_state "$var"
if test -f /root/.ssh/authorized_keys; then
    install -D -m 0600 /root/.ssh/authorized_keys "$var/roothome/.ssh/authorized_keys"
fi
sync
phase=offline-target-unmount
/usr/bin/bootc install unmount "$mount_target"
deployment_mounted=false
umount "$target"
root_mounted=false
phase=request-fresh-disk-boot
printf '%s\n' "native-lbi-fresh-install: requesting fresh-disk boot mode=$mode"
tmt-reboot
