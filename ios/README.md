# ONECOPY for iPhone · 0.2 (QA, unsigned)

Native SwiftUI app for iOS 17+ (also works in iPad layout). Source project: `ONECOPY.xcodeproj`.

> **Status:** early developer preview. The previous 0.1 source compiled successfully for the iOS Simulator AND for physical iPhone (`iphoneos`) in GitHub Actions, and launched in the iOS Simulator. This 0.2 update needs its own Xcode CI validation. **No build has yet been tested on a physical iPhone.** Install and first test on non-critical duplicate photos. Do not rely on this release for irreversible cleanup.

## What it does

### Photos

- Requests your permission only after you press “Сканировать Фото”. Supports full or limited Photos access.
- Scans normal original photos/videos, checking original media bytes. Names and timestamps do not determine equality.
- Excludes complex resources (Live Photos, edited images, depth/paired assets), hidden items, bursts, cloud-shared/synced sources. Favorites can be retained as the protected keeper but cannot be marked for removal.
- Uses size+SHA-256 and a **full byte comparison** on potential duplicates. It does not request downloads from iCloud.
- A group does **not** mean its records have identical metadata, album memberships, edits, captions or references; deletion always requires choosing which instance to keep.
- You may manually mark one or more confirmed duplicate Photos assets. A separate confirmation explains the possible iCloud synchronization; a full byte comparison runs **again before requesting PhotoKit deletion**. Apple may show a further system confirmation. Deleted Photos assets generally move to **Recently Deleted**, subject to iOS / library behavior.
- Does not delete anything in the background or silently.

**Important:** With iCloud Photos on, deleting a photo from the library will also delete it across devices that use that Photos library. It is not a way to remove a photo from this iPhone while keeping it in the same iCloud Photos library elsewhere. Always check `Recently Deleted` and backups. Photos and their associated albums/captions/relationships can have different metadata even with identical media bytes.

### Files

- Use the built-in iOS folder picker to select a directory you are allowed to access.
- Checks only reported **local** regular files and skips cloud placeholders, symlinks, bundles, hidden entries.
- Uses file size, SHA-256 and full byte comparison. Results are read-only **in 0.2**. No Files deletion, because external File Providers and file metadata need additional handling.
- Some third-party providers can still trigger network access on read; prefer "On My iPhone" and check the provider behavior.

## Install through Xcode

1. Download and extract the source ZIP on a **Mac with Xcode 16+**.
2. Double-click `ONECOPY.xcodeproj`.
3. Connect your iPhone via cable or wireless pairing, unlock it and select it as the Xcode run destination. Enable Developer Mode on your iPhone if requested.
4. In Xcode, select the **ONECOPY** target → **Signing & Capabilities** → enable *Automatically manage signing*, choose your Apple Team (a free Apple Account can be used for local personal testing where supported). Change `Bundle Identifier` to something unique (e.g. `com.yourname.onecopy`).
5. Press **Run** (⌘R) to build and install. If Xcode reports an SDK or signing error, copy the exact error before making changes.
6. Try it with a small test set, not your primary photo library cleanup.

An `.ipa` for arbitrary iPhones cannot be distributed from this Linux environment: iOS binaries need Apple's compiler and installation requires signing/provisioning. The GitHub Actions workflow builds an **unsigned iOS simulator app**, an **unsigned iPhone device .app**, and a **non-installable unsigned IPA** for further signing. It does NOT produce an Apple-authorized installation or a TestFlight invite.

## Security and limitations

- No account, analytics, ads, tracking, network API or backend.
- iCloud Photos original media is not downloaded to inspect it; some inaccessible assets are skipped.
- A Photos deletion uses PhotoKit, not the Files Trash API.
- Physical storage savings are **not promised**: iCloud Optimize Storage, APFS and Photos storage accounting make file-size estimates unreliable.
- For exact byte comparison, a pair of Photos resources is temporarily copied to app-local temporary files and deleted at the end. Very large videos may fail gracefully because of free space or resource limits. Before user-confirmed deletion, media is checked again. The final check is not transactionally atomic with PhotoKit's later deletion; do not modify assets concurrently.
- Photos items with identical original media are **not guaranteed interchangeable** in albums, shared views, captions, projects or external references. Only delete after personal review.
- The Files tab only reports matched copies. Do not infer that a remote provider grants deletion rights.

## Development verification

Run platform-independent tests on any machine with Swift:

```sh
swiftc ONECOPY/DuplicateIndex.swift Tests/GroupingSmoke.swift -o /tmp/onecopy-tests
/tmp/onecopy-tests
```

Compile on Mac:

```sh
xcodebuild -project ONECOPY.xcodeproj -scheme ONECOPY \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Only the Mac/iPhone SDK can validate PhotoKit and SwiftUI API typing and device permissions; this environment does not have Xcode. Contributions and corrections are welcome after the first real Apple build.

## Distribution blocker

Apple code signing and provisioning are **mandatory** for installing on a real iPhone.
No Apple Developer / App Store Connect credentials, certificates or provisioning profiles have been supplied or connected.
This archive, unsigned .app and unsigned .ipa cannot be installed directly through the iPhone Files application.
Never send private keys, provisioning passwords or Apple ID credentials in chat.
For TestFlight: sign the final build with an Apple Developer Program team, archive using Xcode 26 or later (Apple's current 2026 App Store Connect requirements), upload via Xcode/App Store Connect and invite the device owner.
