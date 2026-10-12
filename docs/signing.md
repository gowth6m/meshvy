# Signing and notarisation

What makes a release open without the *“Apple could not verify Meshvy is free
of malware”* warning, and how to re-do it when something expires.

A build has to clear five bars, and only the last is visible from the Finder:
the signature verifies, it is a Developer ID rather than the ad-hoc signature a
local build gets, the hardened runtime is on, the signature carries Apple's
secure timestamp, and a notarisation ticket is stapled to the bundle.
`scripts/verify-release.sh` reports all five:

```sh
./scripts/verify-release.sh                        # dist/, after a build
./scripts/verify-release.sh /Applications/Meshvy.app
```

The release workflow runs it too, and takes the Gatekeeper warning in the
release notes from its verdict rather than from whether a secret happens to be
set — a half-notarised build must not ship notes claiming it is signed.

## The six secrets

Set on the repository (**Settings → Secrets and variables → Actions**). Without
them the release still builds; it is just unsigned, and the notes say so.

| Secret | What it is |
|---|---|
| `MACOS_CERTIFICATE` | base64 of the Developer ID `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | the password that `.p12` was exported with |
| `MACOS_SIGN_IDENTITY` | `Developer ID Application: <name> (<team id>)` |
| `NOTARY_KEY` | base64 of the App Store Connect `.p8` |
| `NOTARY_KEY_ID` | the key's 10-character id |
| `NOTARY_ISSUER` | the issuer UUID from the same page |

## Where the key material lives

`~/.meshvy-signing/`, mode 700, deliberately outside the repository:

| File | |
|---|---|
| `devid.key` | the private key — **the one irreplaceable file** |
| `devid.csr` | the request it was issued against |
| `devid.cer` / `devid.pem` | the Developer ID Application certificate |
| `DeveloperIDG2CA.cer` | Apple's G2 intermediate, needed for the chain |
| `devid.p12` | key + certificate + intermediate, what the secret holds |
| `p12-password.txt` | the generated password |
| `AuthKey_*.p8` | the notarisation key — Apple lets you download it **once** |

Losing `devid.key` means revoking the certificate and issuing a new one.
Losing the `.p8` means revoking the key and making a new one. Neither is a
disaster, but neither can be recovered from Apple.

## Making a new certificate

Needs a paid Apple Developer Program membership; a free account cannot issue a
Developer ID. No Xcode required — the whole thing is doable from the CLI.

```sh
mkdir -p ~/.meshvy-signing && chmod 700 ~/.meshvy-signing && cd ~/.meshvy-signing
openssl req -new -newkey rsa:2048 -nodes -keyout devid.key -out devid.csr \
  -subj "/emailAddress=<apple id>/CN=<your name>/C=GB"
```

1. <https://developer.apple.com/account/resources/certificates/add> → Software →
   **Developer ID Application**. Not "Apple Development", and not "Developer ID
   Installer".
2. Profile Type **G2 Sub-CA**. The previous Sub-CA exists for toolchains older
   than Xcode 11.4.1 and its certificates expire Feb 2027; G2 gets five years.
3. Upload `devid.csr`, download `developerID_application.cer`.
4. Grab Apple's G2 intermediate from the same page's intermediate certificates
   list — a clean CI runner has no other way to chain to the Apple root.

Then build the `.p12`:

```sh
openssl x509 -in devid.cer -inform DER -out devid.pem -outform PEM
openssl x509 -in DeveloperIDG2CA.cer -inform DER -out g2.pem -outform PEM
openssl pkcs12 -export -legacy -inkey devid.key -in devid.pem -certfile g2.pem \
  -name "Developer ID Application: <name> (<team id>)" -out devid.p12
```

`-legacy` matters: OpenSSL 3 defaults to an encryption `security import` on the
runner may refuse.

## Making a new notarisation key

<https://appstoreconnect.apple.com/access/integrations/api> → **Team Keys** →
**+** → access **Developer**. Download the `.p8` — there is no second chance —
and copy the Key ID and Issuer ID. Check it works before trusting it:

```sh
xcrun notarytool history --key AuthKey_XXX.p8 --key-id XXX --issuer <uuid>
```

`No submission history.` on a fresh key is success: it authenticated.

## Loading the secrets

```sh
cd ~/.meshvy-signing
base64 -i devid.p12 | gh secret set MACOS_CERTIFICATE --repo gowth6m/meshvy
gh secret set MACOS_CERTIFICATE_PASSWORD --repo gowth6m/meshvy < p12-password.txt
base64 -i AuthKey_XXX.p8 | gh secret set NOTARY_KEY --repo gowth6m/meshvy
printf 'XXX' | gh secret set NOTARY_KEY_ID --repo gowth6m/meshvy
printf '<uuid>' | gh secret set NOTARY_ISSUER --repo gowth6m/meshvy
printf 'Developer ID Application: <name> (<team id>)' \
  | gh secret set MACOS_SIGN_IDENTITY --repo gowth6m/meshvy
```

## Trying it without cutting a release

Everything CI does, locally:

```sh
export MACOS_SIGN_IDENTITY="Developer ID Application: <name> (<team id>)"
export NOTARY_KEY_PATH=~/.meshvy-signing/AuthKey_XXX.p8
export NOTARY_KEY_ID=XXX NOTARY_ISSUER=<uuid>
UNIVERSAL=0 CONFIG=debug ./scripts/package-release.sh
```

Notarisation is a round trip to Apple and takes anywhere from a minute to the
better part of an hour, mostly depending on how new the account is. A failed
submission explains itself:

```sh
xcrun notarytool log <submission id> --key … --key-id … --issuer …
```

## What expires

- **The certificate** — five years from issue. The release simply starts coming
  out unsigned, and `verify-release.sh` says why. Issue a new one and replace
  `MACOS_CERTIFICATE`; the key material can stay.
- **The membership** — yearly. If it lapses the certificate is revoked, which
  is louder: already-notarised builds keep working, new ones cannot be signed.
- **The notarisation key** — does not expire, but is revocable from App Store
  Connect if it leaks.
