# NAME

bootc-install-unmount - Unmount a deployment previously mounted by `install mount`

# SYNOPSIS

bootc install unmount

# DESCRIPTION

Unmount a deployment previously mounted by **bootc install mount**. Bootc
validates the saved mount namespace, mount identifiers, sources, topology, and
read-only attributes before removing the mounts. It refuses mounts that are
busy or whose identity or topology has changed; it does not force or lazily
detach them.

# OPTIONS

<!-- BEGIN GENERATED OPTIONS -->
**TARGET**

    Mountpoint previously passed to `install mount`

    This argument is required.

<!-- END GENERATED OPTIONS -->

# EXAMPLES

```bash
bootc install unmount /mnt/installed
```

# SEE ALSO

**bootc**(8), **bootc-install**(8), **bootc-install-mount**(8)

# VERSION

<!-- VERSION PLACEHOLDER -->
