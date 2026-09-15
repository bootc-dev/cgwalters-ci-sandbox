# number: 49
# tmt:
#   summary: Test the bootc 1.16 composefs UKI bridge
#   duration: 45m
#   enabled: false
#   adjust:
#     - when: composefs_bridge == true
#       enabled: true
# extra:
#   skip_if_ostree: true
#   try_bind_storage: true

# This deliberately starts disabled.  The bridge fixtures are large and are
# supplied from the host's read-only containers-storage mount only on request.
use std assert
use tap.nu
use composefs-bridge-markers.nu *

def bridge-image [] {
    let image = ($env.BOOTC_bridge_image? | default "")
    if $image == "" {
        error make { msg: "BOOTC_bridge_image is required; run with --bridge-image and --bind-storage-ro" }
    }
    $image
}

def upgrade-image [] {
    let image = ($env.BOOTC_upgrade_image? | default "")
    if $image == "" {
        error make { msg: "BOOTC_upgrade_image is required for old-stager mode" }
    }
    $image
}

def mode [] {
    let mode = ($env.BOOTC_composefs_bridge_mode? | default "")
    if not ($mode in ["old-stager" "old-initramfs"]) {
        error make { msg: "BOOTC_composefs_bridge_mode must be old-stager or old-initramfs" }
    }
    $mode
}

# Keep selection pure so the static fixture test proves coordinator input is
# accepted before a guest path can be touched.
def select-store-layout [bridge_mode: string, layout: string, layout_is_set: bool, misspelled_is_set: bool] {
    if $misspelled_is_set {
        error make { msg: "BOOTC_composefs_bridge_store_layout is invalid; use BOOTC_bridge_store_layout" }
    }
    if $bridge_mode == "old-stager" {
        if not $layout_is_set {
            error make { msg: "BOOTC_bridge_store_layout is required for old-stager (default, legacy-dir, or missing-link)" }
        }
        if not ($layout in ["default" "legacy-dir" "missing-link"]) {
            error make { msg: "BOOTC_bridge_store_layout must be legacy-dir, missing-link, or default" }
        }
        return $layout
    }
    if $layout_is_set and $layout != "default" {
        error make { msg: "BOOTC_bridge_store_layout may only be default for old-initramfs" }
    }
    "default"
}

def store-layout [bridge_mode: string] {
    let env_names = ($env | columns)
    let layout = ($env.BOOTC_bridge_store_layout? | default "")
    select-store-layout $bridge_mode $layout ("BOOTC_bridge_store_layout" in $env_names) ("BOOTC_composefs_bridge_store_layout" in $env_names)
}

let compat_root = "/sysroot/ostree/bootc"
let compat_target = "../composefs/bootc"
let legacy_proof = "/var/composefs-bridge-legacy-store.json"
let expected_current_lbis = [
    "quay.io/curl/curl:latest",
    "quay.io/curl/curl-base:latest",
    "registry.access.redhat.com/ubi9/podman:latest",
]

def assert-guest-native-store [] {
    assert (tap is_composefs) "bridge layout mutation requires a native composefs boot"
    assert (not ("/run/.containerenv" | path exists)) "refusing to mutate a container"
    assert (not ("/run/.toolboxenv" | path exists)) "refusing to mutate a Toolbox"
    assert ("/sysroot/composefs" | path exists) "native composefs physical root is required"
    assert ((^test -d /sysroot/ostree | complete | get exit_code) == 0) "ostree compatibility parent must be a real directory"
    assert ((^test -L /sysroot/ostree | complete | get exit_code) != 0) "refusing a symlinked ostree compatibility parent"
}

def assert-compat-link [] {
    assert ((^test -L $compat_root | complete | get exit_code) == 0) "missing composefs compatibility link"
    let target = (readlink $compat_root | str trim)
    assert equal $target $compat_target "unexpected composefs compatibility link target"
}

def compat-root-is-link [] { (^test -L $compat_root | complete | get exit_code) == 0 }

def normalize-config-ids [ids: list<string>] {
    let normalized = ($ids | where { |id| ($id | str trim) != "" } | each { |id|
        let id = ($id | str trim | str downcase)
        let id = if ($id | str starts-with "sha256:") { $id | str replace "sha256:" "" } else { $id }
        assert equal ($id | str length) 64 "config ID is not SHA-256-sized"
        assert equal ($id | str replace -r '^[0-9a-f]{64}$' '') "" "config ID is not lowercase SHA-256"
        $id
    } | uniq)
    assert equal ($normalized | length) 1 "expected one config ID after deduplicating aliases"
    $normalized | first
}

def parse-legacy-proof [raw: string] {
    let proof = $raw | from json
    assert (($proof.source_image | str length) > 0) "legacy proof lacks its source image"
    assert equal (normalize-config-ids [$proof.config_id]) $proof.config_id "legacy proof config ID is not normalized"
    $proof
}

