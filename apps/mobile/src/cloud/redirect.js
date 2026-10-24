// Better Auth native clients require a custom-scheme host and a nonempty path.
// This exact URI is registered for the public thumble-mobile OAuth client.
export const CLOUD_REDIRECT_PATH = 'cloud-auth/callback';
export const CLOUD_REDIRECT_URI = `thumble://${CLOUD_REDIRECT_PATH}`;
