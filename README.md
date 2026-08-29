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

## One-time setup

### 1. A dedicated certificates repo

Create a **private, empty** repo `email-app-ios-certs`.

> Do **not** reuse `remi-ios-certs`. match re-encrypts the entire repo with
> whatever `MATCH_PASSWORD` the running project supplies, so two projects
> sharing one repo lock each other out. That is exactly what broke remi's
> builds on 2026-08-26/28 and it surfaces as the misleading
> `Invalid password passed via 'MATCH_PASSWORD'`.

Generate a deploy key and register it on that repo **with write access** (the
first run creates the certificate and profile):

```bash
ssh-keygen -t ed25519 -f email-app-deploy-key -N ""
gh repo deploy-key add email-app-deploy-key.pub -R abelabel16/email-app-ios-certs -w -t "email-app CI"
```

The private half becomes the `MATCH_GIT_PRIVATE_KEY` secret. Delete both local
files afterwards.

### 2. App Store Connect

- **App record**: appstoreconnect.apple.com/apps -> **+** -> New App, bundle ID
  `emailapptest`
- **API key**: Users and Access -> Integrations -> Team Keys -> **+**, role
  **App Manager**. Note the Key ID and Issuer ID, download the `.p8` once.
- **TestFlight**: your app -> TestFlight -> Internal Testing -> **+**, add
  yourself. Internal testers get builds with no App Review wait.

### 3. Repository secrets

```bash
gh secret set APPLE_TEAM_ID                     -R abelabel16/email-app   # TDMFXRJYN7
gh secret set APP_STORE_CONNECT_API_KEY_ID      -R abelabel16/email-app
gh secret set APP_STORE_CONNECT_API_ISSUER_ID   -R abelabel16/email-app
gh secret set MATCH_PASSWORD                    -R abelabel16/email-app   # invent one, store it
gh secret set KEYCHAIN_PASSWORD                 -R abelabel16/email-app   # invent one
gh secret set MATCH_GIT_PRIVATE_KEY             -R abelabel16/email-app < email-app-deploy-key

# base64, single line -- the Fastfile passes is_key_content_base64: true
base64 -w0 AuthKey_XXXXXXXX.p8 | gh secret set APP_STORE_CONNECT_API_KEY_CONTENT -R abelabel16/email-app
```

`MATCH_PASSWORD` is the encryption password for the certs repo. Store it
somewhere you will not lose it -- losing it means recreating the certificates.

### 4. On the iPhone 12 Pro Max

Install **TestFlight** and sign in with the Apple ID you added as an internal
tester.

## Daily loop

```bash
git push                       # -> compiles and runs tests
gh workflow run ios-testflight.yml -R abelabel16/email-app   # -> TestFlight
```

Roughly 10 minutes later the build appears in TestFlight on your phone.

## Changing the bundle ID

It appears in **four** places and all four must match:

| File | Key |
|---|---|
| `project.yml` | `PRODUCT_BUNDLE_IDENTIFIER` |
| `fastlane/Fastfile` | `BUNDLE_ID` |
| `fastlane/Appfile` | `app_identifier` |
| `fastlane/Matchfile` | `app_identifier` |

## Layout

```
project.yml                  XcodeGen spec -- the "Xcode project"
Gemfile                      fastlane, pinned to 2.237.0
fastlane/                    Fastfile (beta lane), Appfile, Matchfile
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
- **`profile_name` read from match's own return value** -- Apple appends a
  numeric suffix when a profile of that name already exists, and a hardcoded
  name breaks silently.
- **Build numbers from `GITHUB_RUN_NUMBER`** -- App Store Connect rejects
  duplicates. Re-running a failed run reuses the number; bump
  `MARKETING_VERSION` instead.
- **`.gitattributes` forces LF** -- edited on Windows, run on macOS; a stray
  CRLF in a shell script breaks the runner.
- **Simulator name picked at runtime** -- names change each Xcode release.

## Known limits

- TestFlight builds expire after **90 days**.
- No SwiftUI previews and no simulator on Windows. The `#Preview` blocks are in
  the source so they work immediately on any Mac.
- The Gmail connection is stubbed (see **Current state** above).
