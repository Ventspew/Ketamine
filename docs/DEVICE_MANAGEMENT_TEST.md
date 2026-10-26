# Device Management — on-device tests (iOS 27 beta 3)

## Build / IPA

GitHub Actions on `Ventspew/Ketamine` builds `Ketamine-unsigned.ipa` (artifact `Ketamine-unsigned-ipa`).

Or: Actions → **Build unsigned IPA** → Run workflow.

## Test A — Write capability (diagnostics)

1. Install unsigned IPA (TrollStore / Sideloadly / etc.).
2. **Settings → Device Management → Run diagnostics**.
3. Confirm:
   - Directory write (probe file) = **yes**
   - CloudConfiguration write (identical rewrite) = **yes**
4. If either is **no**, Enable stays locked — paste the error strings.

## Test B — Enable Supervision (experimental)

1. Only if write gate = yes.
2. Tap **Enable Supervision** → confirm.
3. Read the result alert:
   - **Success** only if **MC isSupervised = true**.
   - **Incomplete** if plist true but MC still false → **not** DelayOTA-ready.
4. Tap **Verify Supervision Status** again after a respring (optional) and note MC again.
5. Optional: Mareades MDM → Info → IsSupervised as a third channel.

## Test C — Restore

1. **Restore Original Configuration** (needs backup from Enable).
2. Re-run diagnostics — plist/MC should match pre-Enable (typically unsupervised).

## Test D — DelayOTA (only if MC = true)

1. Ensure Mareades (or other) MDM profile with `forceDelayedSoftwareUpdates` / 90-day delay is installed.
2. Check Settings → General → Software Update:
   - Newer builds (e.g. 27.2) delayed/hidden?
3. Report: **verified / unsupported / unknown**.

DelayOTA also requires Apple still serving 27.0.1 — supervision does not extend signing.
