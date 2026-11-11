// LumeSource: {"id":"juzhi4k_video","name":"橘汁视频4K · JS","version":"1.0.0","category":"video","contentCategory":"movie","network":"direct","mirrors":["https://gdsaj.hzhcbkj.cn"],"icon":"","settingsApiVersion":2,"requiresSettings":["settingsActions"]}
// LumeRuntime: javascript
// Port of the supplied Spider's public protobuf contract. Uses native RSA/AES;
// no Python, account registration, loopback server or external parsing bridge.
// M蓝光/NS蓝光 first; all upstream lines remain selectable. Labels are source
// line names, not verified resolution claims. Requires binary POST bridge support.
var JZ_SITE = 'https://gdsaj.hzhcbkj.cn';
var JZ_PUBLIC = 'MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCr8SzZhjYy+rsya1K09t8d2K50pWFoBkgUqMpKOiW+3IEVKd4eTdvg9RSOjQ82kypL6R9BnsmrS1V8s4PVDwjQbUtYhTPPC9Hz16qY7rpD6m0d2vr09/UpWQ5uOy9PR0QTrsioveZ+DIe9jc3C+zBCu/kZSY/R8stwJoiitki3gwIDAQAB';
var JZ_SAFE = 'OC1A06E197EF10CF3F6058CA7A803B5E';
var JZ_SECURITY = 'SGNWTJHSK05SU3NBSLJQSELXREFRPT0=';
var JZ_UA = 'okhttp/3.12.1';
var JZ_DEVICE = '';
var JZ_SECONDARY = '';
var JZ_SECONDARY_AT = 0;
var JZ_PENDING = null;
var JZ_DETAILS = {};

