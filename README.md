# VDrive

SwiftUI app for a private photo/video vault. Minimum deployment target: iOS 26.0. This repository currently contains source scaffolding only; it is **not yet a complete Xcode project or installable IPA**.

## Current scaffold
- Photo/video selection through PhotosPicker
- Local AES-GCM encryption
- Key stored in Keychain as device-only (development placeholder)
- GitHub Actions workflow placeholder

## Not implemented yet
- Xcode project and app signing
- Google OAuth and Google Drive upload/download
- PIN/Face ID gate and secure key wrapping/recovery
- Remote integrity verification and safe original deletion

**Do not use this prototype for irreplaceable files.** The current device-only key cannot restore encrypted files after reinstall/device loss. Before cloud sync, implement and test a deliberate key recovery design; never upload plaintext media.

## Next steps
1. Add a valid Xcode project with scheme `VDrive` and iOS deployment target.
2. Implement PIN + Face ID and key wrapping/recovery.
3. Add Google Drive OAuth, encrypted blob sync, integrity checks, and restore tests.
4. Build/test with GitHub Actions; export an IPA only after signing is configured.


## iOS 26+ and UI

The Xcode project links `MetalFxKit` from `https://github.com/Jakubantalik/Libraries.dev` on branch `main` (iOS 17+). The media-picker control uses a chromatic liquid-metal circle; the app title uses `MetalText` and a small status chip uses `MetalBadge`.

The package's Metal shader resources need an Xcode build; SwiftPM resolution alone is not a substitute for compiling the app target. CI builds an unsigned simulator app. A signed device IPA still requires signing/provisioning configuration.


The app targets iOS 26.0 and newer. UI should use native iOS 26 Liquid Glass materials and system controls where appropriate.
