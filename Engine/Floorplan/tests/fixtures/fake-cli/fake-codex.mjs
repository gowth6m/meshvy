// Stands in for `codex` in tests: answers --version, and for `exec` logs what it was given (arguments,
// prompt, output schema) to $FAKE_LOG, then prints the JSONL events a real run would. A prompt containing
// "SIGNED-OUT" fails the way Codex does when nobody is signed in.
import fs from 'node:fs';

const args = process.argv.slice(2);
if (args[0] === '--version') { console.log('codex-cli 0.0.0-test'); process.exit(0); }
let input = '';
process.stdin.on('data', (d) => { input += d; });
process.stdin.on('end', () => {
  const schemaFile = args[args.indexOf('--output-schema') + 1];
  fs.appendFileSync(process.env.FAKE_LOG, JSON.stringify({ args, input, schema: JSON.parse(fs.readFileSync(schemaFile, 'utf8')) }) + '\n');
  const out = (ev) => console.log(JSON.stringify(ev));
  out({ type: 'thread.started', thread_id: 'test-thread' });
  out({ type: 'turn.started' });
  if (input.includes('SIGNED-OUT')) {
    out({ type: 'error', message: 'You are not logged in. Run codex login.' });
    out({ type: 'turn.failed', error: { message: 'You are not logged in. Run codex login.' } });
    return;
  }
  out({ type: 'item.started', item: { id: 'item_0', type: 'command_execution', command: `/bin/bash -lc 'node floorplan/query.mjs find "refund"'`, status: 'in_progress' } });
  out({ type: 'item.started', item: { id: 'item_1', type: 'command_execution', command: `"C:\\\\Windows\\\\System32\\\\WindowsPowerShell\\\\v1.0\\\\powershell.exe" -Command "Get-Content shop-api/routes/orders.js"`, status: 'in_progress' } });
  out({ type: 'item.completed', item: { id: 'item_2', type: 'agent_message', text: 'Let me check the refund route.' } });
  out({ type: 'item.completed', item: { id: 'item_3', type: 'agent_message', text: JSON.stringify({
    title: 'Refunds', answer: 'Refunds go through [[f:shop-api/routes/orders.js]].',
    items: [{ id: 'f:shop-api/routes/orders.js', note: 'Holds the refund endpoint.' }], steps: [], followups: ['Who can ask for one?'],
  }) } });
  out({ type: 'turn.completed', usage: { input_tokens: 1, output_tokens: 1 } });
});
