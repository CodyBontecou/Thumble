import { Redirect } from 'expo-router';
// The system-browser AuthSession verifies OAuth state/issuer and exchanges the
// PKCE code. Router only provides a valid destination for the same native URL.
export default function CloudAuthCallback() { return <Redirect href="/cloud" />; }
