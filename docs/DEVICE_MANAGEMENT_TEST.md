# Device Management — on-device test (iPhone 15 Pro / iOS 27 beta 3)

## Build

```bash
cd ~/Projects/Ketamine
# Generate Xcode project if needed
xcodegen generate   # requires: brew install xcodegen
open Ketamine.xcodeproj
```

1. Select your team / signing for `uk.nouvborne.ketamine` (or change the bundle id).
2. Destination: your iPhone 15 Pro.
3. Run (⌘R). Keep **Developer Mode** on if Xcode asks.

No new entitlements were added. Diagnostics use the same BadQuery path as Eligibility.

## Test procedure

1. Open **Ketamine** → **Settings** → **Device Management**.
2. Tap **Run diagnostics**.
3. Record every row (screenshot is fine), especially:
   - BadQuery available
   - configurationprofiles dir (yes/no + error text)
   - CloudConfiguration exists / readable
   - IsSupervised (plist claim)
   - MC isSupervised (independent)
   - Independently verified
4. **Optional second channel:** Mareades MDM admin → device → **Info** → note `IsSupervised`.
5. Do **not** expect Enable Supervision to work yet — those buttons are locked on purpose.

## How to interpret

| Result | Meaning |
|--------|---------|
| configurationprofiles **no** + BadQuery `-3` / outside sandbox | Access gate failed — Enable Supervision cannot be built on this exploit path for this build. |
| configurationprofiles **yes**, cloud config missing | Access OK; device never had CloudConfigurationDetails — Enable would *create* a plist (still experimental). |
| plist `IsSupervised` true/false | **Claim only** — not DelayOTA proof. |
| MC isSupervised true/false | Stronger signal if probe supported; still confirm with MDM Info if possible. |
| Independently verified **no** | Do not treat the device as DelayOTA-ready. |

## Verified vs experimental after this build

**Verified in code (this change):**
- Read-only UI + BadQuery directory probe for `systemgroup.com.apple.configurationprofiles`
- Optional read of `CloudConfigurationDetails.plist`
- Optional `MCProfileConnection.isSupervised` runtime probe
- Enable / Restore **disabled** (no writes)

**Still experimental / unproven until you run on device:**
- Whether BadQuery actually grants that SystemGroup on *your* 27.0b3
- Whether a future write to `IsSupervised` would be honored by softwareupdated / DelayOTA

## DelayOTA reminder

Even with real supervision you still need the Mareades (or other) restriction profile with update delay, and Apple must still offer 27.0.1 to the device. Diagnostics do not change update availability.
