# iOS real-device convenience scripts

These scripts automate the local Mac + iPhone development loop for the Health Bridge companion.

## Device defaults

The scripts read the target device and bundle ID from environment variables or from
an ignored local file at `scripts/ios-device-local.env`:

```bash
# scripts/ios-device-local.env  (gitignored)
export DEVICE_ID=<your-device-id>
export BUNDLE_ID=<your-companion-bundle-id>
# Optional if you have not configured signing in Xcode:
export DEVELOPMENT_TEAM=<your-apple-developer-team-id>
# Optional manual-signing fallback when you installed a profile yourself:
export CODE_SIGN_STYLE=Manual
export PROVISIONING_PROFILE_SPECIFIER=<your-profile-name>
export CODE_SIGN_IDENTITY=<matching-apple-development-certificate-hash-or-name>
# Optional if you want Xcode to create/update signing assets automatically:
export ALLOW_PROVISIONING_UPDATES=1
# Optional if Xcode may need to register a new device for development builds:
export ALLOW_PROVISIONING_DEVICE_REGISTRATION=1
```

Set `DEVICE_ID` and `BUNDLE_ID` for your local device/build before running the
helpers. Do not commit the local env file; each developer should use their own
device identifier, bundle identifier, signing team, signing certificate,
provisioning profile, and provisioning policy. Start from the tracked example if
useful:

```bash
cp scripts/ios-device-local.env.example scripts/ios-device-local.env
```

## Common commands

```bash
scripts/ios-device-status.sh   # check wired/wireless device state
scripts/ios-device-build.sh    # CLI xcodebuild for the real iPhone
scripts/ios-device-install.sh  # install built .app through devicectl
scripts/ios-device-launch.sh   # launch installed app
scripts/ios-device-run.sh      # build + install + launch
```

If SSH `xcodebuild` fails at `CodeSign ... errSecInternalComponent`, run from the Mac GUI session instead:

```bash
open scripts/ios-device-build-local.command
open scripts/ios-device-run-local.command
```

The `.command` wrappers write logs under `.tmp/` and keep the Terminal window open. They are useful because macOS keychain/codesign access can differ between GUI Terminal and SSH sessions.

### Signing and keychain troubleshooting

Prefer Xcode and Keychain Access over password-accepting shell helpers:

1. Open Xcode in the signed-in Mac GUI session and confirm the Apple account under **Xcode → Settings → Accounts**.
2. Open the project, select the app target, and confirm the local team under **Signing & Capabilities**.
3. In Keychain Access, unlock the login keychain through the macOS UI and confirm that the Apple Development certificate has its private key.
4. Run `security find-identity -v -p codesigning` only to inspect available identities; it does not need the login password.
5. Retry `open scripts/ios-device-build-local.command` from the GUI session.

Do not paste your macOS password into chat, issues, environment files, command arguments, or repository scripts. Do not copy signing certificates, private keys, provisioning profiles, or keychain dumps into support requests. If the GUI steps do not resolve signing, use Apple's current Xcode signing documentation or contact Apple Developer Support rather than distributing a keychain-repair script.

## One-time wireless debugging setup

1. Connect iPhone to Mac once.
2. Xcode → Window → Devices and Simulators.
3. Select the iPhone.
4. Enable **Connect via network**.
5. Confirm `scripts/ios-device-status.sh` reports `transportType: localNetwork` after unplugging.
