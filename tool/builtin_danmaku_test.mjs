import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawn} from 'node:child_process';

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'lumebox-danmaku-'));
const token = crypto.randomBytes(32).toString('hex');
const manifest = JSON.parse(fs.readFileSync('assets/local_danmaku/manifest.json'));
assert.equal(crypto.createHash('sha256').update(fs.readFileSync('assets/local_danmaku/upstream.cjs')).digest('hex'), manifest.patchedSha256);
for (const name of ['index.js', 'upstream.cjs']) fs.copyFileSync('assets/local_danmaku/' + name, path.join(root, name));
fs.writeFileSync(path.join(root, 'config.js'), 'module.exports=' + JSON.stringify({token, nativeNetwork: true, upstreamPath: path.join(root, 'upstream.cjs')}));
fs.writeFileSync(path.join(root, 'cat.js'), 'module.exports.start=async()=>{catServerFactory((req,res)=>res.end("cat-alive")).listen(0)}');
fs.writeFileSync(path.join(root, 'cat.config.js'), 'module.exports={}');
const spec = {id:'builtin', index:path.join(root,'index.js'), config:path.join(root,'config.js'),dataRoot:root};
const cat = {id:'cat', index:path.join(root,'cat.js'), config:path.join(root,'cat.config.js'),dataRoot:root};
try {
  for (const first of [spec, cat]) {
    const messages = [];
    let failNetwork = false;
    const bridge = http.createServer(async(req,res)=>{
      assert.equal(req.headers['x-catvod-token'], token);
      let body=''; for await(const chunk of req) body+=chunk;
      const message = JSON.parse(body)
      messages.push(message)
      if (message.action === 'danmakuFetch') {
        assert.equal(message.opt.id, 'builtin')
        assert.match(message.opt.url, /^https?:\/\//)
        res.end(JSON.stringify(failNetwork ? { error: 'simulated VPN routing failure' } : { status: 200, headers: {'content-type':'application/json'}, body: Buffer.from('{}').toString('base64') }))
      } else res.end('{}');
    });
    await new Promise(r=>bridge.listen(0,'127.0.0.1',r));
    fs.writeFileSync(path.join(root,'spec.json'),JSON.stringify({token,bridgePort:bridge.address().port,sources:[first]}));
    const child = spawn(process.execPath,[path.resolve('assets/cat/bootstrap.js'),path.join(root,'spec.json')], {stdio:['ignore','ignore','pipe']});
    let errors=''; child.stderr.on('data',b=>errors+=b);
    const wait = async predicate => {
      const end=Date.now()+15000;
      while(!predicate() && Date.now()<end && child.exitCode==null) await new Promise(r=>setTimeout(r,20));
      assert.ok(predicate(), 'Node startup failed: '+errors);
    };
    try {
      await wait(()=>messages.some(m=>m.action==='sourceStarted'&&m.opt.id===first.id)&&messages.some(m=>m.action==='controlReady'));
      const control=messages.find(m=>m.action==='controlReady').opt.address;
      const ctl=async(route,body)=>{
        const r=await fetch(control+route,{method:body?'POST':'GET',headers:{'X-CatVod-Token':token,'content-type':'application/json'},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(10000)});
        assert.equal(r.status,200);return r.json();
      };
      await ctl('/ctl/source',first===cat?spec:cat);
      const status=await ctl('/ctl/status');
      assert.equal(status.sources.filter(s=>s.listening).length,2);
      const base=status.sources.find(s=>s.id==='builtin').address;
      const catBase=status.sources.find(s=>s.id==='cat').address;
      const get=route=>fetch(base+route,{signal:AbortSignal.timeout(10000)});
      assert.equal((await get('/bad/_health')).status,403);
      assert.equal((await get('/'+token+'/_health')).status,200);
      for(const route of ['/api/config','/api/logs','/api/env/set']) assert.equal((await get('/'+token+route)).status,404);
      const settingsUrl=base+'/'+token+'/_settings';
      assert.equal((await fetch(settingsUrl,{method:'POST',body:JSON.stringify({AI_API_KEY:'test-only-local-key'})})).status,200);
      const localSettings=await (await fetch(settingsUrl)).json();
      assert.equal(localSettings.hasAiKey,true);
      assert.equal(localSettings.AI_API_KEY,undefined);
      assert.equal(process.env.AI_API_KEY,undefined);
      await fetch(settingsUrl,{method:'POST',body:JSON.stringify({AI_API_KEY:''})});
      const unmatched=await fetch(base+'/'+token+'/api/v2/match',{method:'POST',body:'{}'});
      assert.equal(unmatched.status,400,'real match endpoint validates request body');
      const result=await get('/'+token+'/api/v2/search/episodes?anime=');
      assert.equal(result.status,400,'real bundled API must validate requests, not return a mock');
      assert.equal((await result.json()).errorCode,400);
      const search = await get('/'+token+'/api/v2/search/episodes?anime=keyboard&episode=1');
      assert.equal(search.status,200);
      await search.json();
      assert.ok(messages.some(m=>m.action==='danmakuFetch'), 'upstream requests must use the native network bridge');
      failNetwork = true;
      const failed = await get('/'+token+'/api/v2/search/episodes?anime=networkfailure&episode=1');
      assert.equal(failed.status,502,'platform network failure must not become a successful empty search');
      assert.match((await failed.json()).errorMessage, /VPN/);
      failNetwork = false;
      const recovered = await get('/'+token+'/api/v2/search/episodes?anime=networkrecovery&episode=1');
      assert.equal(recovered.status,200,'network errors must not poison later requests');
      await recovered.json();
      assert.equal(await(await fetch(catBase)).text(),'cat-alive');
      await ctl('/ctl/stop',{id:'builtin'});
      await ctl('/ctl/source',spec);
      const restart=await ctl('/ctl/status');
      const again=restart.sources.find(s=>s.id==='builtin').address;
      assert.equal((await fetch(again+'/'+token+'/_health')).status,200);
      assert.equal(await(await fetch(catBase)).text(),'cat-alive');
      assert.equal(child.exitCode,null);
      console.log(`PASS: ${first.id} first; bundled API, loopback auth, blocked admin/proxy, stop/restart, Cat coexistence`);
    } finally {
      child.kill(); await new Promise(r=>child.exitCode!=null?r():child.once('exit',r));
      bridge.closeAllConnections(); await new Promise(r=>bridge.close(r));
    }
  }
} finally {
  assert.ok(path.resolve(root).startsWith(path.resolve(os.tmpdir())+path.sep));
  fs.rmSync(root,{recursive:true,force:true});
}
