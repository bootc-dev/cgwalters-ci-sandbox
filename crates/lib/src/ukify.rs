//! Build Unified Kernel Images (UKI) using ukify.
//!
//! This module provides functionality to build UKIs by computing the necessary
//! arguments from a container image and invoking the ukify tool. Default V1
//! UKIs also carry the legacy V2 digest for older bootc clients.

use std::ffi::{OsStr, OsString};
use std::process::{Command, Output};

use anyhow::{Context, Result};
use bootc_utils::CommandRunExt;
use camino::Utf8Path;
use cap_std_ext::cap_std::fs::Dir;
use fn_error_context::context;
use linux_kernel_cmdline::utf8::Cmdline;

use composefs::erofs::format::FormatVersion;
use composefs::fsverity::{FsVerityHashValue, Sha512HashValue};
use composefs_ctl::composefs;

use crate::bootc_composefs::digest::compute_composefs_digest;
use crate::bootc_composefs::status::build_composefs_karg;
use crate::cli::ErofsVersionArg;
use crate::kernel::KernelInternal;

const COMPOSEFS_DIGEST_V1_FEATURE: &str = "/usr/lib/bootc/initramfs-features/composefs-digest-v1";
const COMPOSEFS_DIGEST_V1_FEATURE_CONTENT: &[u8] = b"composefs-digest-v1 state-v1\n";

/// Query `lsinitrd` without unpacking or executing any initramfs contents.
fn run_lsinitrd(args: &[&OsStr]) -> Result<Output> {
    Command::new("lsinitrd")
        .args(args)
        .output()
        .context("Running lsinitrd")
}

fn resolve_erofs_version_with<F>(
    requested: Option<ErofsVersionArg>,
    initramfs: &Utf8Path,
    run: F,
) -> Result<FormatVersion>
where
    F: Fn(&[&OsStr]) -> Result<Output>,
{
    if let Some(ErofsVersionArg::V2) = requested {
        return Ok(FormatVersion::V2);
    }

    let archive_args = [initramfs.as_ref()];
    let archive =
        run(&archive_args).with_context(|| format!("Validating initramfs {initramfs}"))?;
    if !archive.status.success() {
        anyhow::bail!(
            "Validating initramfs {initramfs} failed: lsinitrd could not read the archive: {}",
            String::from_utf8_lossy(&archive.stderr).trim()
        );
    }

    let feature_args = [
        OsStr::new("--file"),
        OsStr::new(COMPOSEFS_DIGEST_V1_FEATURE),
        initramfs.as_ref(),
    ];
    let feature = run(&feature_args)
        .with_context(|| format!("Reading composefs capability from initramfs {initramfs}"))?;
    let marker_listed = archive
        .stdout
        .windows(COMPOSEFS_DIGEST_V1_FEATURE.as_bytes().len())
        .any(|entry| entry == COMPOSEFS_DIGEST_V1_FEATURE.as_bytes());
    let marker_present = if feature.stdout == COMPOSEFS_DIGEST_V1_FEATURE_CONTENT {
        true
    } else if feature.stdout.is_empty() && !marker_listed && !feature.status.success() {
        // lsinitrd reports a missing file with a nonzero exit status on some
        // supported dracut versions.
        false
    } else if feature.stdout.is_empty() && !marker_listed && feature.status.success() {
        // Other supported versions successfully extract zero bytes when a
        // requested file is absent.  The successful full-archive probe above
        // has already ruled out a malformed archive.
        false
    } else {
        anyhow::bail!(
            "Initramfs {initramfs} has an unexpected composefs V1 capability marker; rebuild its initramfs"
        );
    };
    if marker_present {
        return Ok(FormatVersion::V1);
    }

    if requested == Some(ErofsVersionArg::V1) {
        anyhow::bail!(
            "--erofs-version=v1 requires an initramfs with composefs V1 support; rebuild the initramfs with current bootc or use --erofs-version=v2"
        );
    }
    tracing::warn!(
        "Initramfs lacks composefs V1 support; generating a V2-only UKI for compatibility"
    );
    Ok(FormatVersion::V2)
}