def config-id-for [image: string] {
    let ids = (bootc image cmd list --no-trunc --format '{{.ID}}' $image | lines | where { |id| $id != "" })
    normalize-config-ids $ids
}

def logical-proof [] {
    let logical = bootc image list --type logical --format json | from json
    assert (($logical | length) > 0) "fixture must provide at least one logical image"
    # 1.16 exposes pulls through `bootc image cmd pull`; use it rather than an
    # inspection command so the old client creates the historical CStorage.
    let image = ($logical | first).image
    bootc image cmd pull $image
    { source_image: $image, config_id: (config-id-for $image) } | to json
}

def assert-current-logical-images [] {
    let logical = bootc image list --type logical --format json | from json | get image | sort
    assert equal $logical ($expected_current_lbis | sort) "current bridge fixture must declare exactly its three shared LBIs"
    let config_ids = ($expected_current_lbis | each { |image| config-id-for $image })
    { images: $logical, config_ids: $config_ids } | to json | save --force /var/composefs-bridge-current-lbi-proof.json
}

def legacy-layout-script [] {
'set -euo pipefail
trap "rc=\$?; echo bridge_legacy_layout_helper_failed_at_line_\$LINENO_exit_\$rc >&2; exit \$rc" ERR
mount --make-rprivate /
test -d /sysroot/ostree
test ! -L /sysroot/ostree
test -d /sysroot/composefs
mount -o remount,rw /sysroot
if test -L "$1"; then
    printf "%s\n" "$2" | cmp -s - <(readlink "$1")
    rm -- "$1"
    mkdir -p "$1"
elif ! test -d "$1"; then
    exit 1
fi
test ! -e "$1"/bridge-userdata
test ! -L "$1"/bridge-userdata
printf composefs-1-16-legacy-userdata > "$1"/bridge-userdata
stat -c %i "$1" > /var/composefs-bridge-legacy-parent-inode'
}

def missing-link-script [] {
'set -euo pipefail
trap "rc=\$?; echo bridge_missing_link_helper_failed_at_line_\$LINENO_exit_\$rc >&2; exit \$rc" ERR
mount --make-rprivate /
mount -o remount,rw /sysroot
test -L "$1"
printf "%s\n" "$2" | cmp -s - <(readlink "$1")
rm -- "$1"
printf '%s\n' missing-link-removed > /var/composefs-bridge-layout-missing-link'
}

def prepare-legacy-store [layout: string] {
    if $layout != "legacy-dir" { return }
    assert-guest-native-store
    # The link target is native cache state.  A private mount namespace makes
    # the writable physical-root operation guest-local; this never removes it.
    print "# bridge layout=legacy-dir: entering private mount helper"
    unshare --mount --propagation private /bin/bash -c (legacy-layout-script) -- $compat_root $compat_target
    let proof = logical-proof
    ($proof | from json | upsert parent_inode (open /var/composefs-bridge-legacy-parent-inode | str trim)) | to json | save --force $legacy_proof
    write-checkpoint-marker /var/composefs-bridge-layout-legacy-dir "legacy-dir-created"
    assert-legacy-store $layout
}

def assert-legacy-store [layout: string] {
    if $layout != "legacy-dir" { return }
    let proof = parse-legacy-proof (open --raw $legacy_proof)
    assert equal ($compat_root | path type) "dir" "legacy compatibility root must remain a real directory"
    assert equal (stat -c %i $compat_root | str trim) $proof.parent_inode "legacy directory inode changed"
    assert equal (open $"($compat_root)/bridge-userdata" | str trim) "composefs-1-16-legacy-userdata"
    assert (checkpoint-marker-present /var/composefs-bridge-layout-legacy-dir "legacy-dir-created")
    config-id-for $proof.source_image | ignore
}

def assert-legacy-payload [layout: string] {
    if $layout != "legacy-dir" { return }
    let proof = parse-legacy-proof (open --raw $legacy_proof)
    let checkpoint = ($env.TMT_REBOOT_COUNT? | default "0")
    let archive = $"/var/tmp/bootc-composefs-bridge-legacy-($checkpoint).oci"
    assert (not ($archive | path exists)) "refusing to overwrite a payload proof archive"
    bootc image cmd push $proof.source_image $"oci-archive:($archive)"
    assert (($archive | path exists) and ((^test -s $archive | complete | get exit_code) == 0)) "payload proof archive is empty"
    append-checkpoint-marker /var/composefs-bridge-layout-legacy-dir "payload-proven"
    ^rm -- $archive
}

def remove-compat-link [layout: string] {
    if $layout != "missing-link" { return }
    assert-guest-native-store
    assert-compat-link
    print "# bridge layout=missing-link: entering private mount helper"
    unshare --mount --propagation private /bin/bash -c (missing-link-script) -- $compat_root $compat_target
    assert (not (compat-root-is-link)) "expected compatibility link to be absent"
}

