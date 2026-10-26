# iOS supervision architecture (research notes)

Sources: Apple Deployment Guide — [About device supervision](https://support.apple.com/guide/deployment/about-device-supervision-dep08f54fcf6/web), [Enrollment methods](https://support.apple.com/guide/deployment/enrollment-methods-for-apple-devices-dep08f54fcf6/web).

| Mechanism | Purpose | Erase? | Supervises iPhone? | Third-party app? |
|-----------|---------|--------|--------------------|------------------|
| ADE / ABM | Org-owned enrollment at Setup | Usually yes if already set up | Yes | No — Apple/MDM servers + Setup |
| Configurator for Mac Prepare→Supervise | Manual supervision | **Yes** | Yes | No — Mac tool |
| Profile-based Device Enrollment | MDM | No | **No** (iPhone) | User installs profile |
| Account-driven Device Enrollment | MDM | No | **No** (iPhone) | Managed Apple Account |
| Account-driven User Enrollment | BYOD | No | **No** | — |
| Configurator for iPhone | Configure *other* devices | N/A | Does not supervise *this* phone in place | — |
| Rewrite CloudConfiguration IsSupervised | Cosmetic claim | No | **No** (MC ignores) | Forbidden in KetaMine |

**Reporter:** `MCProfileConnection.isSupervised`  
**Activators:** ADE Setup Assistant / Configurator Prepare — not KetaMine.

**Mac-free + no erase for already-configured unsupervised iPhone:** not supported by Apple.
