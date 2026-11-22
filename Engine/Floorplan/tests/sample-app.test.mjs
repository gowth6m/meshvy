// End to end: map a small two-repo shop the way the skill does, then check the map, the Health
// check, the privacy promises (offline, no secret values, nothing committed) and an update.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { shopApp, scanAndBuild, run, readGraph, readJson, writeJson, routeKeys, openEndpoints, allFiles, cleanup, FAKE_PASSWORD } from './helpers.mjs';

let root, graph, output;
before(() => { root = shopApp(); output = scanAndBuild(root); graph = readGraph(root); });
after(() => cleanup(root));

test('both repos are found and every file lands in a part of the map', () => {
  assert.deepEqual(graph.meta.repos.map((r) => r.path).sort(), ['shop-api', 'shop-web']);
  assert.equal(graph.meta.counts.unassigned, 0);
  assert.ok(graph.files.some((f) => f.p === 'shop-web/src/App.jsx' && f.n === 'web'));
});

test('endpoints get the prefix of the router they are mounted under', () => {
  assert.deepEqual(routeKeys(graph), ['DELETE /admin/users/:id', 'GET /api/orders', 'POST /api/notes', 'POST /api/orders/:id/refund']);
});

test("the website's requests are matched to the server's endpoints across repos", () => {
  const http = graph.links.filter((l) => l.k === 'http' && l.a === 'f:shop-web/src/api.js').map((l) => l.b);
  assert.ok(http.includes('f:shop-api/routes/orders.js'), JSON.stringify(graph.links.filter((l) => l.k === 'http')));
  assert.ok(graph.links.some((l) => l.k === 'import' && l.a === 'f:shop-web/src/App.jsx' && l.b === 'f:shop-web/src/api.js'));
});

test('Health flags only the endpoint with no login check, and the hard-coded password', () => {
  // orders use requireAuth on the route, admin is checked where it's mounted, notes has nothing
  assert.deepEqual(openEndpoints(graph), ['POST /api/notes']);
  const secret = graph.health.issues.find((i) => i.kind === 'secret');
  assert.ok(secret, 'the password in config.js is reported');
  assert.deepEqual(secret.locations, [{ file: 'shop-api/config.js', line: 1 }]);
});

test('the secret value is never written anywhere Floorplan writes, or printed', () => {
  assert.ok(!output.includes(FAKE_PASSWORD), 'scan/build output');
  for (const f of allFiles(path.join(root, 'floorplan'))) assert.ok(!f.text.includes(FAKE_PASSWORD), path.relative(root, f.path));
});

test('the map makes no outside requests: scripts, styles and fonts are all inside the file', () => {
  const html = fs.readFileSync(path.join(root, 'floorplan', 'index.html'), 'utf8');
  assert.doesNotMatch(html, /<script[^>]*\ssrc\s*=\s*["']?(https?:)?\/\//i);
  assert.doesNotMatch(html, /<link[^>]*\shref\s*=\s*["']?(https?:)?\/\//i);
  assert.doesNotMatch(html, /url\(\s*["']?(https?:)?\/\//i);
  assert.doesNotMatch(html, /@import/);
  assert.match(html, /@font-face\{font-family:"Inter"/);
});

test('nothing Floorplan makes is committed: floorplan/ ignores itself', () => {
  assert.equal(fs.readFileSync(path.join(root, 'floorplan', '.gitignore'), 'utf8').trim().split('\n').pop(), '*');
});

test('query.mjs finds things on the map by plain words', () => {
  const found = JSON.parse(execFileSync(process.execPath, [path.join(root, 'floorplan', 'query.mjs'), 'find', 'refund'], { encoding: 'utf8' }));
  const ids = JSON.stringify(found);
  assert.ok(ids.includes('r:'), `an endpoint is found: ${ids.slice(0, 300)}`);
});

test('an update carries descriptions over to a renamed file', () => {
  const descFile = path.join(root, 'floorplan', 'descriptions', 'api.json');
  const desc = { name: 'Customer notes', description: 'Saves a note a customer leaves.' };
  writeJson(descFile, { files: { 'shop-api/routes/notes.js': desc } });
  fs.renameSync(path.join(root, 'shop-api/routes/notes.js'), path.join(root, 'shop-api/routes/feedback.js'));
  const server = path.join(root, 'shop-api/server.js');
  fs.writeFileSync(server, fs.readFileSync(server, 'utf8').replaceAll('notes', 'feedback'));
  run('refresh.mjs', root);
  const files = readJson(descFile).files;
  assert.deepEqual(files['shop-api/routes/feedback.js'], desc);
  assert.equal(files['shop-api/routes/notes.js'], undefined);
  assert.equal(readGraph(root).files.find((f) => f.p === 'shop-api/routes/feedback.js').name, 'Customer notes');
});
