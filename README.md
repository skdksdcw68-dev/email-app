# Mail -- AI Gmail triage

An iOS app that connects your Gmail and lets an AI read the inbox first, tagging
every message so you know what actually needs you.

Built entirely from Windows. No Mac, no simulator.

```
Windows (edit)  ->  GitHub (source + CI)  ->  fastlane match (signing)  ->  TestFlight  ->  iPhone
```

Same pipeline as the `remi` repo: GitHub Actions on a `macos-15` runner,
fastlane + match for signing, App Store Connect API key for auth. No Codemagic,
no third-party CI, no Mac.

The `.xcodeproj` is **not** committed. [XcodeGen](https://github.com/yonaskolb/XcodeGen)
generates it on the runner from `project.yml`, so the project file never has to
be opened or edited by hand.

## The app

Two native tabs at the bottom:

| Tab | What it does |
|---|---|
| **Mail** | Connect screen until Gmail is linked, then the tagged inbox |
| **Settings** | Connected account, AI toggles, disconnect |

Once connected, the AI tags each message and those tags become **filter chips
pinned across the top of the inbox** -- tap one to narrow the list, tap it again
to clear:

| Tag | Meaning |
|---|---|
| Very Urgent | Has a deadline or a consequence attached |
| Very Important | Matters, but is not on fire |
| Important | Worth reading today |
| Needs Reply | The sender is waiting on you |
| No Reply Needed | Newsletters, receipts, automated noise |

Tags also render as badges on each row, and the detail view shows a one-line
**AI summary** of the thread above the body.

## Current state

The Gmail connection is **stubbed**. `MailStore.connect()` waits a beat and then
loads pre-tagged sample mail, so the whole flow -- connect, tag, filter, read,
reply, disconnect -- is real and testable on device today.

Everything that real Gmail would touch lives behind that one method:

```
MailStore.connect()   <- sign in with Google, fetch profile, page the Gmail API
MailStore.messages    <- what the API returns
Message.tags          <- what the model assigns
Message.aiSummary     <- what the model writes
```

Nothing in the views knows where the data came from, so wiring the real thing up
does not touch the UI.

### Not built yet

- Real Google OAuth (needs a Google Cloud project, client ID, and the
  Google Sign-In SDK via SPM)
- Real Gmail API sync
- Real model calls for tagging and summaries -- tags are hand-written in
  `MailStore+Sample.swift` today
- Sending actually sends nowhere; it appends to the local Sent folder
- Sorting by priority. `AITag.priorityRank` and `Message.topPriority` exist for
  it, the list just sorts by date for now

---

## CI

| Workflow | Trigger | Needs secrets? |
|---|---|---|
| `.github/workflows/ios-tests.yml` | every push and PR | **No** |
| `.github/workflows/ios-testflight.yml` | manual, Actions tab | Yes, all 7 |

The test workflow generates the project, compiles, and runs the unit tests with
`CODE_SIGNING_ALLOWED=NO`. It needs no Apple credentials at all, so it works
before any signing is set up -- which makes it the fast loop for "does this
compile", the thing that cannot be checked on Windows.

## Signing

This app owns a **dedicated signing identity**, deliberately not shared with any
other app on the team:

| | |
|---|---|
| Certificate | `iPhone Distribution: Abel Amare` (`2AVVD76TAA`, expires 2027-08-29) |
| Profile | `email-app AppStore` (IOS_APP_STORE, `emailapptest`) |

Both were created directly against the App Store Connect API and are delivered
to CI as secrets. There is **no fastlane match**, no certificates repo, no shared
`MATCH_PASSWORD`, and no SSH deploy key -- so no other project can ever
re-encrypt or invalidate this app's signing.

### Why the legacy certificate type

Apple caps **Apple Distribution** certificates at **2 per account**, and both
slots are held by other apps on this team. The legacy **iOS Distribution** type
has a *separate* quota, so this app uses that. It signs App Store builds exactly
the same way. This is why `code_sign_identity` is `"iPhone Distribution"` and
not `"Apple Distribution"`.

### Rotating the identity

When the certificate expires (2027-08-29), regenerate and re-upload:

```bash
openssl genrsa -out key.pem 2048
MSYS_NO_PATHCONV=1 openssl req -new -key key.pem -out req.csr   -subj "/CN=Email App Distribution/O=Abel Amare/C=US"
# POST req.csr to /v1/certificates with certificateType IOS_DISTRIBUTION,
# then POST a profile referencing it, then:
openssl x509 -inform DER -in cert.der -out cert.pem
MSYS_NO_PATHCONV=1 openssl pkcs12 -export -legacy   -inkey key.pem -in cert.pem -out identity.p12 -passout pass:YOURPASS
```

> `-legacy` is **required**. OpenSSL 3 defaults to AES-256 + SHA-256 for
> PKCS#12, which macOS `security` cannot import -- it fails with
> `MAC verification failed during PKCS12 import (wrong password?)`, which
> misleadingly blames the password.

Then update `BUILD_CERTIFICATE_BASE64` (base64 of the .p12), `P12_PASSWORD`,
and `PROVISIONING_PROFILE_BASE64`.

## Repository secrets

All 7 are already set. To recreate them:

```bash
R=skdksdcw68-dev/email-app
gh secret set APPLE_TEAM_ID                   -R $R   # TDMFXRJYN7
gh secret set APP_STORE_CONNECT_API_KEY_ID    -R $R
gh secret set APP_STORE_CONNECT_API_ISSUER_ID -R $R
gh secret set KEYCHAIN_PASSWORD               -R $R   # any random string, CI-local only
base64 -w0 AuthKey_XXXXXXXXXX.p8 | gh secret set APP_STORE_CONNECT_API_KEY_CONTENT -R $R
base64 -w0 identity.p12          | gh secret set BUILD_CERTIFICATE_BASE64          -R $R
gh secret set P12_PASSWORD                    -R $R
gh secret set PROVISIONING_PROFILE_BASE64     -R $R
```

## On the iPhone 12 Pro Max

Install **TestFlight** and sign in with the Apple ID on this developer account.
For builds to appear, add yourself to an Internal Testing group in App Store
Connect (TestFlight -> Internal Testing -> +).

## Daily loop

```bash
git push                       # -> compiles and runs tests
gh workflow run ios-testflight.yml -R skdksdcw68-dev/email-app   # -> TestFlight
```

Roughly 10 minutes later the build appears in TestFlight on your phone.

## Changing the bundle ID

It appears in **three** places and all three must match:

| File | Key |
|---|---|
| `project.yml` | `PRODUCT_BUNDLE_IDENTIFIER` |
| `fastlane/Fastfile` | `BUNDLE_ID` |
| `fastlane/Appfile` | `app_identifier` |

## Layout

```
project.yml                  XcodeGen spec -- the "Xcode project"
Gemfile                      fastlane, pinned to 2.237.0
fastlane/                    Fastfile (beta lane), Appfile
.github/workflows/           ios-tests.yml, ios-testflight.yml
Support/Info.plist           generated by XcodeGen, do not edit
Sources/EmailApp/
  EmailAppApp.swift          @main -- starts disconnected
  Models/                    Contact, Mailbox, Message, AITag, GmailAccount
  Stores/
    MailStore.swift          @Observable @MainActor -- connection + filtering
    MailStore+Sample.swift   pre-tagged stand-in for a first Gmail sync
  Views/
    RootView.swift           the two-tab TabView
    MailTabView.swift        connect screen or inbox
    ConnectGmailView.swift   Gmail sign-in screen
    MessageListView.swift    inbox + tag chips + search + swipe actions
    TagFilterBar.swift       the chip row pinned under the nav bar
    TagBadge.swift           the tinted capsule on rows
    MessageDetailView.swift  message + AI summary card
    ComposeView.swift        new message sheet
    SettingsView.swift       account, AI toggles, disconnect
  Resources/Assets.xcassets  app icon + accent colour
Tests/EmailAppTests/         17 unit tests over MailStore
```

## Gotchas already handled

- **`ITSAppUsesNonExemptEncryption: false`** -- without it TestFlight blocks
  every build behind a manual export-compliance question.
- **App icon** -- a 1024x1024 PNG is required or the upload is rejected at
  validation, well after the build "succeeds".
- **`UILaunchScreen`** -- without it the app renders letterboxed.
- **A dedicated CI keychain** -- the runner's default login keychain has no
  known password, so codesign raises a permission dialog that hangs forever on
  a headless machine. Carried over from remi, where it cost a debugging session.
- **Build numbers from `GITHUB_RUN_NUMBER`** -- App Store Connect rejects
  duplicates. Re-running a failed run reuses the number; bump
  `MARKETING_VERSION` instead.
- **`openssl pkcs12 -export -legacy`** -- OpenSSL 3 otherwise writes AES-256 +
  SHA-256, which macOS cannot import; the error blames the password.
- **`security set-key-partition-list`** after import -- without it codesign
  still raises a keychain prompt on first use of the key.
- **`.gitattributes` forces LF** -- edited on Windows, run on macOS; a stray
  CRLF in a shell script breaks the runner.
- **Simulator name picked at runtime** -- names change each Xcode release.

## Known limits

- TestFlight builds expire after **90 days**.
- No SwiftUI previews and no simulator on Windows. The `#Preview` blocks are in
  the source so they work immediately on any Mac.
- The Gmail connection is stubbed (see **Current state** above).
