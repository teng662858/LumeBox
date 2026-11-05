import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const code = fs.readFileSync(new URL('../sources/comic/i275.js', import.meta.url), 'utf8');
function fixture({hiddenCookie = false, reject = false} = {}) {
  const store = new Map();
  const calls = [];
  let seeded = false;
  const ctx = vm.createContext({console, setTimeout, clearTimeout});
  vm.runInContext(code, ctx);
  Object.assign(ctx.LumeSource, {config: {}, fs: {
    exists: async k => store.has(k), readText: async k => store.get(k), writeText: async (k,v) => store.set(k,v),
  }, http: {get: async (url, options) => {
    calls.push({url, headers: options?.headers || {}});
    if (url.includes('api_chapter.php')) return {status: 200, body: JSON.stringify(seeded && !reject ? {url: 'https://media.test/book.mp3'} : {error: '非法访问'})};
    seeded = true;
    return {status: 200, headers: hiddenCookie ? {} : {'set-cookie': 'PHPSESSID=fresh; Path=/'}, body: ''};
  }}});
  store.set(ctx.SESSION_KEY, JSON.stringify({origin: 'https://www.i275.com', cookie: 'PHPSESSID=expired', seeded: true, t: Date.now()}));
  return {ctx, calls, store};
}
for (const hiddenCookie of [false, true]) {
  const {ctx, calls} = fixture({hiddenCookie});
  const result = await ctx.chapterAudio('1', '2');
  assert.equal(result.url, 'https://media.test/book.mp3');
  assert.equal(calls.length, 3, 'expired session: API, real reseed, API');
  assert.equal(calls[1].url, 'https://www.i275.com/');
  if (!hiddenCookie) assert.equal(calls[2].headers.Cookie, 'PHPSESSID=fresh');
}
{
  const {ctx, calls} = fixture({reject: true});
  await assert.rejects(ctx.chapterAudio('1', '2'), /非法访问/);
  assert.equal(calls.length, 3, 'persistent rejection must not retry forever');
}
{
  const {ctx, calls} = fixture();
  ctx.LumeSource.config.domain = 'https://mirror.test';
  await ctx.chapterAudio('1', '2');
  assert.equal(calls[0].url, 'https://mirror.test/');
  assert.equal(calls.some(c => c.headers.Cookie?.includes('expired')), false);
}
{
  const {ctx} = fixture();
  ctx.fetchPage = async () => ({html: '', url: 'https://www.i275.com/'});
  ctx.parseHomeNewest = () => [{id:'new', title:'new'}];
  ctx.parseHot = () => [];
  ctx.search = async () => ({items:[{id:'genre', title:'genre'}]});
  const rows = await ctx.homeBoard();
  assert.equal(rows[0].moreUrl, 'kw:悬疑');
  assert.equal(rows[0].items[0].id, 'genre');
  ctx.search = async () => { throw Error('network'); };
  assert.equal((await ctx.homeBoard())[0].items[0].id, 'new');
}
{
  const {ctx} = fixture();
  let count = 0;
  ctx.LumeSource.http.get = async () => ({status: 200, body: JSON.stringify({list:[{path:'https://media.test/' + (++count) + '.m4a'}]})});
  assert.equal(await ctx.resolveLrts('lrts$1#2#1'), 'https://media.test/1.m4a');
  assert.equal(await ctx.resolveLrts('lrts$1#2#1'), 'https://media.test/2.m4a');
}
console.log('i275 source: 7 offline cases passed');
