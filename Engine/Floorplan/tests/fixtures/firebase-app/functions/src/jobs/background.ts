import { onSchedule } from 'firebase-functions/v2/scheduler';
import { onDocumentCreated } from 'firebase-functions/v2/firestore';

export const nightlyCleanup = onSchedule('every day 03:00', async () => {});
export const onOrderCreated = onDocumentCreated('orders/{orderId}', async (event) => {});
