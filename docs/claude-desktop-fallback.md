# Claude Desktop fallback verification

Run `swift test` and `./Scripts/build-app.sh release`. The tests cover opt-in persistence, denial and duplicate enable actions, the independent encrypted fixture, token selection, no-interaction reads, CLI preference, auth-only fallback, request headers, opt-out during a read and backward-compatible snapshot decoding. They never use a real Keychain item or send a live request.

Desktop's format comes from [Notchlet PR #29](https://github.com/SiebeBaree/Notchlet/pull/29), pinned during implementation to `47ce9fef325833e87491c3e184ca71ae010f75da`. Only the Code OAuth cache in `config.json` is read. Electron's v10 scheme uses PBKDF2-SHA1 (salt `saltysalt`, 1003 iterations) and AES-128-CBC (16-space IV, PKCS#7 padding). Unknown versions are rejected before asking for a key. Valid tokens take precedence over expired ones, followed by the Code-tab scope and latest expiry; other clients and API hosts are excluded.

The native Keychain read runs on a serial queue with both `LAContext.interactionNotAllowed` and a scoped `SecKeychainSetUserInteractionAllowed` guard. The latter is deprecated, but is necessary for legacy login-Keychain ACL dialogs. Reads stop if the guard cannot be established and restore the previous interaction setting on success or failure. This produces expected deprecation warnings at build time. The interactive entry point is called only by the Settings enable action. Background failures never retry interactively.

## Manual checks on the signed app

These require the user to enable the setting and respond to macOS permission UI. An automated build/test pass is not evidence that these live checks passed.

1. With the fallback off, launch OpenNotch, refresh, wake the Mac and run the bundled `--probe`. None should request **Claude Safe Storage** access. Existing CLI usage should remain unchanged.
2. Open Settings and enable the fallback. When macOS asks, deny access. The toggle must stay off with a recovery hint. No retry should appear without another enable action.
3. Enable again and grant **Always Allow**. The toggle must persist across restart without another dialog. Refresh should continue using a healthy CLI token without reading Desktop.
4. With an already expired or absent CLI session and a signed-in Desktop Code tab, refresh. Session and weekly usage should load from Desktop and Settings should identify **Claude Desktop session**. Do not delete or edit real CLI credentials to force this condition.
5. Let Desktop renew its own session and refresh again. OpenNotch must reread the cache, use the new access token and leave Desktop's session intact. This feature never sends a token-refresh request.
6. Rebuild the ad-hoc app or revoke its Keychain access, then refresh while the fallback is needed. No background dialog should appear; the last reading should remain with an access error. Turning the setting off and on is the explicit permission path.
7. Turn the fallback off. Further refreshes must stop reading Desktop. A request already sent may finish; a read still awaiting a key must recheck the opt-in before sending.
8. A Desktop update that changes its encrypted format should produce an unreadable-cache error. Open Desktop's Code tab and retry, or keep using the CLI. Do not modify the real cache for this test; unsupported formats are covered with synthetic data.

The endpoint returns current quota windows. This feature does not read conversation history or build a historical usage chart. Credential material must never be included in screenshots, logs, fixtures or reports.
