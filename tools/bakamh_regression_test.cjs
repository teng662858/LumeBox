const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
function source() {
  const ctx = {};
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../sources/comic/巴卡漫画.js'), 'utf8'), ctx);
  return ctx.LumeSource;
}
// Small representative Madara markup, not a claim of a live website response.
const card = '<div class="item-thumb"><a href="/manga/sample/" title="Sample"><img data-src="https://img.example/a.jpg"></a></div>';
const reading = '<div class="reading-content"><div class="page-break"><img data-src="https://img.example/1.jpg"></div><div class="page-break"><img src="https://img.example/2.jpg"></div></div>';
test('baka: home pagination advances and image requests carry source headers', async () => {
 const s = source(); s.__host = 'https://bakamh.com'; const requests = [];
 s.http = { get: async (url) => { requests.push(url); return {status:200, body:card}; } };
 const result = await s.list({page:2});
 assert.equal(requests[0], 'https://bakamh.com/page/2/');
 assert.equal(result.items.length, 1);
 assert.equal(result.items[0].cover, 'https://img.example/a.jpg');
 assert.equal(result.items[0].coverHeaders.Referer, 'https://bakamh.com/');
 assert.ok(result.items[0].coverHeaders['User-Agent']);
});
test('baka: category pagination and last-page result', async () => {
 const s = source(); s.__host = 'https://bakamh.com'; let requested;
 s.http = { get: async url => {requested=url;return {status:200,body:card};} };
 const result = await s.list({categoryId:'manhwa',page:3});
 assert.equal(requested, 'https://bakamh.com/manhwa/page/3/');
 assert.equal(result.hasMore,false);
});
test('baka: chapters sorted, recommendations excluded and shortcut titles replaced', () => {
 const s=source(); const html='<a href="/manga/sample/c-2/">观看最新话</a><a href="/manga/sample/c-2/">第2话</a><a href="/manga/other/c-1/">第1话</a><a href="/manga/sample/c-1/">第1话</a>';
 const chapters=s.__chapters(html,'/manga/sample/');
 assert.deepEqual(Array.from(chapters, c=>c.title), ['第1话','第2话']);
});
test('baka: body images and individual chapter referer', async () => {
 const s=source();s.__host='https://bakamh.com';s.http={get:async()=>({status:200,body:reading})};
 const result=await s.content({chapterId:'/manga/sample/c-1/'});
 assert.deepEqual(Array.from(result.images),['https://img.example/1.jpg','https://img.example/2.jpg']);
 for(const url of result.images) assert.equal(result.imageHeaders[url].Referer,'https://bakamh.com/manga/sample/c-1/');
});
test('baka: Cloudflare and locked chapters return actionable errors', async () => {
 const s=source();s.__host='https://bakamh.com';s.http={get:async()=>({status:403,body:'challenge'})};
 await assert.rejects(()=>s.list({page:1}),/NEED_WEBVIEW_VERIFY/);
 s.http={get:async()=>({status:200,body:'<div class="mkjp-ea-lock"></div>'})};
 await assert.rejects(()=>s.content({chapterId:'/manga/sample/c-1/'}),/需要登录/);
});
test('baka: a shared stylesheet mentioning the lock class does not block a public chapter', async () => {
 const s=source();s.http={get:async()=>({status:200,body:'<style>.mkjp-ea-lock{display:none}</style>'+reading})};
 const c=await s.content({chapterId:'/manga/sample/c-1/'});
 assert.equal(c.images.length,2);
});
test('baka: unreachable primary moves to an available mirror', async () => {
 const s=source();const requests=[];s.http={get:async url=>{requests.push(url);return {status:requests.length===1?502:200,body:card};}};
 const host=await s.__pickHost();assert.notEqual(host + '/', requests[0]);assert.equal(host + '/', requests[1]);assert.ok(requests.length>=2);
});

