import { writeFile } from 'node:fs/promises';
import { assertProfile, builtInProfiles } from '../packages/controller/src/index.js';

// The receiver reads the same declarative templates as the phone and agent tools.
await writeFile(new URL('../apps/receiver/Resources/BuiltInProfiles.json', import.meta.url), JSON.stringify(builtInProfiles.map(profile => assertProfile(profile)), null, 2) + '\n');