function jzBase() { return String((LumeSource.config || {}).domain || JZ_SITE).replace(/\/+$/, ''); }
function jzBytes(text) { return unescape(encodeURIComponent(String(text))); }
function jzText(bytes) { return decodeURIComponent(escape(bytes)); }
function jzPem(key) { return '-----BEGIN PUBLIC KEY-----\n' + key + '\n-----END PUBLIC KEY-----'; }
function jzRandom(count) {
  var chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789', out = '';
  while (out.length < count - 1) out += chars.charAt(Math.floor(Math.random() * chars.length));
  return out + '=';
}
function jzVarint(value) {
  var out = '';
  do { var b = value % 128; value = Math.floor(value / 128); out += String.fromCharCode(b + (value ? 128 : 0)); } while (value);
  return out;
}
function jzField(field, value) {
  if (typeof value === 'number') return jzVarint(field * 8) + jzVarint(value);
  return jzVarint(field * 8 + 2) + jzVarint(value.length) + value;
}
function jzPb(bytes) {
  var rows = [], at = 0;
  function read() {
    var value = 0, factor = 1;
    for (var i = 0; i < 10; i++) {
      if (at >= bytes.length) throw new Error('橘汁响应 protobuf 截断');
      var b = bytes.charCodeAt(at++); value += (b & 127) * factor;
      if (b < 128) return value;
      factor *= 128;
    }
    throw new Error('橘汁响应 protobuf varint 超长');
  }
  while (at < bytes.length) {
    var tag = read(), field = Math.floor(tag / 8), wire = tag % 8, value;
    if (!field) throw new Error('橘汁响应 protobuf 字段无效');
    if (wire === 0) value = read();
    else if (wire === 2) { var size = read(); if (size > bytes.length - at) throw new Error('橘汁响应 protobuf 长度无效'); value = bytes.slice(at, at + size); at += size; }
    else if (wire === 1 || wire === 5) { var width = wire === 1 ? 8 : 4; if (at + width > bytes.length) throw new Error('橘汁响应字段截断'); value = bytes.slice(at, at + width); at += width; }
    else throw new Error('橘汁响应 protobuf 类型不支持');
    rows.push({field: field, wire: wire, value: value});
  }
  return rows;
}
function jzGet(rows, field, fallback) {
  for (var i = 0; i < rows.length; i++) if (rows[i].field === field) return rows[i].value;
  return fallback;
}
function jzString(rows, field) { return jzText(jzGet(rows, field, '')); }
async function jzRequest(path, payload, headers) {
  var options = {url: jzBase() + path, method: payload == null ? 'GET' : 'POST', headers: headers || {'User-Agent': JZ_UA}, binary: true};
  if (payload != null) options.bodyBase64 = btoa(payload);
  var reply = await LumeSource.http.request(options);
  if (!reply || reply.status !== 200) throw new Error('橘汁接口请求失败：HTTP ' + (reply && reply.status || 0));
  if (payload == null) return JSON.parse(reply.body);
  var binary = reply.bytes || reply.bodyBase64;
  if (!binary) throw new Error('App 未提供二进制响应，请更新 LumeBox');
  var top = jzPb(atob(binary));
  if (jzGet(top, 1, 0) !== 200) throw new Error('橘汁接口拒绝请求：' + (jzString(top, 2) || jzGet(top, 1, 0)));
  return jzGet(top, 3, '');
}
function jzPublicParams() {
  if (!JZ_DEVICE) JZ_DEVICE = 'LUME' + Date.now().toString(16).toUpperCase() + Math.random().toString(16).slice(2, 8).toUpperCase();
  return {plat:'tv',vOs:'16',_vOsCode:'36',vApp:'3026',vName:'3.0.2.6',pkg:'com.exxammpea.a1',appName:'%E6%A9%98%E6%B1%81',udid:JZ_DEVICE,uuid:JZ_DEVICE,chid:'10000',androidID:JZ_DEVICE,net:'1',young:0,tenantId:'*',v:1,device:0,lang:'zh',country:'CN',cpu:'arm64-v8a'};
}
async function jzBoot() {
  if (JZ_SECONDARY && Date.now() - JZ_SECONDARY_AT < 30 * 60 * 1000) return;
  if (JZ_PENDING) return JZ_PENDING;
  JZ_PENDING = (async function () {
    var ts = Date.now(), random = jzRandom(16);
    var sign = await LumeSource.tools.rsa({pem:jzPem(JZ_PUBLIC),data:btoa(jzBytes(String(ts) + random)),encrypt:true});
    var body = jzField(1, ts) + jzField(2, sign) + jzField(3, random) + jzField(4, random) + jzField(5, random);
    var data = await jzRequest('/api/v5/find/app/zone', body, {'User-Agent':JZ_UA,'Content-Type':'application/x-protobuf','Accept':'application/x-protobuf','publicParams':JSON.stringify(jzPublicParams())});
    var rows = jzPb(data);
    JZ_SECONDARY = jzString(rows, 1) + jzString(rows, 2) + jzString(rows, 4) + jzString(rows, 5);
    if (!JZ_SECONDARY) throw new Error('橘汁未返回会话公钥');
    JZ_SECONDARY_AT = Date.now();
  })();
  try { await JZ_PENDING; } finally { JZ_PENDING = null; }
}
async function jzSecure(path, params) {
  await jzBoot();
  var ts = Date.now(), random = jzRandom(16), common = jzPublicParams();
  var sign = await LumeSource.tools.rsa({pem:jzPem(JZ_SECONDARY),data:btoa(jzBytes(String(ts) + random + '3026')),encrypt:true});
  var ao = await LumeSource.tools.aes({key:btoa(JZ_SAFE),data:btoa(jzBytes(String(ts) + random)),mode:'ECB',encrypt:true});
  Object.assign(common, {country:'CN',vName:'3.0.2.6',cpuId:'',young:0,facturer:'OnePlus',resolution:'1080x2256',mac:'02%3A00%3A00%3A00',sig:sign,abid:'7470',model:'PJX110',dpi:'480',net:'1',lang:'zh',random_str:random,brand:'OnePlus',timestamp:ts,density:'3.0',cpu:'arm64-v8a',carrier:'%E8%81%94%E9%80%9A',sig2:ao.slice(0,8),sig3:ao.slice(8)});
  var ct = await LumeSource.tools.aes({key:btoa(JZ_SECURITY),data:btoa(jzBytes(params + ts)),mode:'ECB',encrypt:true});
  var body = jzField(1, random + ct.slice(0,4)) + jzField(2,ct.slice(4)) + jzField(3,jzRandom(20)) + jzField(4,ts) + jzField(5,random);
  return jzRequest(path, body, {'User-Agent':JZ_UA,'Content-Type':'application/x-protobuf','Accept':'application/x-protobuf','publicParams':JSON.stringify(common)});
}
function jzCover(bytes) {
  var rows = jzPb(bytes || ''), urls = [];
  rows.forEach(function (r) { if (r.wire === 2) { var url = jzText(r.value); if (/^https?:\/\//.test(url)) urls.push(url); } });
  return urls.filter(function (u) { return u.indexOf('https:') === 0; })[0] || urls[0] || '';
}
function jzListItems(data) {
  return jzPb(data).filter(function (r) { return r.field === 1 && r.wire === 2; }).map(function (r) {
    var f = jzPb(r.value);
    return {id:String(jzGet(f,3,'')),title:jzString(f,5),cover:jzCover(jzGet(f,2,'')),subtitle:jzString(f,13),mediaType:'video'};
  }).filter(function (r) { return r.id && r.title; });
}
async function getCategories() {
  var data = await jzRequest('/api/v3/drama/getCategory?orderBy=type_id');
  return (data.data || []).filter(function (r) { return r.id != null && String(r.id) !== '29'; }).map(function (r) { return {id:String(r.id),title:String(r.name || r.id)}; });
}
async function getList(args) {
  args = args || {};
  var page = Math.max(1, Number(args.page) || 1), qs = 'page=' + page + '&pagesize=24';
  var path = '/api/proto/v5/drama/category';
  if (args.keyword) { path = '/api/proto/v5/drama/search'; qs += '&searchKeys=' + String(args.keyword); }
  else if (args.categoryId) qs += '&typeId1=' + encodeURIComponent(args.categoryId);
  var items = jzListItems(await jzSecure(path, qs));
  return {items:items,hasMore:items.length >= 24};
}
async function jzDetail(id) {
  var cached = JZ_DETAILS[id];
  if (cached && Date.now() - cached.at < 5 * 60 * 1000) return cached.value;
  var bytes = await jzSecure('/api/proto/v5/drama/getDetail', 'id=' + encodeURIComponent(id));
  var fields = jzPb(bytes), title = jzString(fields,9);
  if (!title) return null;
  var groups = {}, order = [];
  fields.filter(function (r) { return r.field === 29 && r.wire === 2; }).forEach(function (r) {
    var f = jzPb(r.value), path = jzString(f,4), source = jzString(f,9), line = jzString(f,10) || source || '正片';
    if (!path) return;
    if (!groups[line]) { groups[line] = []; order.push(line); }
    var name = jzString(f,2) || jzString(f,3) || '正片';
    groups[line].push({id:JSON.stringify({source:source,path:path,line:line}),title:name,line:line});
  });
  function rank(line) { return line === 'M蓝光' ? 0 : line.indexOf('NS蓝光') === 0 ? 1 : line === 'JD4K' ? 3 : 2; }
  var original = order.slice();
  order.sort(function (a,b) { return rank(a)-rank(b) || original.indexOf(a)-original.indexOf(b); });
  var chapters = [];
  order.forEach(function (line) { groups[line].forEach(function (c) { chapters.push(c); }); });
  var detail = {id:String(id),title:title,cover:jzCover(jzGet(fields,2,'')),description:jzString(fields,6).replace(/<[^>]+>/g,' '),year:String(jzGet(fields,18,'')),mediaType:'video',chapters:chapters};
  if (Object.keys(JZ_DETAILS).length >= 4) delete JZ_DETAILS[Object.keys(JZ_DETAILS)[0]];
  JZ_DETAILS[id] = {at:Date.now(),value:detail};
  return detail;
}
async function getDetail(args) { return jzDetail(args.id); }
async function getChapters(args) { var value = await jzDetail(args.id); return value ? value.chapters : []; }
async function getContent(args) {
  var chapter = JSON.parse(args.chapterId), url = chapter.path;
  // Some upstream paths are HTTPS watch pages, not media files. They still
  // require videoUsableUrl; handing the HTML page to a decoder cannot work.
  if (!/^https?:\/\/[^\s]+\.(?:m3u8|mp4|mkv|mpd|flv|webm)(?:[?#]|$)/i.test(url)) {
    var data = await jzSecure('/api/proto/v5/videoUsableUrl','vodPlayFrom=' + encodeURIComponent(chapter.source) + '&playUrl=' + encodeURIComponent(chapter.path));
    var rows = jzPb(data);
    url = jzString(rows,1);
    if (!/^https?:\/\//.test(url)) {
      var match = data.match(/https?:\/\/[\x21-\x7e]+/); url = match ? match[0] : '';
    }
  }
  if (!/^https?:\/\/[^\s*<>]+/i.test(url)) throw new Error('橘汁「' + chapter.line + '」未返回有效播放地址，请选择其他线路');
  return {kind:'video',url:url,headers:{'User-Agent':JZ_UA}};
}
var LumeSource = {
  settings:[{key:'note',type:'info',title:'站点说明',description:'原生 JS / protobuf 接口，免注册。需要包含二进制 POST 与分片修复的新版 LumeBox。默认 M蓝光/NS蓝光，其他原站线路保留；部分 JD4K 或蓝光地址可能失效，需要手动换线。线路名不是实际分辨率保证。后端没有独立网页首页或 favicon。'}],
  categories:getCategories,list:getList,detail:getDetail,chapters:getChapters,content:getContent
};
