// LumeSource: {"id":"bakamh_comic","name":"巴卡漫画","version":"2.2.1","category":"comic","contentCategory":"adult","settingsApiVersion":2,"mirrors":["https://bakamh.com","https://bakamh.ru","https://baka3.cfd","https://baka1.cfd","https://baka2.cfd"],"network":"proxy","icon":"https://bakamh.app/favicon.ico","settings":[{"key":"publishPage","type":"action","action":"openWebsite","title":"打开发布页（bakamh.app）","url":"https://bakamh.app/","description":"官方发布页：实时更新 bakamh.com / bakamh.ru / baka*.cfd 等地址"},{"key":"note","type":"info","title":"站点说明","description":"巴卡漫画（Madara/WordPress）：韩漫/BL/GL/连载/完结 分类，条目 /manga/<slug>/，章节 /c-N/，正文图片在 reading-content。站点在 Cloudflare 后面，直连常是「Just a moment」→ 会抛 NEED_WEBVIEW_VERIFY，用 App 网页视图过一次校验即可；部分章节需登录/购买，可在「源设置 → 账号登入」填账号。"}]}
// 发布页 https://bakamh.app/ ：官方地址发布页（bakamh.com 海外、bakamh.ru / baka3.cfd / baka1.cfd / baka2.cfd 四条备用）
// Reimplemented from bakamh.com public Madara pages; mirrors match bakamh.app publisher.
// Embedded into each source by tools/build_requested_sources.py; no remote code imports.
var H = {
  base: '', name: '巴卡漫画', ua: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1',
  clean: function (s) { return this.entity(String(s || '').replace(/<script\b[\s\S]*?<\/script>/gi,'').replace(/<style\b[\s\S]*?<\/style>/gi,'').replace(/<\/(?:p|div|section|li|h\d)>|<br\s*\/?>/gi,'\n').replace(/<[^>]+>/g,'' )).replace(/[ \t]+/g,' ').replace(/\n\s*\n/g,'\n').trim(); },
  entity: function(s) {return String(s||'').replace(/&(?:amp|quot|apos|lt|gt|nbsp);|&#(?:x[0-9a-f]+|\d+);/gi,function(v){var map={'&amp;':'&','&quot;':'"','&apos;':"'",'&lt;':'<','&gt;':'>','&nbsp;':' '};if(map[v])return map[v];var code=v.charAt(2)==='x'?parseInt(v.slice(3),16):parseInt(v.slice(2),10);return Number.isFinite(code)?String.fromCodePoint(code):v;});},
  attr: function(s,k) {var m=new RegExp('(?:^|\\s)'+k+'\\s*=\\s*(?:"([^"]*)"|\x27([^\x27]*)\x27|([^\\s>]+))','i').exec(s||'');return this.entity(m?(m[1]!==undefined?m[1]:m[2]!==undefined?m[2]:m[3]):'');},
  abs: function(u,from) {u=this.entity(u).trim();if(!u)return '';if(/^https?:\/\//i.test(u))return u;if(u.indexOf('//')===0)return 'https:'+u;var b=from||this.base;if(u.charAt(0)==='/')return /^https?:\/\/[^/]+/.exec(b)[0]+u;return b.replace(/[^/]*$/,'')+u;},
  headers: function(page) {return {'User-Agent':this.ua,'Referer':page||this.base+'/'};},
  response: function(r) {if(!r)throw new Error(this.name+'：没有网络响应');var s=r.status;if(s===403||s===503||s===521)throw new Error('NEED_WEBVIEW_VERIFY：'+this.name+' 需要网页验证（HTTP '+s+'）');if(s!==200)throw new Error(this.name+'：请求失败（HTTP '+s+'）');var b=String(r.body||'');if(/cf-chl-|Just a moment|cf-turnstile/i.test(b))throw new Error('NEED_WEBVIEW_VERIFY：'+this.name+' 需要网页验证');return b;},
  get: async function(u) {return this.response(await LumeSource.http.get(this.abs(u,this.base+'/'),{headers:this.headers()}));},
  post: async function(u,data) {var h=this.headers();h['Content-Type']='application/x-www-form-urlencoded';h['X-Requested-With']='XMLHttpRequest';return this.response(await LumeSource.http.post(this.abs(u,this.base+'/'),data,{headers:h}));},
  json: async function(u) {try{return JSON.parse(await this.get(u));}catch(e){if(/NEED_WEBVIEW_VERIFY|HTTP/.test(String(e)))throw e;throw new Error(this.name+'：数据格式已变化');}},
  tree: function(html) {html=String(html).replace(/<!--[^]*?-->/g,'').replace(/<script\b[^]*?<\/script>|<style\b[^]*?<\/style>/gi,'');var root={tag:'root',attrs:{},children:[],raw:''},stack=[root],re=/<\/?([a-z][\w:-]*)\b([^>]*)>|([^<]+)/gi,m;while((m=re.exec(html))){var parent=stack[stack.length-1];if(m[3]){parent.children.push({tag:'#text',raw:m[3],attrs:{},children:[]});continue;}var tag=m[1].toLowerCase();if(m[0].charAt(1)==='/'){for(var i=stack.length-1;i>0;i--)if(stack[i].tag===tag){stack.length=i;break;}continue;}var attrs={},ar=/([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/g,a;while((a=ar.exec(m[2])))attrs[a[1].toLowerCase()]=H.entity(a[2]!==undefined?a[2]:a[3]!==undefined?a[3]:a[4]);var node={tag:tag,attrs:attrs,children:[],raw:'',parent:parent};parent.children.push(node);if(!/^(?:img|input|br|hr|meta|link|source|area|embed|wbr)$/.test(tag)&&! /\/$/.test(m[2]))stack.push(node);}return root;},
  all: function(node,pred) {var out=[],stack=[node];while(stack.length){var n=stack.pop();if(pred(n))out.push(n);if(n.tag==='script'||n.tag==='style')continue;for(var i=n.children.length-1;i>=0;i--)stack.push(n.children[i]);}return out;},
  cls: function(n,c) {return (' '+(n.attrs.class||'')+' ').indexOf(' '+c+' ')>=0;},
  text: function(root) {if(!root)return '';if(root.tag==='#text')return this.entity(root.raw);if(root.tag==='script'||root.tag==='style')return '';var frames=[{node:root,i:0,parts:[]}];while(true){var top=frames[frames.length-1],node=top.node;if(top.i<node.children.length){var child=node.children[top.i++];if(child.tag==='#text'){top.parts.push(this.entity(child.raw));continue;}if(child.tag==='script'||child.tag==='style'){top.parts.push('');continue;}frames.push({node:child,i:0,parts:[]});continue;}var rendered=this.clean(top.parts.join(/^(?:p|div|section|article|li|br)$/.test(node.tag)?'\n':''));frames.pop();if(!frames.length)return rendered;frames[frames.length-1].parts.push(rendered);}},
  first: function(node,pred) {return this.all(node,pred)[0];},
  links: function(node,pattern) {return this.all(node,function(n){return n.tag==='a'&&pattern.test(n.attrs.href||'');});},
  image: function(node) {var img=this.first(node,function(n){return n.tag==='img';});return img?this.abs(img.attrs['data-original']||img.attrs['data-src']||img.attrs['data-lazy-src']||img.attrs.src,this.base+'/'):null;},
  title: function(tree) {var h=this.first(tree,function(n){return n.tag==='h1';});if(h)return this.text(h);var meta=this.first(tree,function(n){return n.tag==='meta'&&(n.attrs.property==='og:title'||n.attrs.name==='title');});if(meta)return meta.attrs.content;return this.text(this.first(tree,function(n){return n.tag==='title';}));},
  cover: function(tree) {var n=this.first(tree,function(n){return n.tag==='meta'&&n.attrs.property==='og:image';});return n?this.abs(n.attrs.content):null;},
  unique: function(items) {var seen={};return items.filter(function(i){if(!i.id||seen[i.id]||!i.title)return false;seen[i.id]=true;return true;});},
  next: function(tree,page) {return this.links(tree,new RegExp('(?:[?&]page=|/page/|/page-)(?:'+(page+1)+')(?:\\D|$)')).length>0;},
  imageContent: function(images,page) {if(!images.length)throw new Error(this.name+'：没有读取到正文图片');var headers={};images.forEach(function(u){headers[u]=H.headers(page);});return {kind:'images',images:images,imageHeaders:headers};},
  textContent: function(text) {if(!text||text.length<20)throw new Error(this.name+'：没有读取到正文，请确认章节是否需要登录');return {kind:'text',text:text};}
};

H.base="https://bakamh.com";H.name="巴卡漫画";
var LumeSource={id:"bakamh_comic",name:"巴卡漫画",version:"2.2.1",category:"comic",

__host:'',
// Every entry uses the selected site, including a direct reader reopen. Keep a
// fallback only while the configured domain is unchanged; cookies stay per host.
__base(){var cfg=String((this.config&&this.config.domain)||'').trim().replace(/\/+$/,'');if(cfg!==this.__configuredHost){this.__configuredHost=cfg;this.__host=cfg||this.__host||'https://bakamh.com';}H.base=this.__host||'https://bakamh.com';return H.base;},
async __pickHost(){var hosts=[];var cfg=(this.config&&this.config.domain)?String(this.config.domain).replace(/\/+$/,''):'';if(cfg)hosts.push(cfg);['https://bakamh.com','https://bakamh.ru','https://baka3.cfd','https://baka1.cfd','https://baka2.cfd'].forEach(function(h){if(hosts.indexOf(h)<0)hosts.push(h);});for(var i=0;i<hosts.length;i++){var r=await this.http.get(hosts[i]+'/',{headers:H.headers(hosts[i]+'/')});if(r.status===200){H.response(r);this.__host=hosts[i];H.base=hosts[i];return hosts[i];}if(r.status===403||r.status===503||r.status===521)H.response(r);}throw new Error('巴卡漫画：站点暂时不可用，请稍后重试');},
async __get(path){H.base=this.__base();var u=H.abs(String(path).replace(/^https?:\/\/[^/]+/,'')),r=await this.http.get(u,{headers:H.headers(H.base+'/')});if(r.status===502||r.status===404){this.__host=await this.__pickHost();u=H.abs(String(path).replace(/^https?:\/\/[^/]+/,''));r=await this.http.get(u,{headers:H.headers(H.base+'/')});}return H.response(r);},
async categories(){return [{id:'',title:'全部'},{id:'manhwa',title:'韩漫'},{id:'bl',title:'BL'},{id:'gl',title:'GL'},{id:'allages',title:'全年龄'},{id:'en-manga',title:'英文'},{id:'on-going',title:'连载'},{id:'end',title:'完结'}];},
__items(html){var t=H.tree(html);return H.unique(H.all(t,function(n){return H.cls(n,'item-thumb');}).map(function(n){var a=H.first(n,function(x){return x.tag==='a'&&/\/manga\//.test(x.attrs.href||'');});return {id:a?a.attrs.href.replace(/^https?:\/\/[^/]+/,''):'',title:a?(a.attrs.title||H.text(a)):'',cover:H.image(n),coverHeaders:H.headers(H.base+'/')};}));},
async home(){var r=await this.list({page:1});return [{title:'最新',items:r.items.slice(0,12)}];},
async list(a){a=a||{};var p=Number(a.page)||1;if(a.keyword){if(p>1)return {items:[],hasMore:false};H.base=this.__base();var raw=H.response(await this.http.post(H.base+'/wp-admin/admin-ajax.php','action=wp-manga-search-manga&title='+encodeURIComponent(a.keyword),{headers:Object.assign(H.headers(),{'Content-Type':'application/x-www-form-urlencoded','X-Requested-With':'XMLHttpRequest'})}));var result=JSON.parse(raw);var rows=Array.isArray(result.data)?result.data:[];return {items:H.unique(rows.map(function(x){return {id:String(x.url||'').replace(/^https?:\/\/[^/]+/,''),title:H.clean(x.title),cover:null};})),hasMore:false};}var c=String(a.categoryId||'').replace(/^\/+|\/+$/g,'');if(c&&!/^[a-z-]+$/.test(c))throw new Error('巴卡漫画：无效分类');var path='/'+(c?c+'/':'')+(p>1?'page/'+p+'/':'');var html=await this.__get(path);return {items:this.__items(html),hasMore:H.next(H.tree(html),p)};},
async detail(a){var t=H.tree(await this.__get(a.id));var scope=H.first(t,function(n){return H.cls(n,'summary_image');});return {id:a.id,title:H.title(t),cover:H.image(scope||t),coverHeaders:H.headers(H.base+'/')};},
__chapters(html,id){var base=String(id).replace(/^https?:\/\/[^/]+/,'').replace(/\/?$/,'/');var t=H.tree(html),seen={};H.links(t,/\/manga\/[^/]+\/c-[^/]+\/?$/).forEach(function(n){var path=n.attrs.href.replace(/^https?:\/\/[^/]+/,'');if(path.indexOf(base)!==0)return;var title=H.text(n);if(!seen[path]||(/最新|观看|阅读/.test(seen[path].title)&&! /最新|观看|阅读/.test(title)))seen[path]={id:path,title:title};});return Object.keys(seen).map(function(k){return seen[k];}).sort(function(a,b){return parseFloat((/\/c-([\d.]+)/.exec(a.id)||[])[1]||0)-parseFloat((/\/c-([\d.]+)/.exec(b.id)||[])[1]||0);});},
async chapters(a){var rows=this.__chapters(await this.__get(a.id),a.id);if(!rows.length)throw new Error('巴卡漫画：详情页未提供章节，请先完成网页验证');return rows;},

async __loginIfConfigured(){
 var c=this.config||{}, account=String(c.account||'').trim(), password=String(c.password||'');
 if(!account||!password)return false;
 var base=this.__base();
 var key=base+'\u0000'+account+'\u0000'+password;if(this.__loginAttempted===key)throw new Error('巴卡漫画：上次账号登录未成功，请检查账号密码或使用网页登录');
 this.__loginAttempted=key;
 if(!/^https:\/\/(?:bakamh\.(?:com|ru)|baka[123]\.cfd)$/.test(base))throw new Error('巴卡漫画：请使用网页登录确认当前站点');
 var form=await this.__get('/wp-login.php');
 if(!/name=["']log["']/.test(form)||! /name=["']pwd["']/.test(form))throw new Error('巴卡漫画：站点登录表单已变化，请使用网页登录');
 var data='log='+encodeURIComponent(account)+'&pwd='+encodeURIComponent(password)+'&wp-submit=Log+In&redirect_to='+encodeURIComponent(base+'/')+'&testcookie=1';
 var response=H.response(await this.http.post(base+'/wp-login.php',data,{headers:Object.assign(H.headers(base+'/wp-login.php'),{'Content-Type':'application/x-www-form-urlencoded'})}));
 if(/id=["']login_error["']|class=["'][^"']*login-error/.test(response))throw new Error('巴卡漫画：账号登录失败，请核对账号密码或完成网页验证');
 return true;
},
async content(a){var id=a.chapterId||a.id,html=await this.__get(id);var t=H.tree(html);if(H.first(t,function(n){return H.cls(n,'mkjp-ea-lock');})&&await this.__loginIfConfigured()){html=await this.__get(id);t=H.tree(html);}if(H.first(t,function(n){return H.cls(n,'mkjp-ea-lock');}))throw new Error('巴卡漫画：本章节需要登录或购买；可在源设置中登录，已登录仍锁定时请核对该章购买权限');var scope=H.first(t,function(n){return H.cls(n,'reading-content');});var images=scope?H.all(scope,function(n){return n.tag==='img';}).map(function(n){return H.abs(n.attrs['data-src']||n.attrs['data-lazy-src']||n.attrs.src||'').replace(/^http:/,'https:');}).filter(function(u){return /^https?:/.test(u);}):[];return H.imageContent(Array.from(new Set(images)),H.abs(String(id).replace(/^https?:\/\/[^/]+/,'')));}

};
