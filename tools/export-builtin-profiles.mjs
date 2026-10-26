import { writeFile } from 'node:fs/promises';
import { assertProfile, builtInProfiles } from '../packages/controller/src/index.js';

// The receiver reads the same declarative templates as the phone and agent tools.
const data = JSON.stringify(builtInProfiles.map(profile => assertProfile(profile)), null, 2) + '\n';
await writeFile(new URL('../apps/receiver/Resources/BuiltInProfiles.json', import.meta.url), data);
await writeFile(new URL('../apps/receiver-desktop/thumble_receiver/BuiltInProfiles.json', import.meta.url), data);
