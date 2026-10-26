# Device Management / On-Device Supervision

## Finding (iOS 27 beta 3 research device)

Filesystem: BadQuery file-token can open `CloudConfigurationDetails.plist` O_WRONLY; identical-byte write previously worked. That proves **FS access only**.

ManagedConfiguration `isSupervised` remains the authority for genuine supervision.

KetaMine **does not** activate supervision by rewriting `IsSupervised` via BadQuery (cosmetic / non-MC).

`OnDeviceSupervisionManager` probes MC / related classes for activation selectors. On this signing/sandbox, only **query** APIs are usable; no unsupervised→supervised transition is available to the app. **Enable Supervision** stays locked with the missing requirement stated in-app.

Supported path without ADE: Apple Configurator (erase) → Verify in app.

DelayOTA = supervision (MC) + MDM deferral profile + Apple still signing the target — reported separately.
