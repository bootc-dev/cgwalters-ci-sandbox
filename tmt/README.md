# TMT integration tests

In the bootc CI, integration tests are executed via Packit on the Testing Farm.

See [CONTRIBUTING.md](../CONTRIBUTING.md#running-tmt-integration-tests) for
instructions on running them locally.

`native-lbi-fresh-install` is opt-in because it retains its VM and fresh disk.
Its normal coverage uses `LBI_FRESH_INSTALL_MODE=stored`, `pull`, or `skip`.
Set `LBI_FRESH_INSTALL_UNIFIED_STORAGE=1` to cover the existing experimental
unified-storage install path, and `LBI_FRESH_INSTALL_SELINUX=1` to require the
privileged nested installer and the booted target to run under SELinux
enforcement while checking bootc-store labels.  The enforcement fixture binds
the guest's `/sys/fs/selinux` read-write into that privileged installer only:
libselinux 3.11 otherwise treats a read-only selinuxfs mount as disabled.  It
does not relabel the bind or write enforcement state or policy.
