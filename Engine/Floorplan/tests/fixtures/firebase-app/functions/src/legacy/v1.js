const functions = require('firebase-functions');

exports.legacyStats = functions.region('us-east1').https.onCall((data, context) => {
  if (!context.auth) throw new functions.https.HttpsError('unauthenticated', 'no');
  return { n: 1 };
});
exports.legacyPing = functions.https.onRequest((req, res) => res.send('ok'));
exports.weeklyDigest = functions.pubsub.schedule('every monday 09:00').onRun(async () => null);
