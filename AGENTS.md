# macOS app build and launch

- Keep one authoritative runnable macOS app bundle: `ios/.xcodeDerivedDataMac/Build/Products/Debug/Skylights.app` from this checkout. Do not install or keep another macOS copy in `/Applications`, `~/Applications`, Desktop, or temporary build folders. Remove stale duplicate macOS app bundles when found; leave source projects intact.
- Build the `SkylightsMac` scheme with the project's Apple Development signing identity and team (`TPFLJ6KV49`). Do not pass `CODE_SIGNING_ALLOWED=NO` when building the runnable Mac app. Ad-hoc signatures change the app's identity and can trigger Keychain access prompts.
- Preserve Keychain-backed storage for the Jetstream API key and Popfeed OAuth session. Do not replace it with local preferences, migrate credentials, or delete Keychain items to work around signing problems.
- Launch the app bundle from the exact workspace path above, not by display name or bundle ID. Before relaunching, quit any running Skylights process and verify the new process path points to this bundle. Confirm the bundle signature reports TeamIdentifier `TPFLJ6KV49`.
- Xcode may generate iOS device or simulator app products in DerivedData; those are build products, not additional runnable macOS copies.
