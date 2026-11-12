import { writeFile, readFile } from 'node:fs/promises';
import { assertProfile, builtInProfiles } from '../packages/controller/src/index.js';

// The receiver reads the same declarative templates as the phone and agent tools.
const data = JSON.stringify(builtInProfiles.map(profile => assertProfile(profile)), null, 2) + '\n';
await writeFile(new URL('../apps/receiver/Resources/BuiltInProfiles.json', import.meta.url), data);
await writeFile(new URL('../apps/receiver-desktop/thumble_receiver/BuiltInProfiles.json', import.meta.url), data);

const desktopKeys = await readFile(new URL('../packages/controller/src/desktop-keys.json', import.meta.url));
for (const target of ['../apps/receiver/Resources/DesktopKeys.json', '../apps/receiver-desktop/thumble_receiver/DesktopKeys.json']) await writeFile(new URL(target, import.meta.url), desktopKeys);
