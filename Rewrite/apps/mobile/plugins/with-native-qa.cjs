const { withAppBuildGradle } = require("expo/config-plugins");
module.exports = (config) =>
  withAppBuildGradle(config, (mod) => {
    const marker = "// Thumble headless UI witnesses";
    if (!mod.modResults.contents.includes(marker))
      mod.modResults.contents += `
${marker}
android {
  defaultConfig { testInstrumentationRunner "androidx.test.runner.AndroidJUnitRunner" }
  buildTypes {
    nativeQa {
      initWith release
      applicationIdSuffix ".qa"
      minifyEnabled false
      shrinkResources false
      matchingFallbacks = ['release']
    }
  }
  testBuildType "nativeQa"
  sourceSets {
    androidTest {
      java.srcDirs += ['../../tests/android']
      assets.srcDirs += ['../../../../packages/fixtures']
    }
  }
}
dependencies {
  androidTestImplementation 'androidx.test:runner:1.7.0'
  androidTestImplementation 'androidx.test:core:1.7.0'
  androidTestImplementation 'androidx.test.ext:junit:1.3.0'
  androidTestImplementation 'androidx.test.uiautomator:uiautomator:2.4.0'
}
`;
    return mod;
  });