fn resolve_erofs_version(
    requested: Option<ErofsVersionArg>,
    initramfs: &Utf8Path,
) -> Result<FormatVersion> {
    resolve_erofs_version_with(requested, initramfs, run_lsinitrd)
}

fn composefs_kargs_for_uki(
    preferred_digest: Sha512HashValue,
    preferred_version: FormatVersion,
    compatibility_v2_digest: Option<Sha512HashValue>,
    allow_missing_fsverity: bool,
) -> Vec<String> {
    let mut kargs = vec![build_composefs_karg(
        preferred_digest,
        preferred_version,
        allow_missing_fsverity,
    )];
    if let Some(v2_digest) = compatibility_v2_digest {
        kargs.push(build_composefs_karg(
            v2_digest,
            FormatVersion::V2,
            allow_missing_fsverity,
        ));
    }
    kargs
}

/// Build a UKI from the given rootfs.
///
/// This function:
/// 1. Verifies that ukify is available
/// 2. Finds the kernel in the rootfs
/// 3. Computes the composefs digest
/// 4. Reads kernel arguments from kargs.d
/// 5. Appends any additional kargs provided via --karg
/// 6. Invokes ukify with computed arguments plus any pass-through args
#[context("Building UKI")]
pub(crate) async fn build_ukify(
    rootfs: &Utf8Path,
    extra_kargs: &[String],
    args: &[OsString],
    kernel: Option<KernelInternal>,
    allow_missing_fsverity: bool,
    erofs_version: Option<ErofsVersionArg>,
    write_dumpfile_to: Option<&Utf8Path>,
) -> Result<()> {
    // Warn if --karg is used (temporary workaround)
    if !extra_kargs.is_empty() {
        tracing::warn!(
            "The --karg flag is temporary and will be removed as soon as possible \
            (https://github.com/bootc-dev/bootc/issues/1826)"
        );
    }

    // Open the rootfs directory
    let root = Dir::open_ambient_dir(rootfs, cap_std_ext::cap_std::ambient_authority())
        .with_context(|| format!("Opening rootfs {rootfs}"))?;

    let kernel_final = match kernel {
        Some(ref kernel) => kernel,
        None => &crate::kernel::find_kernel(&root)?
            .ok_or_else(|| anyhow::anyhow!("No kernel found in {rootfs}"))?,
    };

    // Extract vmlinuz and initramfs paths, or bail if this is already a UKI
    let (vmlinuz_path, initramfs_path) = match &kernel_final.k_type {
        crate::kernel::KernelType::Vmlinuz { path, initramfs } => (path, initramfs),
        crate::kernel::KernelType::Uki { path, .. } => {
            anyhow::bail!("Cannot build UKI: rootfs already contains a UKI at {path}");
        }
    };

    // Verify kernel and initramfs exist
    //
    // NOTE: Not using cap_std here as the vmlinuz/initramfs path from
    // args can be outside of "rootfs"
    if kernel.is_some() {
        if !vmlinuz_path.exists() {
            anyhow::bail!("Kernel not found at {vmlinuz_path}");
        }

        if !initramfs_path.exists() {
            anyhow::bail!("Initramfs not found at {initramfs_path}");
        }
    } else {
        if !root
            .try_exists(&vmlinuz_path)
            .context("Checking for vmlinuz")?
        {
            anyhow::bail!("Kernel not found at {vmlinuz_path}");
        }

        if !root
            .try_exists(&initramfs_path)
            .context("Checking for initramfs")?
        {
            anyhow::bail!("Initramfs not found at {initramfs_path}");
        }
    }

    let initramfs_archive = if initramfs_path.is_absolute() {
        initramfs_path.clone()
    } else {
        rootfs.join(initramfs_path)
    };
    let erofs_version = resolve_erofs_version(erofs_version, &initramfs_archive)?;

    // Validate the selected initramfs before checking ukify.  This keeps an
    // invalid archive actionable even in minimal producer environments where
    // ukify is not installed yet.
    if !crate::utils::have_executable("ukify")? {
        anyhow::bail!(
            "ukify executable not found in PATH. Please install systemd-ukify or equivalent."
        );
    }

    // Compute the preferred digest. With V1, retain the dumpfile behavior for
    // that preferred digest and add a legacy V2 compatibility digest below.
    let composefs_digest =
        compute_composefs_digest(rootfs, erofs_version, write_dumpfile_to).await?;
    let composefs_digest = Sha512HashValue::from_hex(&composefs_digest)
        .context("Parsing computed composefs digest")?;
    let compatibility_v2_digest = if erofs_version == FormatVersion::V1 {
        let digest = compute_composefs_digest(rootfs, FormatVersion::V2, None).await?;
        Some(Sha512HashValue::from_hex(&digest).context("Parsing computed V2 digest")?)
    } else {
        None
    };

    // Get kernel arguments from kargs.d
    let mut cmdline = crate::bootc_kargs::get_kargs_in_root(&root, std::env::consts::ARCH)?;

    // Add the composefs digest, tagging the karg with the same EROFS format
    // version used to compute it so it stays boot-compatible (see
    // `build_composefs_karg`).
    for karg in composefs_kargs_for_uki(
        composefs_digest,
        erofs_version,
        compatibility_v2_digest,
        allow_missing_fsverity,
    ) {
        cmdline.extend(&Cmdline::from(karg));
    }

    // Add any extra kargs provided via --karg
    for karg in extra_kargs {
        cmdline.extend(&Cmdline::from(karg));
    }

    let cmdline_str = cmdline.to_string();

    // Build the ukify command with cwd set to rootfs so paths can be relative
    let mut cmd = Command::new("ukify");
    cmd.current_dir(rootfs);
    cmd.arg("build")
        .arg("--linux")
        .arg(&vmlinuz_path)
        .arg("--initrd")
        .arg(&initramfs_path)
        .arg("--uname")
        .arg(&kernel_final.kernel.version)
        .arg("--cmdline")
        .arg(&cmdline_str)
        .arg("--os-release")
        .arg("@usr/lib/os-release");

    // Add pass-through arguments
    cmd.args(args);

    tracing::debug!("Executing ukify: {:?}", cmd);

    // Run ukify
    cmd.run_inherited().context("Running ukify")?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use bootc_utils::create_minimal_pe;

    use super::*;
    use std::{fs, io::Write, process::Stdio};

    fn build_cpio_initramfs(marker: Option<&[u8]>) -> Result<tempfile::TempDir> {
        let tempdir = tempfile::tempdir()?;
        let root = tempdir.path();
        let archive = root.join("initramfs.img");
        let mut filenames = b"etc/legacy\0".to_vec();
        fs::create_dir_all(root.join("etc"))?;
        fs::write(root.join("etc/legacy"), b"legacy\n")?;
        if let Some(marker) = marker {
            let marker_path = root.join(COMPOSEFS_DIGEST_V1_FEATURE.trim_start_matches('/'));
            fs::create_dir_all(marker_path.parent().expect("marker has a parent"))?;
            fs::write(&marker_path, marker)?;
            filenames.extend_from_slice(
                COMPOSEFS_DIGEST_V1_FEATURE
                    .trim_start_matches('/')
                    .as_bytes(),
            );
            filenames.push(0);
        }

        let mut command = Command::new("cpio");
        command
            .current_dir(root)
            .args(["--create", "--format=newc", "--null"])
            .stdin(Stdio::piped())
            .stdout(fs::File::create(&archive)?);
        let mut child = command.spawn().context("Creating CPIO initramfs fixture")?;
        child
            .stdin
            .take()
            .expect("stdin was requested")
            .write_all(&filenames)?;
        anyhow::ensure!(
            child.wait()?.success(),
            "Creating CPIO initramfs fixture failed"
        );
        Ok(tempdir)
    }

    #[tokio::test]
    async fn test_build_ukify_no_kernel() {
        let tempdir = tempfile::tempdir().unwrap();
        let path = Utf8Path::from_path(tempdir.path()).unwrap();

        let result =
            build_ukify(path, &[], &[], None, false, Some(ErofsVersionArg::V2), None).await;
        assert!(result.is_err());
        let err = format!("{:#}", result.unwrap_err());
        assert!(
            err.contains("No kernel found") || err.contains("ukify executable not found"),
            "Unexpected error message: {err}"
        );
    }

    #[tokio::test]
    async fn test_build_ukify_already_uki() {
        let tempdir = tempfile::tempdir().unwrap();
        let path = Utf8Path::from_path(tempdir.path()).unwrap();

        // Create a UKI structure
        fs::create_dir_all(tempdir.path().join("boot/EFI/Linux")).unwrap();
        fs::write(
            tempdir.path().join("boot/EFI/Linux/test.efi"),
            &create_minimal_pe(),
        )
        .unwrap();

        let result =
            build_ukify(path, &[], &[], None, false, Some(ErofsVersionArg::V2), None).await;
        assert!(result.is_err());
        let err = format!("{:#}", result.unwrap_err());
        assert!(
            err.contains("already contains a UKI") || err.contains("ukify executable not found"),
            "Unexpected error message: {err}"
        );
    }

    #[test]
    fn test_composefs_kargs_for_uki() {
        let v1 = Sha512HashValue::EMPTY;
        let v2 = Sha512HashValue::from_hex("aa".repeat(64)).unwrap();
        for (version, fallback, expected_len, expected_prefixes) in [
            (
                FormatVersion::V1,
                Some(v2),
                2,
                ["composefs.digest=v1-sha512-12:", "composefs="],
            ),
            (FormatVersion::V2, None, 1, ["composefs=", ""]),
        ] {
            let kargs = composefs_kargs_for_uki(v1.clone(), version, fallback, false);
            assert_eq!(kargs.len(), expected_len);
            for (karg, prefix) in kargs.iter().zip(expected_prefixes) {
                assert!(karg.starts_with(prefix), "unexpected karg: {karg}");
            }
        }
    }

    #[test]
    fn resolve_erofs_version_uses_initramfs_capabilities() {
        use std::os::unix::process::ExitStatusExt;

        fn output(success: bool, stdout: &[u8]) -> Output {
            Output {
                status: std::process::ExitStatus::from_raw(if success { 0 } else { 1 << 8 }),
                stdout: stdout.into(),
                stderr: b"fixture error".to_vec(),
            }
        }

        let initramfs = Utf8Path::new("/test/initramfs.img");
        for (name, requested, responses, expected) in [
            (
                "auto capable",
                None,
                vec![
                    output(true, b""),
                    output(true, COMPOSEFS_DIGEST_V1_FEATURE_CONTENT),
                ],
                Ok(FormatVersion::V1),
            ),
            (
                "auto legacy",
                None,
                vec![output(true, b""), output(false, b"")],
                Ok(FormatVersion::V2),
            ),
            (
                "explicit v1 legacy",
                Some(ErofsVersionArg::V1),
                vec![output(true, b""), output(false, b"")],
                Err("--erofs-version=v1 requires"),
            ),
            (
                "malformed archive",
                None,
                vec![output(false, b"")],
                Err("could not read the archive"),
            ),
            (
                "unexpected marker",
                None,
                vec![output(true, b""), output(true, b"wrong\n")],
                Err("unexpected composefs V1 capability marker"),
            ),
            (
                "explicit v2 skips probing",
                Some(ErofsVersionArg::V2),
                vec![],
                Ok(FormatVersion::V2),
            ),
        ] {
            let calls = std::cell::RefCell::new(Vec::new());
            let responses = std::cell::RefCell::new(responses.into_iter());
            let result = resolve_erofs_version_with(requested, initramfs, |args| {
                calls.borrow_mut().push(
                    args.iter()
                        .map(|arg| arg.to_string_lossy().into_owned())
                        .collect::<Vec<_>>(),
                );
                responses
                    .borrow_mut()
                    .next()
                    .ok_or_else(|| anyhow::anyhow!("unexpected lsinitrd invocation"))
            });
            match expected {
                Ok(version) => assert_eq!(result.unwrap(), version, "case {name}"),
                Err(message) => assert!(
                    result.unwrap_err().to_string().contains(message),
                    "case {name}"
                ),
            }
            if requested == Some(ErofsVersionArg::V2) {
                assert!(calls.borrow().is_empty(), "case {name}");
            } else {
                assert_eq!(calls.borrow()[0], ["/test/initramfs.img"], "case {name}");
                if calls.borrow().len() == 2 {
                    assert_eq!(
                        calls.borrow()[1],
                        ["--file", COMPOSEFS_DIGEST_V1_FEATURE, "/test/initramfs.img",],
                        "case {name}"
                    );
                }
            }
        }
    }

    #[test]
    fn resolve_erofs_version_fails_closed_when_lsinitrd_is_unavailable() {
        let error = resolve_erofs_version_with(None, Utf8Path::new("/test/initramfs.img"), |_| {
            Err(anyhow::anyhow!("lsinitrd executable not found"))
        })
        .unwrap_err();
        assert!(error.to_string().contains("Validating initramfs"));
    }

    #[test]
    fn resolve_erofs_version_with_real_cpio_initramfs() -> Result<()> {
        let legacy = build_cpio_initramfs(None)?;
        let legacy_archive = Utf8Path::from_path(&legacy.path().join("initramfs.img"))
            .expect("temporary path is UTF-8")
            .to_owned();
        assert_eq!(
            resolve_erofs_version(None, &legacy_archive)?,
            FormatVersion::V2
        );
        assert!(
            resolve_erofs_version(Some(ErofsVersionArg::V1), &legacy_archive)
                .unwrap_err()
                .to_string()
                .contains("--erofs-version=v1 requires")
        );

        let capable = build_cpio_initramfs(Some(COMPOSEFS_DIGEST_V1_FEATURE_CONTENT))?;
        let capable_archive = Utf8Path::from_path(&capable.path().join("initramfs.img"))
            .expect("temporary path is UTF-8")
            .to_owned();
        let version = resolve_erofs_version(None, &capable_archive)?;
        assert_eq!(version, FormatVersion::V1);
        let kargs = composefs_kargs_for_uki(
            Sha512HashValue::EMPTY,
            version,
            Some(Sha512HashValue::from_hex("aa".repeat(64))?),
            false,
        );
        assert!(kargs[0].starts_with("composefs.digest=v1-sha512-12:"));
        assert!(kargs[1].starts_with("composefs="));

        let bad_marker = build_cpio_initramfs(Some(b"unexpected\n"))?;
        let bad_marker_archive = Utf8Path::from_path(&bad_marker.path().join("initramfs.img"))
            .expect("temporary path is UTF-8")
            .to_owned();
        assert!(
            resolve_erofs_version(None, &bad_marker_archive)
                .unwrap_err()
                .to_string()
                .contains("unexpected composefs V1 capability marker")
        );

        let corrupt = tempfile::NamedTempFile::new()?;
        fs::write(corrupt.path(), b"not an initramfs")?;
        let corrupt_archive = Utf8Path::from_path(corrupt.path()).expect("temporary path is UTF-8");
        assert!(
            resolve_erofs_version(None, corrupt_archive)
                .unwrap_err()
                .to_string()
                .contains("could not read the archive")
        );
        assert_eq!(
            resolve_erofs_version(Some(ErofsVersionArg::V2), corrupt_archive)?,
            FormatVersion::V2
        );
        Ok(())
    }
}
