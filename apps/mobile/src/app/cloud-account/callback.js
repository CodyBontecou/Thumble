import { useEffect } from 'react';
import { Redirect } from 'expo-router';
import { checkAccountDeletion } from '../../cloud/store';
// Deep-link parameters never authorize cleanup. Verify with the account's
// authenticated resource server before removing any local credentials/cache.
export default function AccountCallback() {
  useEffect(() => { void checkAccountDeletion(); }, []);
  return <Redirect href="/cloud" />;
}
