# Signed, notarized releases

Out of the box the release workflow signs builds ad hoc, so the first launch of a downloaded
Lucente is blocked until the user clicks **Open Anyway** in System Settings. With a Developer ID
certificate and an App Store Connect API key stored as repository secrets, the same workflow signs
the app and the DMG with Developer ID and notarizes them, and Lucente opens like any other app.

You need a paid Apple Developer Program membership, and you must be the team's **Account Holder**
(only the Account Holder can create Developer ID certificates). It takes about five minutes.

**Already shipping iOS apps on the same team?** The team is shared, but neither piece carries over
as is. Apple Development and App Store distribution certificates aren't accepted by Gatekeeper
for apps downloaded from the web; only Developer ID is. And an existing App Store Connect key
used for other automation (App Manager and up) shouldn't go into this repository's secrets: a key
here should be able to notarize and nothing else, and be revocable on its own.

## 1. Create a Developer ID Application certificate

In Xcode:

1. **Xcode › Settings…** (⌘,) › **Accounts**.
2. Select your Apple ID, then your team, and click **Manage Certificates…**.
3. Click **+** in the bottom-left corner and choose **Developer ID Application**.

Xcode generates the private key in your login keychain and installs the certificate. Check it:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

The private key exists only on this Mac. Keep a backup: in **Keychain Access › My
Certificates**, right-click the certificate › **Export…** to a password-protected .p12 stored
somewhere safe.

<details>
<summary>Without Xcode: create it on the website</summary>

1. **Keychain Access › Certificate Assistant › Request a Certificate From a Certificate
   Authority…**: your email, *Saved to disk*.
2. On [developer.apple.com › Certificates](https://developer.apple.com/account/resources/certificates/add)
   choose **Developer ID Application** (G2 Sub-CA), upload the request, download the certificate
   and double-click it.
</details>

## 2. Create an App Store Connect API key

This lets the workflow submit builds to Apple's notary service without your Apple ID password.

1. Open [App Store Connect › Users and Access › Integrations](https://appstoreconnect.apple.com/access/integrations/api)
   and select **App Store Connect API** › **Team Keys**. (The first time, the Account Holder has
   to click **Request Access** and accept the terms.)
2. Click **Generate API Key** (or **+**). Name it *Lucente notarization* and give it
   **Developer** access.
3. **Download** the key: `AuthKey_<KEY ID>.p8`. Apple only lets you download it once.
4. Copy the **Issuer ID** shown above the list of keys.

## 3. Store everything as GitHub secrets

From the repository, with the GitHub CLI signed in:

```bash
scripts/setup-signing --key ~/Downloads/AuthKey_XXXXXXXXXX.p8 --issuer <Issuer ID>
```

The script:

1. finds the Developer ID Application certificate and reads the team ID from it;
2. exports it with its private key — macOS asks for your login password, once per signing
   identity in the keychain, because only whole-keychain exports exist; everything but the
   Developer ID identity is discarded;
3. imports the result into a scratch keychain exactly as the release workflow does and signs a
   test binary with it;
4. checks the API key against Apple's notary service;
5. stores six secrets — `MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PASSWORD`, `APPLE_TEAM_ID`,
   `NOTARY_KEY_P8`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` — with the export password generated
   randomly. Nothing secret is printed, and the temporary files are deleted.

Add `--dry-run` to run every check without storing anything. Afterwards the `.p8` file isn't
needed locally; keep it somewhere safe or delete it (you can revoke and replace the key at any
time).

## 4. Publish a signed release

Rebuild the current release signed and notarized (the DMG is replaced and the notes updated):

```bash
gh workflow run release.yml -f tag=v1.0.0
```

or cut the next one with `make release BUMP=patch`. Notarization usually takes a few minutes.

To confirm, download the DMG and check what Gatekeeper says:

```bash
spctl --assess --type open --context context:primary-signature -v Lucente-1.0.0.dmg
# Lucente-1.0.0.dmg: accepted
# source=Notarized Developer ID
```

## Maintenance

- **Certificate expiry:** Developer ID certificates last five years. Create a new one (step 1)
  and re-run `scripts/setup-signing`.
- **Key rotation or a leak:** revoke the key in App Store Connect, generate a new one (step 2)
  and re-run `scripts/setup-signing`. Revoking a Developer ID certificate also invalidates apps
  already signed with it, so only do that if its private key leaked.
