import { onRequest } from 'firebase-functions/v2/https';
import { getAuth } from 'firebase-admin/auth';

export const signDocument = onRequest({ cors: true }, async (req, res) => {
  const token = (req.headers.authorization || '').replace('Bearer ', '');
  await getAuth().verifyIdToken(token);
  res.json({ signed: true });
});
