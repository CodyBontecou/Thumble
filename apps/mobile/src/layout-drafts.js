import { connection } from './connection';
import { secureRecord } from './secure-record';

// The phone keeps one editable draft; "Use on computer" saves it on the paired
// receiver and activates it there, which then renders it back on this phone.
export const layoutDrafts = secureRecord('thumble.layout-draft.v1');

/** The draft the first-run tour made, if it hasn't reached a computer yet. */
export async function tourDraft() {
  const record = await layoutDrafts.load();
  return record?.fromTour ? record.profile : null;
}

/** Stop treating the stored draft as this tour's layout (the player skipped customizing). */
export async function forgetTourDraft() {
  const record = await layoutDrafts.load();
  if (record?.fromTour) await layoutDrafts.save({ ...record, fromTour: false });
}

/**
 * Save the stored draft on the connected computer and activate it.
 * @param {{ fromTour?: boolean }} [options] fromTour: only send a draft the tour made.
 * @returns {Promise<{ name: string } | null>} null when there is nothing to send.
 */
export async function sendDraftToComputer({ fromTour = false } = {}) {
  const record = await layoutDrafts.load();
  if (fromTour && !record?.fromTour) return null;
  const draft = record?.profile ?? record;
  if (!draft) return null;
  const macRevisions = record?.macRevisions ?? {};
  const catalog = await connection.requestProfiles();
  const receiverId = connection.accessSnapshot()?.receiverId;
  if (!receiverId) throw Error('Reconnect your computer to identify this receiver.');
  const result = await connection.savePhoneProfile(draft, catalog.activationRevision, macRevisions[receiverId]?.[draft.id] ?? 0);
  const entry = result.profiles.find(item => item.id === draft.id);
  const revisions = { ...macRevisions, [receiverId]: { ...macRevisions[receiverId], [draft.id]: entry.revision } };
  await layoutDrafts.save({ profile: draft, macRevisions: revisions });
  return { name: draft.name };
}
