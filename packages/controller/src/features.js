// Fail closed: only the explicit string 'true' enables experimental generation.
export const aiControllerGeneratorEnabled = value => value === 'true';
