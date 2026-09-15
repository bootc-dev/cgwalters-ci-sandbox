# number: 23
# tmt:
#   summary: Execute tests for installing outside of a container
#   duration: 30m
#
use std assert
use tap.nu

# Nu's `rm` is internal, so `complete` cannot be used to inspect its status.
# Return cleanup errors as data so callers can report them without hiding the
# original test failure.
def remove_owned [path: string, recursive: bool] {
    try {
        if $recursive { rm -rf $path } else { rm -f $path }
    } catch {|e| $e }
}

def root_partitions [lsblk_json, loopdev] {
    if ($lsblk_json | is-empty) { return [] }
    let normalized_json = ($lsblk_json | into string)
    if $normalized_json == "" { return [] }
    let parsed = (try { $normalized_json | from json } catch { [] })
    let devices = (try { $parsed | get blockdevices } catch { [] })
    if ($devices | is-empty) { return [] }
    $devices
    | where {|device| (($device.type == "part") and ($device.label == "root") and ($device.path | str starts-with $"($loopdev)p")) }
    | get path
}

def matching_loopdevs [losetup_json, backing_file] {
    if ($losetup_json | is-empty) { return [] }
    let normalized_json = ($losetup_json | into string)
    if $normalized_json == "" { return [] }
    let parsed = (try { $normalized_json | from json } catch { [] })
    let devices = (try { $parsed | get loopdevices } catch { [] })
    if ($devices | is-empty) { return [] }
    $devices
    | where {|device| ($device."back-file" == $backing_file) }
    | get name
}

def mount_tree [path] {
    let result = (do {|target| ^findmnt --json --submounts --mountpoint $target --output TARGET,OPTIONS,ID,SOURCE } $path | complete)
    let stdout = ($result.stdout | default "" | str trim)
    let stderr = ($result.stderr | default "" | str trim)
    if $result.exit_code != 0 {
        error make {msg: $"findmnt failed for ($path): exit=($result.exit_code) stderr=($stderr) stdout=($stdout)"}
    }
    if $stdout == "" {
        error make {msg: $"findmnt returned no JSON for ($path)"}
    }
    try { $stdout | from json } catch {|e| error make {msg: $"invalid findmnt JSON for ($path): ($e)"} }
}

def mount_info [path] {
    let tree = (mount_tree $path)
    try { $tree.filesystems | first } catch {|e| error make {msg: $"findmnt returned no mount for ($path): ($e)"} }
}

def assert_mount_mode [path, mode] {
    let info = (mount_info $path)
    let options = ($info.options | split row ",")
    if $mode not-in $options {
        let mount_json = ($info | to json)
        error make {msg: $"mount mode mismatch for ($path): expected ($mode), got ($info.options); mount=($mount_json)"}
    }
}

def assert_write_denied [path] {
    let result = (do {|target| ^touch $target } $path | complete)
    let stdout = ($result.stdout | default "" | str trim)
    let stderr = ($result.stderr | default "" | str trim)
    print ($"write result path=($path) exit=($result.exit_code) stdout=($stdout) stderr=($stderr)")
    if $result.exit_code == 0 {
        let cleanup_error = (remove_owned $path false)
        if $cleanup_error != null {
            error make {msg: $"write unexpectedly succeeded for ($path), and sentinel cleanup failed: ($cleanup_error)"}
        }
        error make {msg: $"write unexpectedly succeeded for ($path): exit=($result.exit_code) stdout=($stdout) stderr=($stderr)"}
    }
}

# Use the locally-built image which has updated bootupd with compatible
# EFI update metadata. Export to OCI layout on a writable path since
# containers-storage: transport can't work when the root fs is read-only
# (composefs), and install-outside-container tests run directly on the host.
let target_image = "oci:/var/tmp/bootc-oci"

let mount_root = "/var/mnt/bootc-install-mount-root"
let mount_dest = "/var/mnt/bootc-install-mount-dest"
let is_composefs = (tap is_composefs)

let base_args = $"bootc install to-disk --disable-selinux --via-loopback --source-imgref ($target_image)"

