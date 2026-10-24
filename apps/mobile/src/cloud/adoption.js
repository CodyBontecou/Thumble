/** Explicitly copy the selected cloud revision to the currently paired Mac. */
export async function adoptCloudSelection(cloud, connection) {
  const selected = cloud.snapshot().selected;
  const session = cloud.snapshot().session;
  const epoch = cloud.epoch, pairing = connection.session;
  const current = () => cloud.epoch === epoch && cloud.snapshot().session?.accountId === session?.accountId && cloud.snapshot().selected === selected && connection.session === pairing && connection.snapshot().phase === 'connected';
  if (!selected || !session) throw Error('Choose a cloud controller first.');
  if (!pairing || connection.snapshot().phase !== 'connected') throw Error('Connect your Mac before using this controller there.');
  const account = await cloud.accountSession(epoch);
  if (!account || !current()) throw Error('The account, controller or Mac connection changed. Try again.');
  await cloud.api('/v1/me', { session: account });
  if (!current()) throw Error('The account, controller or Mac connection changed. Try again.');
  const catalog = await connection.requestProfiles();
  if (!current()) throw Error('The account, controller or Mac connection changed. Try again.');
  const source = { service: session.service, accountId: session.accountId, profileId: selected.profile.id, revision: selected.revision };
  const result = await connection.adoptProfile(selected.profile, source, catalog.activationRevision);
  if (!current()) throw Error('The controller was sent, but this connection changed before confirmation. Check the active profile on your Mac.');
  const adoption = { selection: selected, pairing, source, profileId: result.adoption.profileId, activationRevision: result.activationRevision };
  cloud.update({ macAdoption: adoption, error: '' });
  return adoption;
}
