import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';
function load() {
  const context = vm.createContext({});
  vm.runInContext(fs.readFileSync('sources/video/yingshidao.js', 'utf8'), context);
  const source = context.LumeSource;
  source.config = { domain: 'https://tv.yingshidao.com', cookie: 'private_session=example' };
  source.http = { get() { throw Error('unexpected HTTP request'); }, post() { throw Error('unexpected guest admission'); } };
  return source;
}
test('web playback preserves each selected episode without guest admission or exporting credentials', async () => {
  const s = load();
  for (const episode of ['ep_first', 'ep_second', 'ep_&?#']) {
    const r = await s.content({id:'mov_example', chapterId:'ep:' + episode});
    const u = new URL(r.url);
    assert.equal(r.kind, 'webplayer');
    assert.equal(u.pathname, '/video/mov_example');
    assert.equal(u.searchParams.get('ep'), episode);
    assert.equal(u.searchParams.get('play'), '1');
    assert.equal(r.headers, undefined);
    assert(!JSON.stringify(r).includes('private_session'));
  }
});
test('web fallback and missing chapter retain the movie without inventing an episode', async () => {
  const s = load();
  for (const chapterId of ['web:mov_example', '']) {
    const r = await s.content({id:'mov_example', chapterId});
    assert.equal(r.url, 'https://tv.yingshidao.com/video/mov_example?play=1');
  }
  await assert.rejects(s.content({}), /缺少影片编号/);
});
test('configured domain is honored and normal webpage login is offered', async () => {
  const s = load();
  s.config.domain = 'https://mirror.example/';
  const r = await s.content({id:'mov_example', chapterId:'ep:ep_second'});
  assert.equal(new URL(r.url).origin, 'https://mirror.example');
  assert(s.settings.some(x => x.action === 'openWebsite' && new URL(x.url).pathname === '/login'));
});
