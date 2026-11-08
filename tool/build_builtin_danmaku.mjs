import {createRequire} from 'node:module';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
const root=path.resolve(process.argv[2]||'work/danmaku-update');
const require=createRequire(path.join(root,'package.json'));
const {build}=require('esbuild');
const out=path.resolve(process.argv[3]||'assets/local_danmaku');fs.mkdirSync(out,{recursive:true});
const tmp=path.join(root,'.lumebox-build');fs.mkdirSync(tmp,{recursive:true});
const nodeFetch=require.resolve('node-fetch');
const bridge=path.join(tmp,'bridge.mjs');
fs.writeFileSync(bridge,`import fallback,{Request,Response,Headers} from ${JSON.stringify(nodeFetch)};
export {Request,Response,Headers};
let native;
export let lumeDataRoot=__dirname+"/data";
export function setDataRoot(value){lumeDataRoot=value}
export function setNativeFetch(fn){native=fn}
export async function fetch(url,options){
 if(!native)return fallback(url,options);
 const req=new Request(url,options), body=Buffer.from(await req.arrayBuffer());
 const result=await native(req.url,{method:req.method,headers:Object.fromEntries(req.headers),body:body.toString('base64'),signal:req.signal,redirect:req.redirect});
 return new Response(Buffer.from(result.body,'base64'),{status:result.status,headers:result.headers});
}
export default fetch;
`);
const entry=path.join(tmp,'entry.mjs');
fs.writeFileSync(entry,`import {handleRequest} from '../danmu_api/worker.js';
import {Globals} from '../danmu_api/configs/globals.js';
export const version=Globals.VERSION;
export const reset=()=>{Globals.aiValid=false};
import {Request,setNativeFetch} from './bridge.mjs';
export {setDataRoot} from './bridge.mjs';
export const setFetch=setNativeFetch;
export const handle=(url,env,method='GET',body)=>handleRequest(new Request(url,{method,...(body?{body}: {})}),env,'node','127.0.0.1');
`);
await build({entryPoints:[entry],outfile:path.join(out,'upstream.cjs'),bundle:true,platform:'node',format:'cjs',target:'node18',minify:true,legalComments:'inline',inject:[bridge],plugins:[{
 name:'mobile-isolation',setup(b){
 b.onResolve({filter:/^node-fetch$/},args=>args.importer===bridge?null:{path:bridge});
 b.onLoad({filter:/\.js$/},args=>{
 if(!args.path.startsWith(path.join(root,'danmu_api')))return;
 let contents=fs.readFileSync(args.path,'utf8').replaceAll('process.cwd()','lumeDataRoot');
 if(args.path.endsWith(path.join('configs','envs.js'))){
 contents=contents.replace(/process\.env\?\.\[key\]/g,'undefined').replace(/process\.env\[key\]/g,'undefined');
 contents=contents.replace('undefined = String(value);','this.env[key] = String(value);');
 }
 return {contents,loader:'js'};
 });
 }}]});
const sha=crypto.createHash('sha256').update(fs.readFileSync(path.join(out,'upstream.cjs'))).digest('hex');
const version=fs.readFileSync(path.join(root,'danmu_api/configs/globals.js'),'utf8').match(/VERSION:\s*'([^']+)'/)[1];
fs.writeFileSync(path.join(out,'manifest.json'),JSON.stringify({project:'https://github.com/huangxd-/danmu_api',version,patchedSha256:sha,upstreamTagCommit:(await import('node:child_process')).execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8'}).trim(),adapterSha256:crypto.createHash('sha256').update(fs.readFileSync(path.join(out,'index.js'))).digest('hex'),build:'tool/build_builtin_danmaku.mjs'},null,2)+'\n');
console.log(version,sha);

if(process.env.BUILTIN_SIGNING_KEY){
 const manifest=fs.readFileSync(path.join(out,'manifest.json'));
 fs.writeFileSync(path.join(out,'manifest.sig'),crypto.sign('sha256',manifest,process.env.BUILTIN_SIGNING_KEY).toString('base64')+'\n');
}
