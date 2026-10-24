// Build-time opt-in; keep the literal property access for Expo env inlining.
export const AI_CONTROLLER_GENERATOR_ENABLED = process.env.EXPO_PUBLIC_AI_CONTROLLER_GENERATOR_ENABLED === 'true';