let install_cmd = if $is_composefs {
    let st = bootc status --json | from json
    let bootloader = ($st.status.booted.composefs.bootloader | str downcase)
    $"($base_args) --composefs-backend --bootloader=($bootloader) --filesystem ext4 ./disk.img"
} else {
    $"($base_args) --filesystem xfs ./disk.img"
}

mut disk_created = false
mut outer_mounted = false
mut loopdev = null
mut root_created = false
mut root_mounted = false
mut dest_created = false
mut deployment_mounted = false
mut oci_created = false
let failure = (try {
    for path in ["./disk.img", $mount_root, $mount_dest, "/var/tmp/bootc-oci"] {
        if ($path | path exists) {
            error make {msg: $"refusing pre-existing test path: ($path)"}
        }
    }

    bootc image copy-to-storage
    # Claim this path before the copy so a partial failed copy is still cleaned.
    $oci_created = true
    skopeo copy containers-storage:localhost/bootc oci:/var/tmp/bootc-oci

    # setup filesystem
    mkdir /var/mnt
    truncate -s 10G disk.img
    $disk_created = true
    mkfs.ext4 disk.img
    mount -o loop disk.img /var/mnt
    $outer_mounted = true

    # attempt to install to filesystem without specifying a source-imgref
    let result = bootc install to-filesystem /var/mnt e>| find "--source-imgref must be defined"
    assert not equal $result null
    umount /var/mnt
    $outer_mounted = false

    # And using systemd-run here breaks our install_t so we disable SELinux enforcement
    setenforce 0

    tap run_install $install_cmd

    # Exercise the explicit-path mount lifecycle in this guest, rather than in
    # a container whose mount namespace would disappear with the CLI process.
    let disk_realpath_result = (do { ^realpath -- ./disk.img } | complete)
    if $disk_realpath_result.exit_code != 0 {
        error make {msg: $"could not canonicalize ./disk.img: ($disk_realpath_result.stderr)"}
    }
    let disk_realpath = ($disk_realpath_result.stdout | default "" | str trim)
    if ($disk_realpath | is-empty) {
        error make {msg: "realpath returned an empty canonical disk path"}
    }
    let created_loop = (do { ^losetup --find --show --partscan ./disk.img } | complete)
    let reported_loop = ($created_loop.stdout | default "" | str trim)
    let created_stderr = ($created_loop.stderr | default "" | str trim)
    let loop_json_result = (do { ^losetup --json --output NAME,BACK-FILE } | complete)
    let loop_json = ($loop_json_result.stdout | default "" | str trim)
    let query_stderr = ($loop_json_result.stderr | default "" | str trim)
    let matching_loops = if $loop_json_result.exit_code == 0 {
        matching_loopdevs $loop_json $disk_realpath
    } else {
        []
    }
    if ($matching_loops | length) != 1 {
        let diagnostic = $"losetup failed to identify exactly one loop for ($disk_realpath): exit=($created_loop.exit_code) stderr=($created_stderr) stdout=($reported_loop) query_exit=($loop_json_result.exit_code) query_stderr=($query_stderr) query_json=($loop_json)"
        error make {msg: $diagnostic}
    }
    let attached_loopdev = ($matching_loops | first | into string | str trim)
    if not ($attached_loopdev =~ '^/dev/loop[0-9]+$') {
        error make {msg: $"losetup identified an invalid loop device ($attached_loopdev) for ($disk_realpath); reported stdout=($reported_loop)"}
    }
    # The exact backing-file match establishes ownership even if --show's
    # stdout was malformed; cleanup must handle that possible orphan.
    $loopdev = $attached_loopdev
    if not ($reported_loop =~ '^$|^/dev/loop[0-9]+$') {
        error make {msg: $"losetup returned malformed loop stdout ($reported_loop); verified device ($attached_loopdev) retained for cleanup"}
    }
    udevadm settle
    partprobe $attached_loopdev
    udevadm settle
    mut root_partition = null
    mut last_lsblk = ""
    for attempt in 1..10 {
        let probe = (do {|device| lsblk --list --json --paths --output PATH,LABEL,TYPE,PKNAME $device } $attached_loopdev | complete)
        let stdout = ($probe.stdout | default "")
        let stderr = ($probe.stderr | default "")
        $last_lsblk = $"exit=($probe.exit_code) stderr=($stderr) stdout=($stdout)"
        if $probe.exit_code == 0 {
            let roots = (root_partitions $stdout $attached_loopdev)
            if ($roots | length) == 1 {
                $root_partition = ($roots | first)
                break
            }
        }
        if $attempt < 10 { sleep 1sec }
    }
    if $root_partition == null {
        error make {msg: $"timed out waiting for exactly one root partition on ($attached_loopdev); last lsblk JSON: ($last_lsblk)"}
    }

    mkdir $mount_root
    $root_created = true
    mount $root_partition $mount_root
    $root_mounted = true
    mkdir $mount_dest
    $dest_created = true
    assert ((ls $mount_dest | length) == 0)

    ^/usr/bin/bootc install mount --sysroot $mount_root $mount_dest
    $deployment_mounted = true
    let readonly_mounts = (mount_tree $mount_dest)
    print ($readonly_mounts | to json)
    assert_mount_mode $mount_dest "ro"
    assert_mount_mode ($mount_dest | path join etc) "ro"
    assert_mount_mode ($mount_dest | path join var) "ro"
    # /root is a persistent-state indirection on OSTree, not the deployment
    # root. Use a file directly at the mounted root for this immutability check.
    for path in [mount-api-root-sentinel usr/sentinel etc/sentinel var/sentinel] {
        let target = ($mount_dest | path join $path)
        print ($"write attempt path=($target)")
        assert_write_denied $target
    }
    ^/usr/bin/bootc install unmount $mount_dest
    $deployment_mounted = false

    ^/usr/bin/bootc install mount --sysroot $mount_root --writable $mount_dest
    $deployment_mounted = true
    let writable_mounts = (mount_tree $mount_dest)
    print ($writable_mounts | to json)
    assert_mount_mode $mount_dest "ro"
    assert_mount_mode ($mount_dest | path join etc) "rw"
    assert_mount_mode ($mount_dest | path join var) "rw"
    "etc sentinel" | save ($mount_dest | path join etc/sentinel)
    "var sentinel" | save ($mount_dest | path join var/sentinel)
    for path in [mount-api-root-sentinel usr/sentinel] {
        assert_write_denied ($mount_dest | path join $path)
    }
    ^/usr/bin/bootc install unmount $mount_dest
    $deployment_mounted = false

    let deployment_root = if $is_composefs {
        ($mount_root | path join state/deploy)
    } else {
        ($mount_root | path join ostree/deploy/default/deploy)
    }
    let deployments = (ls $deployment_root | where type == dir | get name)
    if ($deployments | length) != 1 {
        error make {msg: $"installed target has ($deployments | length) selected deployments in ($deployment_root); expected exactly one"}
    }
    let deployment = ($deployments | first)
    let etc_path = ($deployment | path join etc/sentinel)
    let etc_value = (open $etc_path)
    assert ($etc_value == "etc sentinel") $"unexpected etc sentinel at ($etc_path): actual=($etc_value)"
    let shared_var = if $is_composefs {
        ($mount_root | path join state/os/default/var/sentinel)
    } else {
        ($mount_root | path join ostree/deploy/default/var/sentinel)
    }
    let var_value = (open $shared_var)
    assert ($var_value == "var sentinel") $"unexpected var sentinel at ($shared_var): actual=($var_value)"
    let root_sentinel = ($deployment | path join mount-api-root-sentinel)
    let usr_sentinel = ($deployment | path join usr/sentinel)
    assert (not ($root_sentinel | path exists)) $"unexpected root sentinel persisted at ($root_sentinel)"
    assert (not ($usr_sentinel | path exists)) $"unexpected usr sentinel persisted at ($usr_sentinel)"
} catch {|e| $e })

