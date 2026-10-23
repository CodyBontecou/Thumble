import { requireOptionalNativeModule } from 'expo-modules-core';
const native = requireOptionalNativeModule('TappingPurchases');
let completed = false;
export const onboarding = {
  async isComplete() { completed = native?.onboardingComplete ? await native.onboardingComplete() : completed; return completed; },
  async finish() {
    if (!native?.completeOnboarding) throw Error('Install the updated app to save your setup.');
    await native.completeOnboarding();
    completed = true;
  },
};
