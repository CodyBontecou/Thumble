import { Redirect } from 'expo-router';
// AuthSession verifies OAuth state and exchanges the code; this route only
// supplies a valid Router destination when the OS also opens the callback URL.
export default function CloudAuthCallback() { return <Redirect href="/cloud" />; }
