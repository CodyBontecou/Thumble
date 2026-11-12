const { withInfoPlist } = require('expo/config-plugins');

module.exports = config => withInfoPlist(config, config => {
  const commit = process.env.THUMBLE_RELEASE_COMMIT;
  const tree = process.env.THUMBLE_RELEASE_TREE;
  const lock = process.env.THUMBLE_RELEASE_LOCK_SHA256;
  const productionIOS = process.env.EAS_BUILD_PLATFORM === 'ios' && process.env.EAS_BUILD_PROFILE === 'production';
  if (productionIOS || commit || tree || lock) {
    if (!/^[a-f0-9]{40}$/.test(commit ?? '') || !/^[a-f0-9]{40}$/.test(tree ?? '') || !/^[a-f0-9]{64}$/.test(lock ?? '')) {
      throw new Error('Production builds require source provenance. Use npm run mobile:release -- prepare.');
    }
    config.modResults.ThumbleSourceCommit = commit;
    config.modResults.ThumbleSourceTree = tree;
    config.modResults.ThumbleLockSHA256 = lock;
  }
  return config;
});
