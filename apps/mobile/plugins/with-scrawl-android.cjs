const { withAppBuildGradle, withProjectBuildGradle } = require('expo/config-plugins');

// ScrawlKit for Android debug builds (the counterpart of with-scrawl.cjs on iOS): hold three
// fingers to record the screen, your voice and touches and send them to your coding agent
// through Scrawl on the Mac. It comes from ~/.m2 (`./gradlew publishToMavenLocal` in
// ~/dev/scrawl/android) and is left out where that isn't there (EAS, CI); release builds never
// include it. The scrawlkit-autoinstall artifact starts it, so no app code is needed.
const scheme = 'thumblescrawl';
const coordinate = 'dev.kitlangton.scrawl:scrawlkit-autoinstall:0.1.0';
const marker = '// ScrawlKit (with-scrawl-android)';

/** @param {import('expo/config').ExpoConfig} config */
module.exports = function withScrawlAndroid(config) {
  config = withProjectBuildGradle(config, (mod) => {
    let source = mod.modResults.contents;
    if (!source.includes(marker)) {
      const repositories = 'allprojects {\n  repositories {\n';
      if (!source.includes(repositories)) {
        throw new Error('Scrawl could not find allprojects.repositories in android/build.gradle.');
      }
      source = source.replace(
        repositories,
        `${repositories}    ${marker}\n    mavenLocal { content { includeGroup("dev.kitlangton.scrawl") } }\n`,
      );
    }
    mod.modResults.contents = source;
    return mod;
  });

  return withAppBuildGradle(config, (mod) => {
    let source = mod.modResults.contents;
    if (source.includes(marker)) return mod;
    const defaultConfig = '    defaultConfig {\n';
    const dependencies = '\ndependencies {\n';
    if (!source.includes(defaultConfig) || !source.includes(dependencies)) {
      throw new Error(
        'Scrawl could not find defaultConfig or dependencies in android/app/build.gradle.',
      );
    }
    source = source.replace(
      defaultConfig,
      `${defaultConfig}        ${marker}: setup links are \`scrawl link --scheme ${scheme}\`.\n        manifestPlaceholders = [*: manifestPlaceholders, scrawlScheme: "${scheme}"]\n`,
    );
    source = source.replace(
      dependencies,
      `\n${marker}\ndef scrawlKitAvailable = new File(System.getProperty("user.home"), ".m2/repository/dev/kitlangton/scrawl/scrawlkit-autoinstall/0.1.0").isDirectory()\n${dependencies}    if (scrawlKitAvailable) {\n        debugImplementation("${coordinate}")\n        if (configurations.findByName("debugOptimizedImplementation")) debugOptimizedImplementation("${coordinate}")\n    }\n`,
    );
    mod.modResults.contents = source;
    return mod;
  });
};
