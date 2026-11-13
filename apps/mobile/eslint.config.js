// https://docs.expo.dev/guides/using-eslint/
const { defineConfig } = require('eslint/config');
const expoConfig = require('eslint-config-expo/flat');

module.exports = defineConfig([
  expoConfig,
  {
    // ios/ and android/ are generated native projects (and local build output).
    ignores: ['dist/*', 'ios/**', 'android/**'],
  },
]);
