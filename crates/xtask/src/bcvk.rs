//! Shared helpers for building `bcvk` CLI arguments.
//!
//! Both the sysext dev-VM flow and the tmt test runner need to translate
//! `BOOTC_*` environment variables into `bcvk libvirt run` flags.  This
//! module centralises that logic so the two code paths stay in sync.

use anyhow::Result;
use camino::{Utf8Path, Utf8PathBuf};
use fn_error_context::context;

use crate::{Bootloader, SealState};

/// Default directory for secure boot test keys.
pub(crate) const DEFAULT_SB_KEYS_DIR: &str = "target/test-secureboot";

/// Resolved bcvk install options, ready to be turned into CLI args.
///
/// Construct via [`BcvkInstallOpts::from_env`] (reads `BOOTC_*` env vars)
/// or populate fields directly.
#[derive(Debug)]
pub(crate) struct BcvkInstallOpts {
    pub(crate) composefs_backend: bool,
    pub(crate) bootloader: Option<Bootloader>,
    pub(crate) filesystem: Option<String>,
    pub(crate) seal_state: Option<SealState>,
    pub(crate) kargs: Vec<String>,
    pub(crate) secure_boot_keys: Option<Utf8PathBuf>,
}

impl Default for BcvkInstallOpts {
    fn default() -> Self {
        Self {
            composefs_backend: false,
            bootloader: None,
            filesystem: None,
            seal_state: None,
            kargs: Vec::new(),
            secure_boot_keys: None,
        }
    }
}

impl BcvkInstallOpts {
    /// Build from `BOOTC_*` environment variables.
    ///
    /// `BOOTC_variant=composefs` implies `composefs_backend = true`.
    pub(crate) fn from_env() -> Self {
        let composefs_backend = std::env::var("BOOTC_variant")
            .map(|v| v == "composefs")
            .unwrap_or(false);

        let bootloader = std::env::var("BOOTC_bootloader")
            .ok()
            .and_then(|v| match v.as_str() {
                "grub" => Some(Bootloader::Grub),
                "systemd" => Some(Bootloader::Systemd),
                _ => None,
            });

        let filesystem = std::env::var("BOOTC_filesystem").ok();

        let seal_state = std::env::var("BOOTC_seal_state")
            .ok()
            .and_then(|v| match v.as_str() {
                "sealed" => Some(SealState::Sealed),
                "unsealed" => Some(SealState::Unsealed),
                _ => None,
            });
        let secure_boot_keys = std::env::var("BOOTC_secureboot_dir")
            .ok()
            .filter(|path| !path.is_empty())
            .map(Utf8PathBuf::from);

        Self {
            composefs_backend,
            bootloader,
            filesystem,
            seal_state,
            kargs: Vec::new(),
            secure_boot_keys,
        }
    }

    /// Return the install-related args for `bcvk libvirt run`.
    ///
    /// This covers `--composefs-backend`, `--filesystem`, `--bootloader`,
    /// and `--karg` flags.  Note that `--bootloader` and `--filesystem`
    /// are only valid when `--composefs-backend` is also set (bcvk
    /// enforces this via a clap `requires` relationship).
    pub(crate) fn install_args(&self) -> Vec<String> {
        let mut args = Vec::new();
        if self.composefs_backend {
            args.push("--composefs-backend".into());
            let fs = self.filesystem.as_deref().unwrap_or("ext4");
            args.push(format!("--filesystem={fs}"));
            if let Some(b) = &self.bootloader {
                args.push(format!("--bootloader={b}"));
            }
        }
        for k in &self.kargs {
            args.push(format!("--karg={k}"));
        }
        args
    }

    fn is_sealed(&self) -> bool {
        self.seal_state
            .as_ref()
            .is_some_and(|s| *s == SealState::Sealed)
    }

    fn secure_boot_keys_dir(&self) -> &Utf8Path {
        self.secure_boot_keys
            .as_deref()
            .unwrap_or_else(|| Utf8Path::new(DEFAULT_SB_KEYS_DIR))
    }

    /// Return firmware / secure-boot args for `bcvk libvirt run`.
    ///
    /// For sealed images the secure boot keys directory must already
    /// exist; the caller can use `ensure_secureboot_keys` first.
    #[context("Building firmware arguments")]
    pub(crate) fn firmware_args(&self) -> Result<Vec<String>> {
        let sb_keys_dir = self.secure_boot_keys_dir();
        if self.is_sealed() {
            if sb_keys_dir.try_exists()? {
                let sb_keys_dir = sb_keys_dir.canonicalize_utf8()?;
                Ok(vec![
                    "--firmware=uefi-secure".into(),
                    format!("--secure-boot-keys={sb_keys_dir}"),
                ])
            } else {
                anyhow::bail!(
                    "Sealed image but no secure boot keys at {sb_keys_dir}. \
                     Run 'just generate-secureboot-keys' to generate them."
                );
            }
        } else {
            // Use insecure firmware for all non-sealed images.  The stock
            // OVMF Secure Boot key database does not include the distro
            // signing keys needed to verify shim/grub, so Secure Boot
            // verification fails at the firmware level with
            // "Security Violation".  Sealed images work because they enroll
            // custom test keys and use a test-signed systemd-boot.
            Ok(vec!["--firmware=uefi-insecure".into()])
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sealed(keys: Option<Utf8PathBuf>) -> BcvkInstallOpts {
        BcvkInstallOpts {
            seal_state: Some(SealState::Sealed),
            secure_boot_keys: keys,
            ..Default::default()
        }
    }

    #[test]
    fn firmware_args_use_configured_keys_without_environment() {
        let temp = tempfile::tempdir().unwrap();
        let keys = Utf8PathBuf::from_path_buf(temp.path().join("keys")).unwrap();
        std::fs::create_dir(&keys).unwrap();
        let args = sealed(Some(keys.clone())).firmware_args().unwrap();
        assert_eq!(
            args,
            vec![
                "--firmware=uefi-secure".to_owned(),
                format!("--secure-boot-keys={}", keys.canonicalize_utf8().unwrap())
            ]
        );
    }

    #[test]
    fn firmware_args_report_missing_configured_keys_and_skip_unsealed_keys() {
        let temp = tempfile::tempdir().unwrap();
        let missing = Utf8PathBuf::from_path_buf(temp.path().join("missing")).unwrap();
        let error = sealed(Some(missing.clone())).firmware_args().unwrap_err();
        assert!(format!("{error:#}").contains(missing.as_str()));
        let args = BcvkInstallOpts {
            secure_boot_keys: Some(missing),
            ..Default::default()
        }
        .firmware_args()
        .unwrap();
        assert_eq!(args, vec!["--firmware=uefi-insecure".to_owned()]);
    }

    #[test]
    fn defaults_to_the_existing_secure_boot_key_directory() {
        assert_eq!(
            BcvkInstallOpts::default().secure_boot_keys_dir(),
            Utf8Path::new(DEFAULT_SB_KEYS_DIR)
        );
    }
}
