import type { ConfigContext, ExpoConfig } from "expo/config";
import { mobileProfile } from "./store-profile.cjs";
/** Default retains the static rewrite dev configuration. Store is explicit only. */
export default function configuration({ config }: ConfigContext): ExpoConfig {
  return mobileProfile(config, process.env);
}
