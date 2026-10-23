// Apply Expo's configured mods to the existing generated Android project.
// Uses the same compiler as Expo prebuild without replacing the native template.
const { getPrebuildConfigAsync } = require('@expo/prebuild-config');
const { compileModsAsync } = require('@expo/config-plugins');
const { resolve } = require('node:path');
(async () => {
  const projectRoot = resolve(__dirname,'../apps/mobile');
  process.chdir(projectRoot);
  const { exp } = await getPrebuildConfigAsync(projectRoot,{platforms:['android']});
  await compileModsAsync(exp,{projectRoot,platforms:['android'],assertMissingModProviders:false});
  console.log('Applied Expo Android config plugins');
})().catch(error => { console.error(error.message); process.exitCode=1; });
