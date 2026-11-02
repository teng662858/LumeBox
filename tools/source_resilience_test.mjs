import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
function load(name, store = new Map()) {
 const c = vm.createContext({});
 vm.runInContext(fs.readFileSync(`sources/video/${name}.js`, 'utf8'), c);
 c.LumeSource.config = {};
 c.LumeSource.fs = {readText:async()=>{throw Error('use persistent storage');},writeText:async()=>{throw Error('use persistent storage');}};
 c.LumeSource.storage = {get:async(k,fallback)=>store.get(k)||fallback,set:async(k,v)=>store.set(k,v)};
 return c;
}
const ok = body => ({status:200,body});
test('czzy: concurrent detail requests and subsequent chapters share one fetch', async()=>{
 const c=load('czzy');let calls=0;
 c.LumeSource.http={request:async()=>{calls++;return ok('<h1>Example</h1><a href="/movie/1.html">Example</a>');}};
 await Promise.all([c.get('/movie/1.html'),c.get('/movie/1.html')]);
 await c.get('/movie/1.html');assert.equal(calls,1);
 c.detailCache[c.base()+'/movie/1.html'].time=0;
 await c.get('/movie/1.html');assert.equal(calls,2);
});
test('czzy: expired WAF is actionable, not hidden as missing detail',async()=>{
 const c=load('czzy');c.LumeSource.http={request:async()=>({status:403,body:'<title>Just a moment...</title>'})};
 await assert.rejects(c.LumeSource.detail({id:'1'}),/NEED_WEBVIEW_VERIFY/);
});
test('czzy: connection failure discovers and validates the officially published primary',async()=>{
 const c=load('czzy');const urls=[];
 c.LumeSource.http={request:async({url})=>{urls.push(url);
  if(url==='https://cz01.vip/')return ok("href: 'https://new.example'");
  if(url==='https://new.example/movie_bt/')return ok('<a href="/movie/1.html">Example</a>');
  throw Error('offline');}};
 await c.get('/movie_bt/');assert.equal(c.base(),'https://new.example');
 assert.equal(urls.length,3);
});
test('kkys: image origin follows published RDUL and detail skips logos',async()=>{
 const c=load('kkys');c.LumeSource.http={request:async()=>ok('window.RDUL=["https://images.example","https://192.0.2.1:1234"]')};
 await c.discoverImages('<script src="https://static.example/js/rdul.js?v=2"></script>');
 assert.equal(c.imageUrl('/vod1/vod/cover/a.jpg'),'https://images.example/vod1/vod/cover/a.jpg');
 assert.equal(c.parseDetail('<title>Example</title><img src="https://static.example/vod_pc/logo_horizontal.png"><img data-original="/vod1/vod/cover/a.jpg" src="/logo_placeholder.png">').cover,'https://images.example/vod1/vod/cover/a.jpg');
});
test('kkys: challenge is solved once, session persists, expired cookie is renewed',async()=>{
 const store=new Map();const c=load('kkys',store);let calls=0,solves=0;
 c.solveChallenge=()=>{solves++;return 'cdndefend_js_cookie=fresh';};
 c.LumeSource.http={request:async()=>{calls++;return calls===1?{status:850,body:'cdndefend'}:ok('<h1>Example</h1>');}};
 await c.fetchText('/');assert.equal(calls,2);assert.equal(solves,1);
 const restored=load('kkys',store);await restored.restoreSession();assert.equal(restored.SESSION.cookie,'cdndefend_js_cookie=fresh');
 let sent='';restored.solveChallenge=()=> 'cdndefend_js_cookie=renewed';let round=0;
 restored.LumeSource.http={request:async({headers})=>{sent=headers.Cookie;return ++round===1?{status:850,body:'cdndefend'}:ok('ready');}};
 await restored.fetchText('/');assert.equal(round,2);assert.equal(sent,'cdndefend_js_cookie=renewed');
});
test('kkys: detail calls coalesce and session never crosses a configured domain change on restore',async()=>{
 const c=load('kkys');let calls=0;c.LumeSource.http={request:async()=>{calls++;return ok('<title>Example</title>');}};
 await Promise.all([c.fetchText('/detail/1.html'),c.fetchText('/detail/1.html')]);await c.fetchText('/detail/1.html');assert.equal(calls,1);
 const store=new Map([['kkys-session.json',JSON.stringify({domain:'https://old.example',ua:c.UA,time:Date.now(),cookie:'private=value'})]]);
 const other=load('kkys',store);await other.restoreSession();assert.equal(other.SESSION.cookie,'');
});

test('kkys: a transient 503 followed by a successful retry is accepted and cached', async()=>{
 const c=load('kkys');let calls=0;c.LumeSource.http={request:async()=>++calls===1?{status:503,body:''}:ok('<title>Recovered</title>')};
 assert.equal(await c.fetchText('/detail/9.html'),'<title>Recovered</title>');
 await c.fetchText('/detail/9.html');assert.equal(calls,2);
});

test('changing domain on an existing runtime drops cookies and discovered host from the previous domain',async()=>{
 const c=load('kkys');await c.restoreSession();c.SESSION.cookie='old=private';c.SESSION.imageHost='https://old-images.example';
 c.LumeSource.config={domain:'https://new.example'};await c.restoreSession();assert.equal(c.SESSION.cookie,'');assert.equal(c.SESSION.imageHost,'');
 const z=load('czzy');await z.readHost();z.discoveredHost='https://discovered.example';
 z.LumeSource.config={domain:'https://custom.example'};await z.readHost();assert.equal(z.base(),'https://custom.example');
});
