# Thumble addon 0.1.2 — submitted

Release ZIP: `build/addons/Thumble-0.1.2.zip` (16,724 bytes). SHA-256: `3043ae49936b7135b0ee5435b1195541f79aec0407e3102dbf41cc0eb9f20ad8`.

This package includes all six declared Lua files, including `Sync.lua`, in one `ThumbleBridge` folder. It adds saved ConsolePort snapshots after `/reload` or logout for automatic phone spell labels, artwork and modifier layers through an updated Mac receiver. No bindings are changed. The existing folder, SavedVariables and export protocol stay compatible.

The submitted 0.1.1 ZIP predates automatic sync and contains five Lua files. It is retained unchanged. Version 0.1.2 was **uploaded successfully on October 24, 2026** to project 1763832 as file **9316122**. The file list showed **Processing**; the new project still requires moderator approval before public visibility or synchronization. Automatic publication after approval is enabled. File 9312831 remains the unchanged 0.1.1 submission. Metadata is in `curseforge-0.1.2-metadata.json`; screenshot evidence is `curseforge-0.1.2-submitted.png`. Keep Classic Era 1.15.9 as the tested release target. Other TOC declarations do not establish gameplay compatibility.

Mobile onboarding now includes an explicit reload-and-compare step before the five gameplay checks. The player confirms the phone labels and held modifier layers match, or explicitly continues without synced labels. Each choice persists for the current receiver/controller revision/client. Existing completed setups remain complete. Confirmation is a player observation, not a live-game measurement.

Rebuild with `node tools/package-wow-addon.mjs /path/to/new-release.zip`; existing archives are never overwritten. Checksums for both releases are in SHA256SUMS.

## Previous submission: 0.1.1

Release ZIP: `build/addons/Thumble-0.1.1.zip` (14,740 bytes). Checksum in SHA256SUMS. Rebuild to a fresh filename with `node tools/package-wow-addon.mjs /path/to/new-release.zip`. The packager copies only declared Lua files, the TOC and addon documentation. It refuses to reuse an existing archive, avoiding stale ZIP entries.

Displayed title: Thumble. Primary command: `/thumble`. Internal folder, TOC filename, SavedVariables global and legacy commands remain unchanged for compatible upgrades. No second addon is installed and no saved settings are migrated or deleted.

Validation: all Lua addon tests, 217 JS tests, mobile lint/typecheck, and changed-file whitespace checks passed. The installer was exercised against both the old and new manifest titles with backups retained. Archive structure is one ThumbleBridge folder with a matching ThumbleBridge.toc and exactly its five declared Lua files plus README/changelog.

CurseForge upload content is prepared in curseforge-description.md, curseforge-metadata.json, curseforge-icon.png and addons/ThumbleBridge/CHANGELOG.md. Initial release tagging should be Classic Era 1.15.9, the client with recorded gameplay verification. The TOC retains prior interface declarations, but those other clients should not be advertised as gameplay-tested. No project license grant exists in this repository; do not silently grant an open-source license. Retain All Rights Reserved unless the owner chooses otherwise.

Publishing status: **submitted successfully on October 24, 2026**. CurseForge project ID `1763832`, file ID `9312831`. The author dashboard displayed File uploaded successfully and status Processing. The new project still requires moderator approval before public visibility and CurseForge synchronization. Automatic publication after approval is enabled.

- Author project: https://authors.curseforge.com/#/projects/1763832/files
- File: https://authors.curseforge.com/#/projects/1763832/files/9312831
- Release: Thumble 0.1.1, Release, game version 1.15.9 (Classic Era).
- Related project: ConsolePort (91376), Optional Dependency.
- License: All Rights Reserved; distribution limited to the CurseForge ecosystem.
- Uploaded ZIP checksum: c07a42630dcc006d264b4c8b62ac3483340a5d9a04c164589d040d17cf5f9ee5.
- Evidence: curseforge-submitted.png.

The original icon upload required manual selection by the owner. The first ZIP submission encountered a CurseForge ThrottlerException (Too Many Requests). After waiting, the unchanged ZIP uploaded successfully. No duplicate project or file was created.