const locked = '<div class="mkjp-ea-lock"></div>';
const form = '<form><input name="log"><input name="pwd"></form>';
test('baka: configured account logs in only after a locked chapter and retries content', async () => {
 const s=source();s.config={account:'a+b@example.com',password:'secret &'};const posts=[];let logged=false;
 s.http={get:async url=>({status:200,body:url.endsWith('/wp-login.php')?form:logged?reading:locked}),
 post:async(url,body,options)=>{posts.push({url,body,options});logged=true;return {status:200,body:'<body class="logged-in">'};}};
 const result=await s.content({chapterId:'/manga/sample/c-1/'});
 assert.equal(result.images.length,2);assert.equal(posts.length,1);
 assert.equal(posts[0].url,'https://bakamh.com/wp-login.php');
 const data=new URLSearchParams(posts[0].body);assert.equal(data.get('log'),'a+b@example.com');assert.equal(data.get('pwd'),'secret &');
 assert.equal(data.get('redirect_to'),'https://bakamh.com/');
});
test('baka: bad account fails clearly, repeated loads do not repeatedly send passwords', async () => {
 const s=source();s.config={account:'name',password:'secret'};let posts=0;
 s.http={get:async url=>({status:200,body:url.endsWith('/wp-login.php')?form:locked}),post:async()=>{posts++;return {status:200,body:'<div id="login_error">bad</div>'};}};
 await assert.rejects(()=>s.content({chapterId:'/manga/sample/c-1/'}),/账号登录失败/);
 await assert.rejects(()=>s.content({chapterId:'/manga/sample/c-1/'}),/上次账号登录未成功/);assert.equal(posts,1);
});
test('baka: public chapter does not log in and an already logged-in user still needs purchased access', async () => {
 const s=source();s.config={account:'name',password:'secret'};let posts=0;
 s.http={get:async()=>({status:200,body:reading}),post:async()=>{posts++;throw Error('unexpected');}};
 await s.content({chapterId:'/manga/sample/c-1/'});assert.equal(posts,0);
 s.http.get=async url=>({status:200,body:url.endsWith('/wp-login.php')?form:locked});
 s.http.post=async()=>{posts++;return {status:200,body:'<body class="logged-in">'};};
 await assert.rejects(()=>s.content({chapterId:'/manga/sample/c-1/'}),/购买权限/);assert.equal(posts,1);
});
test('baka: account is never automatically submitted to a custom unrecognized host', async () => {
 const s=source();s.__host='https://example.org';s.config={account:'name',password:'secret'};let posts=0;
 s.http={get:async()=>({status:200,body:locked}),post:async()=>{posts++;return {status:200,body:''};}};
 await assert.rejects(()=>s.content({chapterId:'/manga/sample/c-1/'}),/网页登录确认/);assert.equal(posts,0);
});


test('baka: selected mirror is used on first reader entry, including old absolute chapter URLs', async () => {
 const s=source();s.config={domain:'https://bakamh.ru/'};const requests=[];
 s.http={get:async(url,options)=>{requests.push({url,options});return {status:200,body:reading};}};
 const c=await s.content({chapterId:'https://bakamh.com/manga/sample/c-1/'});
 assert.equal(requests[0].url,'https://bakamh.ru/manga/sample/c-1/');
 assert.equal(requests[0].options.headers.Referer,'https://bakamh.ru/');
 assert.equal(c.imageHeaders[c.images[0]].Referer,'https://bakamh.ru/manga/sample/c-1/');
});
test('baka: mirror switch applies to list, search, detail, chapters and reading without an HTTP failure', async () => {
 const s=source();s.config={domain:'https://bakamh.com'};const requests=[];
 s.http={get:async url=>{requests.push(url);return {status:200,body:card+reading+'<h1>Sample</h1><a href="/manga/sample/c-1/">1</a>'};},
 post:async url=>{requests.push(url);return {status:200,body:'{"data":[]}'};}};
 await s.list({page:1});
 s.config={domain:'https://baka3.cfd'};
 await s.list({page:2});await s.list({keyword:'sample'});await s.detail({id:'/manga/sample/'});
 await s.chapters({id:'/manga/sample/'});await s.content({chapterId:'/manga/sample/c-1/'});
 assert.ok(requests.slice(1).every(u=>u.startsWith('https://baka3.cfd/')));
});
test('baka: logging in on selected mirror never posts credentials to old host', async () => {
 const s=source();s.config={domain:'https://bakamh.ru',account:'test',password:'fixture'};let logged=false;const calls=[];
 s.http={get:async url=>{calls.push(url);return {status:200,body:url.endsWith('/wp-login.php')?form:logged?reading:locked};},
 post:async(url,body)=>{calls.push(url);logged=true;assert.equal(new URLSearchParams(body).get('redirect_to'),'https://bakamh.ru/');return {status:200,body:'logged-in'};}};
 assert.equal((await s.content({chapterId:'/manga/sample/c-1/'})).images.length,2);
 assert.ok(calls.every(u=>u.startsWith('https://bakamh.ru/')));
});
test('baka: failed login on one host does not suppress login after switching mirrors', async () => {
 const s=source();s.config={domain:'https://bakamh.com',account:'test',password:'fixture'};let logged=false;const posts=[];
 s.http={get:async url=>({status:200,body:url.endsWith('/wp-login.php')?form:logged?reading:locked}),
 post:async url=>{posts.push(url);logged=url.startsWith('https://bakamh.ru/');return {status:200,body:logged?'logged-in':'<div id="login_error">error</div>'};}};
 await assert.rejects(()=>s.content({chapterId:'/manga/sample/c-1/'}),/登录失败/);
 s.config={...s.config,domain:'https://bakamh.ru'};
 assert.equal((await s.content({chapterId:'/manga/sample/c-1/'})).images.length,2);
 assert.deepEqual(posts,['https://bakamh.com/wp-login.php','https://bakamh.ru/wp-login.php']);
});
test('baka: healthy selected host is never replaced by an automatic primary probe', async () => {
 const s=source();s.config={domain:'https://bakamh.ru'};const calls=[];
 s.http={get:async url=>{calls.push(url);return {status:200,body:reading};}};
 await s.content({chapterId:'/manga/sample/c-1/'});await s.content({chapterId:'/manga/sample/c-2/'});
 assert.equal(calls.length,2);assert.ok(calls.every(u=>u.startsWith('https://bakamh.ru/')));
});
