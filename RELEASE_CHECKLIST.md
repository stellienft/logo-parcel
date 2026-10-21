# Public release checklist

Repository: [stellienft/logo-parcel](https://github.com/stellienft/logo-parcel) — public, MIT-licensed.

## Before a public binary

- [x] License the original source under MIT and add LICENSE.
- [ ] Finalise the production bundle identifier under the organisation's control.
- [x] Bundle standalone Python 3.13.16 and its licence notices; launch it directly from Swift. Relocated-bundle testing passed with an isolated environment.
- [ ] Verify installation on a fresh Mac without developer tools.
- [x] Build and smoke-test Apple silicon; label the beta Apple silicon only. Intel remains unsupported.
- [ ] Confirm the actual minimum supported macOS version on a clean installation.
- [ ] Finalise the app icon, version/build numbers and About information.
- [ ] Exercise real logo files: text, fonts, masks, gradients, images, effects, many artboards and CMYK exports. Inspect exported formats in independent viewers.
- [ ] Check readable error handling, cancellation/large jobs, temporary-cache cleanup and destination disk failures.
- [ ] Retain VectorCraft and runtime licences/notices; pin dependency versions and verify downloaded packages.
- [ ] Sign all bundled executable components appropriately, then sign the app with a Developer ID Application identity and hardened runtime.
- [ ] Create a ZIP or DMG; submit it to Apple's notarisation service; staple and validate the result as applicable.
- [ ] Test downloading and opening the final artifact on a clean Mac using normal Gatekeeper settings.

## GitHub publication

- [x] Create the public repository `stellienft/logo-parcel`.
- [x] Push source, README, build instructions, licence and release checklist. Exclude customer artwork, local paths, binaries and signing credentials.
- [ ] Add screenshots and a short demo of the four-step workflow.
- [ ] Create a version tag and a draft release.
- [ ] Attach the signed/notarised download, checksum, release notes and supported system requirements.
- [ ] Publish only after validating the final download.
- [ ] Link the GitHub release from stellio.com.au. Decide separately whether to add automatic app updates later.

## Official references

- GitHub Releases: https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases
- Apple Developer ID: https://developer.apple.com/developer-id/
- Apple notarisation: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution

No signing credentials or certificates should be committed to the repository. Signing/notarisation must use the owner's developer account and approved credential storage.
