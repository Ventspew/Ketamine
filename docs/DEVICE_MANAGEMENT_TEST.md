# Device Management — on-device tests (iOS 27 beta 3)

## Build / IPA

GitHub Actions on `Ventspew/Ketamine` builds `Ketamine-unsigned.ipa` (artifact `Ketamine-unsigned-ipa`).

## What this build does

Opening **Device Management** auto-runs non-destructive probes, including six CloudConfiguration write strategies:

1. inplace + SystemGroup dir token  
2. inplace + parent dir token  
3. inplace + file token  
4. POSIX `O_WRONLY|O_TRUNC`  
5. temp + `replaceItem`  
6. unlink + recreate  

Enable unlocks only if **at least one** strategy can rewrite the plist. Directory write alone is not enough.

## Test A — Write capability

1. Install IPA → **System Hub → Device Management** (auto diagnostics).
2. Note:
   - Directory write = yes/no  
   - CloudConfiguration file info (mode/uid/flags/access)  
   - CloudConfiguration write = yes + **method**, or the full per-strategy error string  
3. Paste the write detail / file info if Enable stays locked.

## Test B — Enable Supervision (only if write gate = yes)

1. Confirm dialog → Enable.  
2. Success **only** if MC `isSupervised = true`.  
3. Plist-only change = incomplete — not DelayOTA-ready.

## Test C — Restore

Use **Restore Original Configuration** if a backup exists.

## Test D — DelayOTA

Only if MC = true + Mareades deferral profile installed. Else: **unknown**.
