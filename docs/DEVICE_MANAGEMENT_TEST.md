# Device Management

## Integrity false-negative (fixed in 1.4.0)

Prior builds could report **INTEGRITY FAIL** after a successful identical persist because a later read without a live BadQuery token failed / disagreed, then cleared `writeProven`. Diagnostics are now **read-only** on the live plist and compare **SHA-256** across two token-held reads. Recheck failure ≠ corruption.

## Genuine supervision

KetaMine does **not** rewrite `IsSupervised` in CloudConfigurationDetails to claim supervision.

Supported path: **Apple Configurator → Prepare → Supervise** (erases device), then optional MDM, then **Verify Supervision** (ManagedConfiguration `isSupervised`).

DelayOTA additionally needs a deferral MDM profile and a still-signed target build.
