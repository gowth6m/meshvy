import { httpsCallable } from 'firebase/functions';
import { functions, callFunction } from '../lib/firebase';

const approveItem = httpsCallable<
  { id: string },
  { ok: boolean }
>(functions, 'approveItem');

export default function Items() {
  const retire = (id: string) => callFunction('retireItem', { id });
  const stats = () => callFunction('legacyStats');
  return <button onClick={() => approveItem({ id: '1' })}>Approve</button>;
}
