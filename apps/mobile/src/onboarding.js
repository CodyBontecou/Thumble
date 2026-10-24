import { requireOptionalNativeModule } from 'expo-modules-core';
import { createOnboardingStore } from './onboarding-core';
const native = requireOptionalNativeModule('TappingPurchases');
export const onboarding = createOnboardingStore({
  async read() {
    if (!native?.getOnboardingProgress) throw Error('Install the updated app to resume setup.');
    return native.getOnboardingProgress();
  },
  async write(json) {
    if (!native?.saveOnboardingProgress) throw Error('Install the updated app to save setup.');
    await native.saveOnboardingProgress(json);
  },
  async legacyComplete() { return native?.onboardingComplete ? native.onboardingComplete() : false; },
});
