//! Explicit, caller-owned mounts of an offline deployment.
//!
//! This is deliberately not a runner: the mount namespace belongs to the
//! caller, and the mounts remain after this process exits.

use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail, ensure};
use camino::Utf8PathBuf;
use cap_std_ext::{
    cap_std::{ambient_authority, fs::Dir},
    dirext::CapStdExtDirExt,
};
use clap::Args;
use ostree::gio;
use ostree_ext::ostree;
use rustix::fs::{FlockOperation, Mode, OFlags, flock, openat};
use rustix::mount::{
    MoveMountFlags, OpenTreeFlags, UnmountFlags, move_mount, open_tree, unmount as unmount_fs,
};
use serde::{Deserialize, Serialize};

const ETC: &str = "etc";
const VAR: &str = "var";
const RECORD_DIR: &str = "/run/bootc/install-mounts";

fn ostree_state_path(stateroot: &str) -> PathBuf {
    Path::new("ostree/deploy").join(stateroot).join(VAR)
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
struct MountRecord {
    sysroot: PathBuf,
    target: PathBuf,
    namespace_dev: u64,
    namespace_ino: u64,
    writable_state: bool,
    mounts: Vec<MountIdentity>,
    /// A mount which was selected for teardown before the last operation.
    /// This makes a crash after unmount(2), but before updating the record,
    /// recoverable without ever guessing about an unrelated mount.
    #[serde(default)]
    pending_unmount: Option<MountIdentity>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
struct MountIdentity {
    path: PathBuf,
    id: u64,
    source: String,
    readonly: bool,
}

fn namespace_identity() -> Result<(u64, u64)> {
    let metadata = std::fs::metadata("/proc/self/ns/mnt")
        .context("Reading the current mount namespace identity")?;
    Ok((metadata.dev(), metadata.ino()))
}

fn record_path(target: &Path) -> Result<PathBuf> {
    let target = target
        .to_str()
        .ok_or_else(|| anyhow::anyhow!("mount target is not valid UTF-8"))?;
    // Stable across processes; DefaultHasher is intentionally randomized and
    // therefore cannot be used to find a record from the unmount command.
    let mut digest = 0xcbf29ce484222325u64;
    for byte in target.bytes() {
        digest ^= u64::from(byte);
        digest = digest.wrapping_mul(0x100000001b3);
    }
    Ok(Path::new(RECORD_DIR).join(format!("{digest:016x}.json")))
}

fn create_record(record: &MountRecord) -> Result<PathBuf> {
    std::fs::create_dir_all(RECORD_DIR).context("Creating mount record directory")?;
    std::fs::set_permissions(RECORD_DIR, std::fs::Permissions::from_mode(0o700))?;
    let path = record_path(&record.target)?;
    let mut file = tempfile::NamedTempFile::new_in(RECORD_DIR)?;
    file.as_file_mut()
        .set_permissions(std::fs::Permissions::from_mode(0o600))?;
    std::io::Write::write_all(file.as_file_mut(), &serde_json::to_vec(record)?)?;
    file.as_file().sync_all().context("Syncing mount record")?;
    file.persist_noclobber(&path)
        .map_err(|error| error.error)
        .with_context(|| format!("Creating mount record {}", path.display()))?;
    std::fs::File::open(RECORD_DIR)?.sync_all()?;
    Ok(path)
}

fn write_record(path: &Path, record: &MountRecord) -> Result<()> {
    let parent = path.parent().context("mount record has no parent")?;
    let mut file = tempfile::NamedTempFile::new_in(parent)?;
    file.as_file_mut()
        .set_permissions(std::fs::Permissions::from_mode(0o600))?;
    std::io::Write::write_all(file.as_file_mut(), &serde_json::to_vec(record)?)?;
    file.as_file().sync_all()?;
    file.persist(path).map_err(|error| error.error)?;
    // The rename is durable, but only after the containing directory is synced.
    std::fs::File::open(parent)?.sync_all()?;
    Ok(())
}

fn load_record(target: &Path) -> Result<(PathBuf, MountRecord)> {
    let path = record_path(target)?;
    let record: MountRecord = serde_json::from_slice(
        &std::fs::read(&path)
            .with_context(|| format!("Reading mount record {}", path.display()))?,
    )?;
    ensure!(record.target == target, "mount record target mismatch");
    Ok((path, record))
}

fn mount_identity(path: &Path) -> Result<MountIdentity> {
    let path_str = path
        .to_str()
        .ok_or_else(|| anyhow::anyhow!("mount path is not valid UTF-8"))?;
    let result = bootc_mount::run_findmnt(&["--mountpoint"], None, Some(path_str))?;
    let filesystem = result
        .filesystems
        .into_iter()
        .next()
        .ok_or_else(|| anyhow::anyhow!("{} is not a mountpoint", path.display()))?;
    let id = filesystem.id.ok_or_else(|| {
        anyhow::anyhow!("findmnt did not report a mount ID for {}", path.display())
    })?;
    Ok(MountIdentity {
        path: path.to_owned(),
        id,
        source: filesystem.source,
        readonly: filesystem.options.split(',').any(|option| option == "ro"),
    })
}

fn current_mount_identity(path: &Path) -> Result<Option<MountIdentity>> {
    let path_str = path
        .to_str()
        .ok_or_else(|| anyhow::anyhow!("mount path is not valid UTF-8"))?;
    let mut mounts = bootc_mount::run_findmnt(&["--mountpoint"], None, Some(path_str))?.filesystems;
    mounts.pop().map_or(Ok(None), |filesystem| {
        Ok(Some(MountIdentity {
            path: path.to_owned(),
            id: filesystem
                .id
                .ok_or_else(|| anyhow::anyhow!("findmnt did not report a mount ID"))?,
            source: filesystem.source,
            readonly: filesystem.options.split(',').any(|option| option == "ro"),
        }))
    })
}

fn validate_record_shape(record: &MountRecord) -> Result<()> {
    let root = &record.target;
    let expected = [root.clone(), root.join(ETC), root.join(VAR)];
    ensure!(
        record.mounts.len() == expected.len(),
        "mount record has unexpected mount count"
    );
    for (identity, expected_path) in record.mounts.iter().zip(expected) {
        ensure!(
            identity.path == expected_path,
            "mount record has unexpected topology"
        );
    }
    ensure!(
        record.mounts[0].readonly,
        "deployment root is not recorded read-only"
    );
    ensure!(
        record.mounts[1].readonly == !record.writable_state
            && record.mounts[2].readonly == !record.writable_state,
        "persistent state readonly attributes do not match mount mode"
    );
    if let Some(pending) = &record.pending_unmount {
        ensure!(
            record.mounts.iter().any(|mount| mount == pending),
            "pending unmount is not one of the recorded mounts"
        );
    }
    Ok(())
}

fn operation_lock(target: &Path) -> Result<std::fs::File> {
    std::fs::create_dir_all(RECORD_DIR)?;
    let path = record_path(target)?.with_extension("lock");
    let file = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(false)
        .mode(0o600)
        .open(path)?;
    flock(&file, FlockOperation::LockExclusive).context("Locking install mount target")?;
    Ok(file)
}

fn validate_record(record: &MountRecord) -> Result<()> {
    validate_record_shape(record)?;
    ensure!(
        namespace_identity()? == (record.namespace_dev, record.namespace_ino),
        "mount record belongs to a different mount namespace"
    );
    let expected: std::collections::BTreeSet<_> =
        record.mounts.iter().map(|m| m.path.clone()).collect();
    let target = record
        .target
        .to_str()
        .ok_or_else(|| anyhow::anyhow!("mount target is not valid UTF-8"))?;
    let subtree = match bootc_mount::run_findmnt(&["--submounts"], None, Some(target)) {
        Ok(subtree) => subtree,
        Err(_error)
            if record.pending_unmount.as_ref().is_some_and(|mount| {
                mount.path == record.target
                    && current_mount_identity(&record.target)
                        .ok()
                        .flatten()
                        .is_none()
            }) =>
        {
            bootc_mount::Findmnt::default()
        }
        Err(error) => return Err(error),
    };
    let mut actual_paths = std::collections::BTreeSet::new();
    collect_mount_targets(&subtree.filesystems, &mut actual_paths);
    let allowed_missing = record.pending_unmount.as_ref().map(|m| &m.path);
    ensure!(
        actual_paths == expected
            || allowed_missing.is_some_and(|path| {
                let mut reduced = expected.clone();
                reduced.remove(path);
                actual_paths == reduced
            }),
        "mount topology changed; refusing unmount"
    );
    for wanted in &record.mounts {
        let Some(found) = current_mount_identity(&wanted.path)? else {
            ensure!(
                allowed_missing == Some(&wanted.path),
                "expected mount is missing; refusing unmount"
            );
            continue;
        };
        ensure!(
            wanted.id == found.id,
            "mount ID changed for {}; refusing unmount",
            wanted.path.display()
        );
        ensure!(
            wanted.source == found.source,
            "mount source changed for {}; refusing unmount",
            wanted.path.display()
        );
        ensure!(
            wanted.readonly == found.readonly,
            "mount readonly attribute changed for {}; refusing unmount",
            wanted.path.display()
        );
    }
    Ok(())
}

fn collect_mount_targets(
    filesystems: &[bootc_mount::Filesystem],
    targets: &mut std::collections::BTreeSet<PathBuf>,
) {
    for filesystem in filesystems {
        targets.insert(PathBuf::from(&filesystem.target));
        if let Some(children) = &filesystem.children {
            collect_mount_targets(children, targets);
        }
    }
}

/// Decide whether a pending teardown was completed before the process died.
/// A missing mount is recoverable only for the exact identity already recorded.
fn pending_unmount_recovered(
    record: &MountRecord,
    current: Option<&MountIdentity>,
) -> Result<bool> {
    let Some(pending) = &record.pending_unmount else {
        return Ok(false);
    };
    if let Some(current) = current {
        ensure!(
            pending == current,
            "pending mount identity changed; refusing recovery"
        );
        Ok(false)
    } else {
        Ok(true)
    }
}

#[derive(Debug, Args, PartialEq, Eq)]
pub(crate) struct MountOpts {
    /// Offline target sysroot. The target must not be booted or concurrently mutated.
    #[clap(long, value_parser = crate::cli::parse_absolute_path)]
    pub(crate) sysroot: Utf8PathBuf,

    /// Make the persistent /etc and /var mounts writable. The deployment root remains read-only.
    #[clap(long)]
    pub(crate) writable: bool,

    /// Empty directory receiving the deployment mount.
    pub(crate) target: Utf8PathBuf,
}

#[derive(Debug, Args, PartialEq, Eq)]
pub(crate) struct UnmountOpts {
    /// Mountpoint previously passed to `install mount`.
    pub(crate) target: Utf8PathBuf,
}

/// Validate the path relationship before doing any mount syscall.
pub(crate) fn validate_mount_target(sysroot: &Path, target: &Path) -> Result<()> {
    ensure!(sysroot.is_absolute(), "--sysroot must be absolute");
    ensure!(target.is_absolute(), "mount target must be absolute");
    let target_metadata = std::fs::symlink_metadata(target)
        .with_context(|| format!("Opening mount target {}", target.display()))?;
    ensure!(
        target_metadata.file_type().is_dir(),
        "mount target must be a real directory: {}",
        target.display()
    );
    ensure!(
        target.read_dir()?.next().is_none(),
        "mount target must be an existing empty directory: {}",
        target.display()
    );

    let sysroot = std::fs::canonicalize(sysroot)
        .with_context(|| format!("Resolving sysroot {}", sysroot.display()))?;
    let target = std::fs::canonicalize(target)
        .with_context(|| format!("Resolving mount target {}", target.display()))?;
    ensure!(
        !target.starts_with(&sysroot) && !sysroot.starts_with(&target),
        "sysroot and mount target must not overlap"
    );
    Ok(())
}

fn validate_relative_mount_path(path: &Path) -> Result<()> {
    ensure!(!path.is_absolute(), "path must be relative to the sysroot");
    ensure!(!path.as_os_str().is_empty(), "path must not be empty");
    for component in path.components() {
        ensure!(
            matches!(component, std::path::Component::Normal(_)),
            "path must contain only normal components"
        );
    }
    Ok(())
}

pub(crate) async fn mount(opts: MountOpts) -> Result<()> {
    validate_mount_target(opts.sysroot.as_std_path(), opts.target.as_std_path())?;
    // This is an operation lock, not a system-wide GC interlock. The caller's
    // offline/exclusive contract remains necessary for mutations outside bootc.
    let _operation_lock = operation_lock(opts.target.as_std_path())?;
    // Keep handles alive for the complete assembly. They make the selected
    // directories namespace objects rather than merely strings supplied by a
    // later caller; path-based syscalls below are additionally guarded by the
    // mount record before teardown.
    let _sysroot_dir = Dir::open_ambient_dir(&opts.sysroot, ambient_authority())
        .context("Opening target sysroot directory")?;
    let target_dir = Dir::open_ambient_dir(&opts.target, ambient_authority())
        .context("Opening mount target directory")?;
    let target_parent = target_dir.open_parent_dir(ambient_authority())?;
    let target_name = opts
        .target
        .file_name()
        .ok_or_else(|| anyhow::anyhow!("mount target has no final path component"))?
        .to_owned();
    ensure!(
        target_dir.entries()?.next().is_none(),
        "mount target changed and is no longer empty"
    );

    let repo = open_optional_dir_nofollow(&_sysroot_dir, Path::new("ostree/repo"))?;
    let composefs = open_optional_dir_nofollow(&_sysroot_dir, Path::new("composefs"))?;
    ensure!(
        !(repo.is_some() && composefs.is_some()),
        "target has ambiguous OSTree and composefs backend markers"
    );
    let mut sysroot_lock = None;
    let mut composefs_sources = None;
    let (source, _etc, var, composefs_id) = if composefs.is_some() {
        let deployments_dir = open_dir_nofollow(&_sysroot_dir, Path::new("state/deploy"))?;
        let deployments = composefs_deployments(&deployments_dir)?;
        let [id] = deployments.as_slice() else {
            bail!(
                "target must contain exactly one composefs deployment; refusing ambiguous selection"
            );
        };
        let deployment = open_dir_nofollow(&deployments_dir, Path::new(id))?;
        let etc = open_dir_nofollow(&deployment, Path::new(ETC))?;
        let state = open_dir_nofollow(&_sysroot_dir, Path::new("state"))?;
        let default = open_dir_nofollow(
            &open_dir_nofollow(&state, Path::new("os"))?,
            Path::new("default"),
        )?;
        let var_source = open_dir_nofollow(&default, Path::new(VAR))?;
        composefs_sources = Some((etc, var_source));
        (
            PathBuf::new(),
            opts.sysroot
                .join("state/deploy")
                .join(id)
                .join(ETC)
                .into_std_path_buf(),
            opts.sysroot
                .join("state/os/default/var")
                .into_std_path_buf(),
            Some(id.to_owned()),
        )
    } else {
        ensure!(repo.is_some(), "target is not an OSTree sysroot");
        let sysroot = ostree::Sysroot::new(Some(&gio::File::for_path(&opts.sysroot)));
        sysroot
            .load(gio::Cancellable::NONE)
            .context("Loading target OSTree sysroot")?;
        sysroot_lock = Some(ostree_ext::sysroot::SysrootLock::new_from_sysroot(&sysroot).await?);
        let deployments = sysroot.deployments();
        let [deployment] = deployments.as_slice() else {
            bail!("target must contain exactly one deployment; refusing ambiguous selection");
        };
        let source = PathBuf::from(sysroot.deployment_dirpath(deployment).as_str());
        validate_relative_mount_path(&source)
            .with_context(|| format!("Invalid OSTree deployment path {source:?}"))?;
        let etc = source.join(ETC);
        let var = ostree_state_path(deployment.stateroot().as_str());
        validate_relative_mount_path(&var)
            .with_context(|| format!("Invalid OSTree state path {var:?}"))?;
        (source, etc, var, None)
    };
    let _sysroot_lock = sysroot_lock;

    let (root_tree, etc_source, var_source) = if source.as_os_str().is_empty() {
        let sysroot_fd =
            Dir::open_ambient_dir(&opts.sysroot, ambient_authority())?.reopen_as_ownedfd()?;
        let Some(composefs_id) = composefs_id.as_deref() else {
            bail!("internal backend selection error: missing composefs deployment ID");
        };
        let image = bootc_initramfs_setup::mount_composefs_image_readonly(
            &sysroot_fd,
            composefs_id,
            false,
        )?;
        let (etc, var) = composefs_sources
            .take()
            .ok_or_else(|| anyhow::anyhow!("missing selected composefs source handles"))?;
        (Some(image), etc, var)
    } else {
        let deployment = open_dir_nofollow(&_sysroot_dir, &source)?;
        let etc_source = open_dir_nofollow(&deployment, Path::new(ETC))?;
        let var_source = open_dir_nofollow(&_sysroot_dir, &var)?;
        (
            Some(open_tree(
                &_sysroot_dir,
                &source,
                OpenTreeFlags::OPEN_TREE_CLONE | OpenTreeFlags::OPEN_TREE_CLOEXEC,
            )?),
            etc_source,
            var_source,
        )
    };
    let root_tree = root_tree.ok_or_else(|| anyhow::anyhow!("missing deployment root mount"))?;
    bootc_initramfs_setup::set_mount_readonly(&root_tree)
        .context("Making detached deployment root read-only")?;
    move_mount(
        &root_tree,
        "",
        &target_dir,
        ".",
        MoveMountFlags::MOVE_MOUNT_F_EMPTY_PATH,
    )?;
    let target_root = match open_dir_nofollow(&target_parent, Path::new(&target_name)) {
        Ok(root) => root,
        Err(error) => {
            let cleanup = unmount_fs(opts.target.as_std_path(), UnmountFlags::empty());
            return match cleanup {
                Ok(()) => Err(error).context("Opening mounted deployment root"),
                Err(cleanup_error) => Err(error).context(format!(
                    "Opening mounted deployment root (cleanup also failed: {cleanup_error})"
                )),
            };
        }
    };
    let namespace = match namespace_identity() {
        Ok(namespace) => namespace,
        Err(error) => {
            let cleanup = unmount_fs(opts.target.as_std_path(), UnmountFlags::empty());
            return match cleanup {
                Ok(()) => Err(error).context("Recording mount namespace identity"),
                Err(cleanup_error) => Err(error).context(format!(
                    "Recording mount namespace identity (cleanup also failed: {cleanup_error})"
                )),
            };
        }
    };
    let root_identity = match mount_identity(opts.target.as_std_path()) {
        Ok(identity) => identity,
        Err(error) => {
            let _ = unmount_fs(opts.target.as_std_path(), UnmountFlags::empty());
            return Err(error).context("Recording deployment root mount");
        }
    };
    let mut record = MountRecord {
        sysroot: opts.sysroot.as_std_path().to_owned(),
        target: opts.target.as_std_path().to_owned(),
        namespace_dev: namespace.0,
        namespace_ino: namespace.1,
        writable_state: opts.writable,
        mounts: vec![root_identity],
        pending_unmount: None,
    };
    let target = opts.target.as_std_path();
    let mut owned = vec![target.to_owned()];
    let result = (|| -> Result<()> {
        attach_state(&etc_source, &target_root, ETC, opts.writable)?;
        owned.push(target.join(ETC));
        record.mounts.push(mount_identity(&owned[1])?);
        attach_state(&var_source, &target_root, VAR, opts.writable)?;
        owned.push(target.join(VAR));
        record.mounts.push(mount_identity(&owned[2])?);
        create_record(&record).context("Recording deployment mounts")?;
        Ok(())
    })();
    if let Err(error) = result {
        let cleanup = owned
            .into_iter()
            .rev()
            .map(|path| unmount_fs(path, UnmountFlags::empty()))
            .collect::<Result<Vec<_>, _>>();
        return match cleanup {
            Ok(_) => Err(error).context("Assembling offline deployment mount"),
            Err(cleanup_error) => Err(error).context(format!(
                "Assembling offline deployment mount (cleanup also failed: {cleanup_error})"
            )),
        };
    }
    Ok(())
}

fn composefs_deployments(path: &Dir) -> Result<Vec<String>> {
    let mut ids = Vec::new();
    for entry in path.entries().context("Reading composefs deployments")? {
        let entry = entry?;
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if name.as_bytes().len() == 128 && name.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            ensure!(
                entry.file_type()?.is_dir(),
                "composefs deployment is not a directory"
            );
            let deployment = open_dir_nofollow(path, Path::new(name))?;
            open_dir_nofollow(&deployment, Path::new(ETC))
                .context("composefs deployment has no /etc state")?;
            ids.push(name.to_owned());
        }
    }
    Ok(ids)
}

fn attach_state(source: &Dir, target: &Dir, name: &str, writable: bool) -> Result<()> {
    let tree = open_tree(
        source,
        ".",
        OpenTreeFlags::OPEN_TREE_CLONE | OpenTreeFlags::OPEN_TREE_CLOEXEC,
    )?;
    if !writable {
        bootc_initramfs_setup::set_mount_readonly(&tree)
            .context("Making detached state mount read-only")?;
    }
    move_mount(
        &tree,
        "",
        target,
        name,
        MoveMountFlags::MOVE_MOUNT_F_EMPTY_PATH,
    )?;
    Ok(())
}

fn open_dir_nofollow(parent: &Dir, path: &Path) -> Result<Dir> {
    let mut current = parent.try_clone()?;
    for component in path.components() {
        let std::path::Component::Normal(name) = component else {
            bail!("descriptor-relative paths must contain only normal components");
        };
        let fd = openat(
            &current,
            name,
            OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::empty(),
        )?;
        current = Dir::from_std_file(std::fs::File::from(fd));
    }
    Ok(current)
}

fn open_optional_dir_nofollow(parent: &Dir, path: &Path) -> Result<Option<Dir>> {
    match open_dir_nofollow(parent, path) {
        Ok(dir) => Ok(Some(dir)),
        Err(error)
            if error.downcast_ref::<rustix::io::Errno>() == Some(&rustix::io::Errno::NOENT) =>
        {
            Ok(None)
        }
        Err(error) => Err(error),
    }
}

pub(crate) async fn unmount(opts: UnmountOpts) -> Result<()> {
    let target = opts.target.as_std_path();
    ensure!(target.is_absolute(), "mount target must be absolute");
    let _operation_lock = operation_lock(target)?;
    let (record_path, record) = load_record(target)?;
    validate_record(&record)?;
    let _sysroot_lock = if record.sysroot.join("ostree/repo").is_dir() {
        let sysroot = ostree::Sysroot::new(Some(&gio::File::for_path(&record.sysroot)));
        sysroot
            .load(gio::Cancellable::NONE)
            .context("Loading target OSTree sysroot")?;
        Some(ostree_ext::sysroot::SysrootLock::new_from_sysroot(&sysroot).await?)
    } else {
        None
    };
    unmount_record_inner(&record_path, record)
}

fn unmount_record_inner(path: &Path, mut record: MountRecord) -> Result<()> {
    record
        .mounts
        .sort_by_key(|mount| mount.path.components().count());
    while let Some(mount) = record.mounts.last().cloned() {
        record.pending_unmount = Some(mount.clone());
        write_record(path, &record)?;
        let current = current_mount_identity(&mount.path)?;
        if pending_unmount_recovered(&record, current.as_ref())? {
            // A crash may have happened after the kernel teardown and before
            // the record update. Missing is safe only for this exact pending
            // identity; arbitrary missing/unknown mounts are never guessed at.
            record.pending_unmount = None;
            record.mounts.pop();
            if record.mounts.is_empty() {
                std::fs::remove_file(path)?;
            } else {
                write_record(path, &record)?;
            }
            continue;
        }
        unmount_fs(&mount.path, UnmountFlags::empty())
            .with_context(|| format!("Unmounting {}", mount.path.display()))?;
        record.pending_unmount = None;
        record.mounts.pop();
        if record.mounts.is_empty() {
            std::fs::remove_file(path)?;
        } else {
            write_record(path, &record)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use bootc_mount::Filesystem;
    use std::path::PathBuf;

    use super::{
        MountIdentity, MountRecord, collect_mount_targets, ostree_state_path,
        pending_unmount_recovered, validate_mount_target, validate_record_shape,
        validate_relative_mount_path,
    };

    #[test]
    fn rejects_overlap_and_nonempty_targets() {
        let temp = tempfile::tempdir().unwrap();
        let sysroot = temp.path().join("sysroot");
        let target = temp.path().join("target");
        std::fs::create_dir(&sysroot).unwrap();
        std::fs::create_dir(&target).unwrap();
        validate_mount_target(&sysroot, &target).unwrap();
        std::fs::create_dir(target.join("nested")).unwrap();
        assert!(validate_mount_target(&sysroot, &target).is_err());
        assert!(validate_mount_target(&sysroot, &sysroot).is_err());
    }

    #[test]
    fn validates_descriptor_relative_ostree_paths() {
        let cases = [
            ("ostree/deploy/default/deployment", true),
            ("", false),
            ("/ostree/deploy/default/deployment", false),
            ("ostree/../deploy/default", false),
            ("../deploy/default", false),
        ];
        for (path, valid) in cases {
            assert_eq!(
                validate_relative_mount_path(Path::new(path)).is_ok(),
                valid,
                "path {path:?}"
            );
        }
        assert_eq!(
            ostree_state_path("example"),
            PathBuf::from("ostree/deploy/example/var")
        );
    }

    #[test]
    fn collects_nested_mount_targets_for_strict_topology_checks() {
        let filesystems = vec![
            Filesystem {
                source: "root".into(),
                target: "/target".into(),
                maj_min: "0:0".into(),
                fstype: "erofs".into(),
                options: "ro".into(),
                uuid: None,
                id: Some(1),
                children: Some(vec![Filesystem {
                    source: "etc".into(),
                    target: "/target/etc".into(),
                    maj_min: "0:0".into(),
                    fstype: "xfs".into(),
                    options: "ro".into(),
                    uuid: None,
                    id: Some(2),
                    children: Some(vec![Filesystem {
                        source: "unexpected".into(),
                        target: "/target/etc/nested".into(),
                        maj_min: "0:0".into(),
                        fstype: "tmpfs".into(),
                        options: "rw".into(),
                        uuid: None,
                        id: Some(3),
                        children: None,
                    }]),
                }]),
            },
            Filesystem {
                source: "var".into(),
                target: "/target/var".into(),
                maj_min: "0:0".into(),
                fstype: "xfs".into(),
                options: "ro".into(),
                uuid: None,
                id: Some(4),
                children: None,
            },
        ];
        let mut targets = std::collections::BTreeSet::new();
        collect_mount_targets(&filesystems, &mut targets);
        assert!(targets.contains(Path::new("/target")));
        assert!(targets.contains(Path::new("/target/etc")));
        assert!(targets.contains(Path::new("/target/var")));
        assert!(targets.contains(Path::new("/target/etc/nested")));
        assert_ne!(
            targets,
            ["/target", "/target/etc", "/target/var"]
                .into_iter()
                .map(PathBuf::from)
                .collect()
        );
    }

    fn record(writable: bool) -> MountRecord {
        let target = PathBuf::from("/target");
        MountRecord {
            sysroot: PathBuf::from("/sysroot"),
            target: target.clone(),
            namespace_dev: 1,
            namespace_ino: 2,
            writable_state: writable,
            mounts: ["", "etc", "var"]
                .into_iter()
                .map(|suffix| MountIdentity {
                    path: if suffix.is_empty() {
                        target.clone()
                    } else {
                        target.join(suffix)
                    },
                    id: 1,
                    source: "source".into(),
                    readonly: !writable || suffix.is_empty(),
                })
                .collect(),
            pending_unmount: None,
        }
    }

    #[test]
    fn validates_expected_mount_topology_and_attributes() {
        assert!(validate_record_shape(&record(false)).is_ok());
        assert!(validate_record_shape(&record(true)).is_ok());

        let mut unexpected = record(false);
        unexpected.mounts[1].path.push("nested");
        assert!(validate_record_shape(&unexpected).is_err());

        let mut writable_root = record(true);
        writable_root.mounts[0].readonly = false;
        assert!(validate_record_shape(&writable_root).is_err());

        let mut foreign_pending = record(false);
        foreign_pending.pending_unmount = Some(MountIdentity {
            path: PathBuf::from("/unrelated"),
            id: 9,
            source: "other".into(),
            readonly: true,
        });
        assert!(validate_record_shape(&foreign_pending).is_err());

        let mut pending = record(false);
        pending.pending_unmount = Some(pending.mounts[2].clone());
        assert!(validate_record_shape(&pending).is_ok());

        assert!(pending_unmount_recovered(&pending, None).unwrap());
        assert!(!pending_unmount_recovered(&pending, Some(&pending.mounts[2])).unwrap());
        let mut changed = pending.mounts[2].clone();
        changed.id += 1;
        assert!(pending_unmount_recovered(&pending, Some(&changed)).is_err());
    }
}