# Cleanup is deliberately limited to mounts and paths owned by this test.
mut cleanup_errors = []
if $deployment_mounted {
    let result = (do {|path| ^/usr/bin/bootc install unmount $path } $mount_dest | complete)
    if $result.exit_code != 0 {
        $cleanup_errors = ($cleanup_errors | append $"bootc unmount ($mount_dest): ($result.stderr)")
    }
}
if $dest_created {
    let mounted = (do { findmnt --mountpoint $mount_dest } | complete)
    if $mounted.exit_code == 0 {
        let result = (do {|path| umount $path } $mount_dest | complete)
        if $result.exit_code != 0 {
            $cleanup_errors = ($cleanup_errors | append $"unmount ($mount_dest): ($result.stderr)")
        }
    }
    let mounted = (do { findmnt --mountpoint $mount_dest } | complete)
    if $mounted.exit_code == 0 {
        $cleanup_errors = ($cleanup_errors | append $"retaining mounted test directory ($mount_dest)")
    } else if $mounted.exit_code == 1 {
        let error = (remove_owned $mount_dest true)
        if $error != null {
            $cleanup_errors = ($cleanup_errors | append $"remove ($mount_dest): ($error)")
        }
    } else {
        $cleanup_errors = ($cleanup_errors | append $"could not verify mount state for ($mount_dest); retaining it")
    }
}
if $outer_mounted {
    let result = (do { umount /var/mnt } | complete)
    if $result.exit_code != 0 {
        $cleanup_errors = ($cleanup_errors | append $"unmount /var/mnt: ($result.stderr)")
    }
}
if $root_mounted {
    let result = (do {|path| umount $path } $mount_root | complete)
    if $result.exit_code != 0 {
        $cleanup_errors = ($cleanup_errors | append $"unmount ($mount_root): ($result.stderr)")
    }
}
if $root_created {
    let mounted = (do { findmnt --mountpoint $mount_root } | complete)
    if $mounted.exit_code == 0 {
        $cleanup_errors = ($cleanup_errors | append $"retaining mounted physical target ($mount_root)")
    } else if $mounted.exit_code == 1 {
        let error = (remove_owned $mount_root true)
        if $error != null {
            $cleanup_errors = ($cleanup_errors | append $"remove ($mount_root): ($error)")
        }
    } else {
        $cleanup_errors = ($cleanup_errors | append $"could not verify mount state for ($mount_root); retaining it")
    }
}
mut loop_detached = true
if $loopdev != null {
    $loop_detached = false
    mut last_detach_error = ""
    for attempt in 1..5 {
        let result = (do {|device| losetup --detach $device } $loopdev | complete)
        if $result.exit_code != 0 { $last_detach_error = $result.stderr }
        let attached = (do {|device| losetup $device } $loopdev | complete)
        if $attached.exit_code == 1 {
            $loop_detached = true
            break
        }
        if $attempt < 5 {
            do { udevadm settle } | complete
            sleep 1sec
        }
    }
    if not $loop_detached {
        if $last_detach_error == "" {
            $cleanup_errors = ($cleanup_errors | append $"retaining attached loop device ($loopdev)")
        } else {
            $cleanup_errors = ($cleanup_errors | append $"retaining attached loop device ($loopdev): ($last_detach_error)")
        }
    }
}
if $disk_created and $loop_detached {
    let error = (remove_owned ./disk.img false)
    if $error != null {
        $cleanup_errors = ($cleanup_errors | append $"remove ./disk.img: ($error)")
    }
}
if $oci_created {
    let error = (remove_owned /var/tmp/bootc-oci true)
    if $error != null {
        $cleanup_errors = ($cleanup_errors | append $"remove /var/tmp/bootc-oci: ($error)")
    }
}
if $failure != null or ($cleanup_errors | is-empty) == false {
    let details = ($cleanup_errors | prepend $failure | where $it != null | str join "; ")
    error make {msg: $"install mount lifecycle test failed: ($details)"}
}

tap ok
