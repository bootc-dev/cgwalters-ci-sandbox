# NAME

bootc-install-mount - Mount an installed deployment into a caller-owned directory

# SYNOPSIS

bootc install mount

# DESCRIPTION

Mount the selected deployment from an offline physical sysroot at **TARGET**.
The mount remains in the caller's mount namespace after this command exits;
bootc does not create a container, chroot, or private mount namespace.

The deployment root and `/usr` are always read-only. Persistent `/etc` and
`/var` are also read-only unless **--writable** is specified. The caller must
exclusively own the offline sysroot until the deployment is unmounted and
installation finalization is complete.

# OPTIONS

<!-- BEGIN GENERATED OPTIONS -->
**TARGET**

    Empty directory receiving the deployment mount

    This argument is required.

**--sysroot**=*SYSROOT*

    Offline target sysroot. The target must not be booted or concurrently mutated

**--writable**

    Make the persistent /etc and /var mounts writable. The deployment root remains read-only

<!-- END GENERATED OPTIONS -->

# EXAMPLES

Mount an installation and modify its persistent configuration and state:

```bash
mkdir /mnt/installed
bootc install mount --sysroot /mnt/sysroot --writable /mnt/installed
install -D -m 0644 hostname /mnt/installed/etc/hostname
bootc install unmount /mnt/installed
```

Tools that need process isolation can pass the mounted tree to an external
tool such as `bwrap`, `systemd-nspawn`, or `podman --root`. This command only
assembles the filesystem view.

# SEE ALSO

**bootc**(8), **bootc-install**(8), **bootc-install-unmount**(8)

# VERSION

<!-- VERSION PLACEHOLDER -->
