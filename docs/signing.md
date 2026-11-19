# Signing

Tinycast has two signing identities:

- **Local builds** sign with a **stable self-signed identity** called `Tinycast Self-Signed`.
  Keeping the _same_ identity on every build is what makes macOS remember the Accessibility
  permission across rebuilds — ad-hoc signing changes every build and macOS forgets the grant. Each
  contributor creates their own, once (§1).
- **Releases** sign with a **Developer ID** and are notarized. That identity belongs to whoever
  publishes a build (§2), so a contributor never needs it.

## 1. Create the `Tinycast Self-Signed` identity (once)

```sh
./Scripts/local-signing.sh
```

It generates a self-signed code-signing certificate and key, imports them into a keychain of their
own (`~/Library/Keychains/tinycast-signing.keychain-db`, password `tinycast`), authorises `codesign`
for it, and adds that keychain to the user's search list. Its own keychain is what lets `codesign`
use the key without a GUI approval prompt, so headless `xcodebuild` works; the password is public and
protects nothing but a certificate anyone can recreate. The keychain locks on sleep — unlock it with
`security unlock-keychain -p tinycast ~/Library/Keychains/tinycast-signing.keychain-db` if a build
reports `errSecInternalComponent`.

Verify it's there:

```sh
security find-identity -p codesigning | grep "Tinycast Self-Signed"
```

Now local builds (Xcode, VS Code F5, `xcodebuild`) sign with it, and you grant Accessibility once.
Re-running the script is a no-op that only unlocks the keychain.

<details>
<summary>Doing it by hand</summary>

```sh
# Generate a self-signed code-signing cert (10-year, codeSigning use).
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout /tmp/tc-key.pem -out /tmp/tc-cert.pem \
  -subj "/CN=Tinycast Self-Signed" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

# Bundle it as a .p12 (the non-empty password keeps `security import` happy). Add `-legacy` when
# `openssl` is Homebrew's OpenSSL 3 or later; macOS's `security import` rejects its default ciphers.
openssl pkcs12 -export -legacy -inkey /tmp/tc-key.pem -in /tmp/tc-cert.pem \
  -name "Tinycast Self-Signed" -out /tmp/tc.p12 -passout pass:tinycast

security import /tmp/tc.p12 -k ~/Library/Keychains/login.keychain-db \
  -P tinycast -A -T /usr/bin/codesign

rm -f /tmp/tc-key.pem /tmp/tc-cert.pem /tmp/tc.p12
```

The login keychain works from Xcode but needs a keychain password for `set-key-partition-list`
before a headless `codesign` can use the key; the script's separate keychain avoids that.

</details>


## 2. Publishing a build

This fork has no release workflow, so `Scripts/package-release.sh` reads its five values from the
environment of whoever runs it:

| Variable                    | Holds                                                         |
| --------------------------- | ------------------------------------------------------------- |
| `DEVELOPER_ID_P12_BASE64`   | the Developer ID Application certificate and key, base64 `.p12` |
| `DEVELOPER_ID_P12_PASSWORD` | the password the `.p12` was exported with                     |
| `NOTARY_KEY_P8_BASE64`      | an App Store Connect API key (`.p8`) with Developer access, base64 |
| `NOTARY_KEY_ID`             | that key's ID                                                 |
| `NOTARY_ISSUER_ID`          | its issuer ID                                                 |

Export the Developer ID identity alone — `security export -t identities` bundles every identity in
the keychain. In Keychain Access, open **My Certificates**, select the **Developer ID Application**
certificate, choose **File → Export Items…**, and save a `.p12` with a password. Then export each
value into the shell that runs the script; never put the password or private key in a command
argument that history would keep.

**Renew the certificate yearly.** Apple issues a Developer ID certificate for about 13 months. A
shipped build stays valid after renewal because its signature carries Apple's timestamp, and macOS
matches the team rather than the certificate. The API key does not expire.

## Hardened runtime

**Release only**, on both targets: `ENABLE_HARDENED_RUNTIME: YES`, which notarization requires. Debug
must stay without it — hardened runtime turns on library validation, and Xcode's
`Tinycast Legacy Dev.debug.dylib` is refused at launch because a self-signed identity carries no Team ID for
the loader to match. The flag is not part of the designated requirement, so turning it on costs no
Accessibility grant. Each entitlement in `Tinycast/Tinycast.entitlements` earns its place:

| Entitlement | Without it |
| --- | --- |
| `com.apple.security.cs.allow-jit` | JavaScriptCore cannot JIT, and every extension command runs on the interpreter |
| `com.apple.security.automation.apple-events` | Every Apple event is refused with `-1743` and no prompt — Get Info, the Finder selection an extension reads, and the System Events–driven system actions all die silently |
| `com.apple.security.device.camera` | The camera prompt never appears and access resolves as denied |
| `com.apple.security.personal-information.calendars` | `requestFullAccessToEvents()` returns `false` in milliseconds with no dialog, and Tinycast never appears under System Settings › Calendars |

**A usage string is not enough under the hardened runtime.** `tccd` checks the matching entitlement
*before* it prompts, and without it logs "requires entitlement … but it is missing" and denies on the
spot — no dialog, no error, status still `.notDetermined`. A grant saved before the hardened runtime
arrived keeps working, since `tccd` does not re-check it, which is why this surfaces only on fresh
installs. Adding a protected resource therefore means adding its usage string *and* its entitlement.

`RESOURCE_ENTITLEMENTS` in `Scripts/verify-signature.sh` maps every protected resource's usage string
to its entitlement, including resources Tinycast does not use. That grants nothing — only
`Tinycast.entitlements` does, and a row whose usage string `Info.plist` doesn't declare is skipped. It
is there so a future feature that adds the usage string but forgets the entitlement fails the release
instead of shipping a prompt that can never appear.

Nothing else is needed: the only `dlopen` is Apple's own IOBluetooth, so library validation is left
on, and `node`, `ray` and shell commands are separate processes it never reaches. Bluetooth has no
hardened-runtime entitlement.

`./Scripts/verify-signature.sh <path-to-.app>` asserts all of this — the runtime flag and a
timestamped Developer ID signature on the app *and* every helper, an intact nested seal, no
`get-task-allow`, and an entitlement for every usage string `Info.plist` declares. Run it before submitting: a nested binary missing the runtime flag is the most common notarization
rejection, and a usage string missing its entitlement ships a permission that can never be granted.

## Update trust

There is no in-app updater and no released channel in this fork: whatever you build next is the
update.

## Developer ID stays out of the project

**The Developer ID identity is a release-machine fact.** It is passed as `SIGNING_IDENTITY` when
running `Scripts/package-release.sh`, never committed: `project.yml` keeps signing with
`Tinycast Self-Signed`, so a contributor builds with the one they created in §1 — same name, their
own key, never shared.

macOS keys a TCC grant to the app's designated requirement, so a certificate renewal keeps
Accessibility and every other grant, while a new team asks for each one again.

## Quarantine

A release is notarized and its DMG stapled, so Gatekeeper opens a downloaded copy without a warning.
A local `build-dmg.sh` DMG is self-signed and never notarized, so it is for testing on the Mac that
built it, not for sharing.
