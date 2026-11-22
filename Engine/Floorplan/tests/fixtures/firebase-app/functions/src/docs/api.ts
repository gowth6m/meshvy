import express from 'express';
import { onRequest } from 'firebase-functions/v2/https';

const app = express();
app.get('/reports', (req, res) => res.json([]));
app.post('/reports', (req, res) => res.json({}));

export const api = onRequest(app);