def mark-missing-link-repair [layout: string, checkpoint: string] {
    if $layout != "missing-link" { return }
    assert (checkpoint-marker-present /var/composefs-bridge-layout-missing-link "missing-link-removed")
    append-checkpoint-marker /var/composefs-bridge-layout-missing-link $checkpoint
}

def cmdline [] { open /proc/cmdline | str trim | split row " " }

def required-old-bootc-sha256 [] {
    let checksum = ($env.BOOTC_1160_bootc_sha256? | default "")
    if ($checksum | str length) != 64 {
        error make { msg: "BOOTC_1160_bootc_sha256 must be the required 64-character fixture checksum" }
    }
    $checksum | str downcase
}

def assert-old-fixture [] {
    let version = (bootc --version | str trim)
    assert equal $version "bootc 1.16.0"
    let rpm_version = (rpm -q --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' bootc | str trim)
    let binary_sha256 = (sha256sum /usr/bin/bootc | split row " " | first | str downcase)
    assert equal $binary_sha256 (required-old-bootc-sha256)
    { bootc_version: $version, rpm_version: $rpm_version, bootc_sha256: $binary_sha256 }
        | to json
        | save --force /var/composefs-1-16-bootc-proof.json
    print $"bootc 1.16 fixture proof: version=($version) rpm=($rpm_version) sha256=($binary_sha256)"
}

def assert-booted-image [expected: string] {
    let st = bootc status --json | from json
    let booted = $st.status.booted.image
    assert equal $booted.image.transport "containers-storage"
    assert equal $booted.image.image $expected
}

# Verify the identity actually selected by the running initramfs, as well as
# the corresponding repository image and deployment state directory.
def assert-selected-format [format: string, expect_dual: bool] {
    if not ($format in ["v1" "v2"]) {
        error make { msg: $"Unsupported expected composefs format: ($format)" }
    }
    let st = bootc status --json | from json
    assert ((($st.status.booted.composefs.bootType | into string | str downcase) == "uki"))
    let selected = $st.status.booted.composefs.verity
    assert equal ($selected | str length) 128

    let root = findmnt --json --mountpoint / --output SOURCE | from json
    let root_source = ($root.filesystems | first | get source | into string)
    assert ($root_source | str starts-with "composefs:") "normal bridge boots must mount / directly from composefs"
    assert equal $root_source $"composefs:($selected)"

    let params = cmdline
    let v2_params = ($params | where { |p| $p | into string | str starts-with "composefs=" })
    assert (($v2_params | length) == 1) "UKI must contain one V2 fallback argument"
    let v2_value = ($v2_params | first | str replace "composefs=" "" | into string)
    let v2 = ($v2_value | str replace "?" "")
    let v1_params = ($params | where { |p| $p | into string | str starts-with "composefs.digest=" })
    let v1 = if $expect_dual {
        assert (($v1_params | length) == 1) "current automatic UKI must retain one V1 argument"
        let v1_value = ($v1_params | first | str replace "composefs.digest=" "" | into string)
        let v1_value = ($v1_value | str replace "?" "")
        let parsed_v1 = ($v1_value | split row ":" | last)
        assert ($parsed_v1 != $v2) "dual-format UKI must contain distinct V1 and V2 identities"
        $parsed_v1
    } else {
        assert (($v1_params | length) == 0) "old automatic UKI must be V2-only"
        ""
    }

    let expected = if $format == "v1" { $v1 } else { $v2 }
    assert equal $expected $selected "selected UKI identity must match bootc status"
    assert ($"/sysroot/composefs/images/($selected)" | path exists) "selected composefs image must exist"
    assert ($"/sysroot/state/deploy/($selected)" | path exists) "selected deployment state must exist"
    { selected: $selected, v1: $v1, v2: $v2 }
}

def write-sentinels [] {
    "composefs-1-16-bridge-etc" | save --force /etc/bootc-composefs-bridge-sentinel
    "composefs-1-16-bridge-var" | save --force /var/lib/bootc-composefs-bridge-sentinel
}

def assert-sentinels [] {
    assert equal (open /etc/bootc-composefs-bridge-sentinel | str trim) "composefs-1-16-bridge-etc"
    assert equal (open /var/lib/bootc-composefs-bridge-sentinel | str trim) "composefs-1-16-bridge-var"
}

def stage [image: string, save_as: string] {
    bootc switch --transport containers-storage $image
    let staged = (bootc status --json | from json).status.staged
    let staged_image = $staged.image
    assert equal $staged_image.image.transport "containers-storage"
    assert equal $staged_image.image.image $image
    assert (($staged.composefs.verity | str length) == 128)
    assert ("/run/composefs/staged-deployment" | path exists) "staging must create transient composefs deployment state"
    $staged.composefs.verity | save --force $save_as
}

def old_stager_boot0 [layout: string] {
    tap begin $"bootc 1.16 stager to current dual-UKI bridge [layout=($layout)]"
    assert-old-fixture
    write-sentinels
    if $layout == "legacy-dir" {
        # 1.16 staging may prune LBI storage. Seed the historical real
        # directory only after that old-client operation, then test retention
        # by the new client rather than claiming old-client GC safety.
        stage (bridge-image) /var/composefs-bridge-v2-identity
        prepare-legacy-store $layout
        assert-legacy-store $layout
        assert-legacy-payload $layout
    } else {
        prepare-legacy-store $layout
        stage (bridge-image) /var/composefs-bridge-v2-identity
    }
    tmt-reboot
}

def old_stager_boot1 [layout: string] {
    assert-booted-image (bridge-image)
    assert (not ((bootc --version) | str starts-with "bootc 1.16.0")) "bridge userspace must be current"
    let identity = assert-selected-format v2 true
    assert equal $identity.selected (open /var/composefs-bridge-v2-identity | str trim)
    assert (not ($"/sysroot/composefs/images/($identity.v1)" | path exists)) "the old-initramfs first hop must not materialize the V1 image"
    assert-sentinels
    assert-legacy-store $layout
    assert-legacy-payload $layout
    remove-compat-link $layout
    stage (upgrade-image) /var/composefs-bridge-v1-identity
    # The old client seeded only one LBI. The current stager must fetch all
    # candidate dependencies before scheduling the reboot.
    assert-current-logical-images
    if $layout == "missing-link" {
        assert-compat-link
        mark-missing-link-repair $layout "repaired-staged"
    }
    assert-legacy-store $layout
    assert-legacy-payload $layout
    tmt-reboot
}

def old_stager_boot2 [layout: string] {
    assert-booted-image (upgrade-image)
    assert (not ((bootc --version) | str starts-with "bootc 1.16.0")) "upgraded userspace must be current"
    let identity = assert-selected-format v1 true
    assert equal $identity.selected (open /var/composefs-bridge-v1-identity | str trim)
    assert-sentinels
    if $layout == "missing-link" {
        assert-compat-link
        mark-missing-link-repair $layout "repaired-boot"
    }
    assert-legacy-store $layout
    assert-legacy-payload $layout
    bootc rollback
    assert equal ((bootc status --json | from json).status.rollbackQueued) true
    tmt-reboot
}

def old_stager_boot3 [layout: string] {
    assert-booted-image (bridge-image)
    let identity = assert-selected-format v2 true
    assert equal $identity.selected (open /var/composefs-bridge-v2-identity | str trim)
    assert-sentinels
    assert-legacy-store $layout
    assert-legacy-payload $layout
    assert equal ((bootc status --json | from json).status.rollbackQueued) false
    bootc internals composefs-gc --assert-no-op
    if $layout == "missing-link" {
        assert-compat-link
        mark-missing-link-repair $layout "repaired-rollback-gc"
    }
    assert-legacy-store $layout
    assert-legacy-payload $layout
    tap ok
}

def old_initramfs_boot0 [] {
    tap begin "current stager to old-initramfs V2-only UKI [layout=default]"
    assert (not ((bootc --version) | str starts-with "bootc 1.16.0")) "the V2-only fixture must retain current userspace"
    assert-selected-format v1 true | ignore
    write-sentinels
    stage (bridge-image) /var/composefs-old-initramfs-v2-identity
    tmt-reboot
}

def old_initramfs_boot1 [] {
    assert-booted-image (bridge-image)
    assert (not ((bootc --version) | str starts-with "bootc 1.16.0")) "the V2-only fixture must retain current userspace"
    let identity = assert-selected-format v2 false
    assert equal $identity.selected (open /var/composefs-old-initramfs-v2-identity | str trim)
    assert-sentinels
    tap ok
}

def main [] {
    let selected_mode = mode
    let layout = store-layout $selected_mode
    let count = ($env.TMT_REBOOT_COUNT? | default "0")
    print $"# bridge mode=($selected_mode) store-layout=($layout) reboot=($count)"
    match [ $selected_mode $count ] {
        ["old-stager" "0"] => { old_stager_boot0 $layout },
        ["old-stager" "1"] => { old_stager_boot1 $layout },
        ["old-stager" "2"] => { old_stager_boot2 $layout },
        ["old-stager" "3"] => { old_stager_boot3 $layout },
        ["old-initramfs" "0"] => old_initramfs_boot0,
        ["old-initramfs" "1"] => old_initramfs_boot1,
        [$selected_mode $count] => { error make { msg: $"Invalid bridge mode/reboot count: ($selected_mode)/($count)" } },
    }
}
