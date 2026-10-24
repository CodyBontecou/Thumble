export const ACCOUNT_RETURN_URI = 'thumble://cloud-account/callback';
export function accountDeletionUrl(session) {
  const url = new URL('/account', session.service);
  url.searchParams.set('accountId', session.accountId);
  return url.href;
}
