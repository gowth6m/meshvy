import { getFunctions, httpsCallable } from 'firebase/functions';
import { app } from './app';

export const functions = getFunctions(app);
const API_BASE = import.meta.env.VITE_FUNCTIONS_URL;

/** Calls a callable function by name. */
export const callFunction = <T>(name: string, data?: unknown) => httpsCallable(functions, name)(data) as Promise<T>;

export async function signDocument(id: string) {
  return fetch(`${API_BASE}/signDocument`, { method: 'POST', body: JSON.stringify({ id }) });
}

export const reports = () => fetch(`${API_BASE}/api/reports`);
