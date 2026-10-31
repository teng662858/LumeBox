import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const html = fs.readFileSync(new URL('../sources/web/听书合集.html', import.meta.url), 'utf8');
const scripts = [...html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script\s*>/gi)];
for (const [index, script] of scripts.entries()) {
  new vm.Script(script[1], { filename: `听书合集-script-${index}.js` });
}
const start = html.indexOf('var HTTP = {');
const end = html.indexOf('/* ========== MD5', start);
assert(start > 0 && end > start);
const requests = [];
const page = vm.createContext({
  isXmlyUrl: () => false,
  fm: { req: async (url, options) => {
    requests.push({ url, options });
    return { ok: true, status: 200, body: { success: true } };
  } },
});
vm.runInContext(html.slice(start, end), page);
await vm.runInContext("HTTP.request('https://fixture.invalid/api', {method:'POST', data:{q:'测试'}})", page);
assert.equal(requests.length, 1);
assert.equal(requests[0].options.body.q, '测试');
assert.equal(requests[0].options.data.q, '测试');
assert(html.includes('name="lumebox-version" content="1.0.1"'));
console.log(`HTML adapter passed; ${scripts.length} script(s) compiled; body/data preserved.`);
