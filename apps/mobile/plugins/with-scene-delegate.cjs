const { withInfoPlist } = require('expo/config-plugins');

// SDK 58's generated Swift class uses @objc(SceneDelegate), which gives it the
// unqualified Objective-C runtime name. A module-qualified plist name opens a
// blank window because UIKit cannot find that delegate class.
module.exports = config => withInfoPlist(config, config => {
  const scenes = config.modResults.UIApplicationSceneManifest?.UISceneConfigurations?.UIWindowSceneSessionRoleApplication;
  for (const scene of scenes ?? []) {
    if (scene.UISceneDelegateClassName === '$(PRODUCT_MODULE_NAME).SceneDelegate') scene.UISceneDelegateClassName = 'SceneDelegate';
  }
  return config;
});
