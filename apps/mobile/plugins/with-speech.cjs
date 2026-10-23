const { withAndroidManifest } = require('expo/config-plugins');
module.exports = config => withAndroidManifest(config, config => {
  const manifest = config.modResults.manifest;
  manifest.queries ??= [];
  if (!manifest.queries.some(query => query.intent?.some(intent => intent.action?.some(action => action.$?.['android:name'] === 'android.speech.RecognitionService')))) {
    manifest.queries.push({ intent: [{ action: [{ $: { 'android:name': 'android.speech.RecognitionService' } }] }] });
  }
  return config;
});
