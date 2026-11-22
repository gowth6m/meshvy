// Firebase Cloud Functions (#8): callables and onRequest functions are endpoints named after their
// export, the website's httpsCallable and fetch calls reach them, and Screens and Health follow.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { REPO, lib, makeProject, run, readGraph, routeKeys, openEndpoints, cleanup } from './helpers.mjs';

const { extract } = await lib('extract.mjs');
const { matchCalls } = await lib('routes.mjs');

let root, graph, summary;
before(() => {
  root = makeProject({}, { arch: {
    project: { name: 'firebase-app', summary: 'Test fixture.' },
    nodes: [
      { id: 'web', label: 'Website', kind: 'ui', summary: 'The website.', paths: ['web/**'] },
      { id: 'fn', label: 'Functions', kind: 'service', summary: 'Cloud Functions.', paths: ['functions/**'] },
    ],
  } });
  fs.cpSync(path.join(REPO, 'tests', 'fixtures', 'firebase-app'), root, { recursive: true });
  summary = run('scan.mjs', root);
  run('build.mjs', root, '--no-claude-md');
  graph = readGraph(root);
});
after(() => cleanup(root));

test('callables and onRequest functions are endpoints, under the name the entry file exports', () => {
  // archiveItem is exported as retireItem; api is an Express app, so its own routes are the endpoints
  assert.deepEqual(routeKeys(graph), [
    'ANY /legacyPing', 'ANY /signDocument', 'CALL /approveItem', 'CALL /legacyStats', 'CALL /retireItem',
    'GET /api/reports', 'POST /api/reports',
  ]);
  assert.equal(graph.routes.find((r) => r.p === '/approveItem').d, 'Approves an item once an admin has reviewed it.');
  assert.equal(graph.routes.find((r) => r.p === '/api/reports' && r.m === 'GET').name, 'Get api reports');
});

test("the website's calls reach the functions: httpsCallable, a helper around it, and fetch", () => {
  const http = graph.links.filter((l) => l.k === 'http').map((l) => `${l.a.slice(2)} -> ${l.b.slice(2)} ${l.labels.join(', ')}`).sort();
  assert.deepEqual(http, [
    'web/src/lib/firebase.ts -> functions/src/docs/api.ts GET /api/reports',
    'web/src/lib/firebase.ts -> functions/src/docs/signDocument.ts ANY /signDocument',
    'web/src/pages/Items.tsx -> functions/src/items/itemCallables.ts CALL /approveItem, CALL /retireItem',
    'web/src/pages/Items.tsx -> functions/src/legacy/v1.js CALL /legacyStats',
  ]);
});

test('Screens shows the server code behind a page that calls functions', () => {
  const items = graph.screens.find((s) => s.url === '/items');
  assert.ok(items, 'the /items screen');
  const server = items.behind.filter((b) => b.kind === 'server').map((b) => b.id);
  assert.deepEqual(server, ['f:functions/src/items/itemCallables.ts', 'f:functions/src/legacy/v1.js']);
});

test('Health: a callable that checks request.auth or context.auth is protected; one that does not is open', () => {
  assert.deepEqual(openEndpoints(graph), ['ANY /legacyPing', 'CALL /retireItem', 'GET /api/reports', 'POST /api/reports']);
});

test('background functions are listed in the scan summary', () => {
  assert.match(summary, /FIREBASE FUNCTIONS {2}3 callable, 3 onRequest, 3 background/);
  assert.match(summary, /nightlyCleanup {2}onSchedule "every day 03:00"/);
  assert.match(summary, /onOrderCreated {2}onDocumentCreated "orders\/\{orderId\}"/);
  assert.match(summary, /weeklyDigest {2}pubsub\.onRun "every monday 09:00"/);
});

test('v1 chains, multi-line generics, grouped names and cloudfunctions.net addresses', () => {
  const fn = extract([
    `const functions = require('firebase-functions');`,
    `exports.report = functions.region('europe-west1').runWith({ memory: '1GB' }).https.onRequest((req, res) => res.end());`,
    `exports.onSignup = functions.auth.user().onCreate(async (user) => {});`,
    `const unsubscribe = db.collection('x').onSnapshot(() => {});`,
  ].join('\n'), 'javascript', 'functions/index.js');
  assert.deepEqual(fn.routes.map((r) => `${r.method} ${r.path}`), ['ANY /report']);
  assert.deepEqual(fn.triggers.map((t) => `${t.name} ${t.on}`), ['onSignup auth.onCreate']);

  const web = extract([
    `import { httpsCallable } from 'firebase/functions';`,
    `const a = httpsCallable<`,
    `  Req,`,
    `  Promise<Res>`,
    `>(getFunctions(app), 'items-approve');`,
    `const b = functions.httpsCallable('legacyName');`,
    'fetch(`https://${REGION}-${PROJECT}.cloudfunctions.net/report`);',
  ].join('\n'), 'typescript', 'web/api.ts');
  assert.deepEqual(web.calls.map((c) => `${c.method} ${c.path}`).sort(), ['CALL /items/approve', 'CALL /legacyName', 'null /report']);
  assert.deepEqual(web.hosts, []);
});

test('a callable only matches callables, and a URL never matches a callable', () => {
  const routes = [
    { file: 'fn/a.ts', method: 'CALL', path: '/approve' },
    { file: 'api/b.ts', method: 'ANY', path: '/approve' },
  ];
  const files = [{ path: 'web/x.ts', calls: [{ path: '/approve', method: 'CALL', line: 1 }, { path: '/approve', method: 'POST', line: 2 }] }];
  assert.deepEqual(matchCalls(files, routes).map((h) => `${h.line} ${h.to}`), ['1 fn/a.ts', '2 api/b.ts']);
});
