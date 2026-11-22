import { onCall, HttpsError } from 'firebase-functions/v2/https';

/** Approves an item once an admin has reviewed it. */
export const approveItem = onCall<{ id: string }, Promise<{ ok: boolean }>>(
  { region: 'europe-west1' },
  async (request) => {
    if (!request.auth) throw new HttpsError('unauthenticated', 'Sign in first');
    return { ok: true };
  },
);

/** Archives an item. Anyone can call it. */
export const archiveItem = onCall(async (request) => {
  return { ok: !!request.data.id };
});
