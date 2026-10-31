// Standalone LumeBox runtime. No desktop tool or localhost server needed after export.
var C = __CONFIG__;
var knownItems = {};
var pageLinks = {};
function remember(rows) {
  rows.forEach(function(row){knownItems[row.id]=row;});
  var ids=Object.keys(knownItems); while(ids.length>150) delete knownItems[ids.shift()];
  return rows;
}
function setQuery(url, values) {
  var split=url.split('#'), parts=split[0].split('?'), old=(parts[1]||'').split('&').filter(Boolean);
  var keys=Object.keys(values);
  old=old.filter(function(p){try{return keys.indexOf(decodeURIComponent(p.split('=')[0]))<0;}catch(_){return true;}});
  keys.forEach(function(k){old.push(encodeURIComponent(k)+'='+encodeURIComponent(String(values[k])));});
  return parts[0]+(old.length?'?'+old.join('&'):'')+(split.length>1?'#'+split.slice(1).join('#'):'');
}
function decode(s) {
  return String(s || '').replace(/&(?:amp|lt|gt|quot|apos|nbsp|#\d+|#x[\da-f]+);/gi, function(x) {
    var named = {'&amp;':'&','&lt;':'<','&gt;':'>','&quot;':'"','&apos;':"'",'&nbsp;':' '};
    if (named[x.toLowerCase()]) return named[x.toLowerCase()];
    var n = x.slice(2,-1), code = n[0].toLowerCase() === 'x' ? parseInt(n.slice(1),16) : parseInt(n,10);
    return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : '';
  });
}
function text(s) { return decode(String(s || '').replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi,'').replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi,'').replace(/<[^>]+>/g,' ')).replace(/\s+/g,' ').trim(); }
function attr(s,k) {
  var m = new RegExp('(?:^|\\s)' + k + '\\s*=\\s*(?:"([^"]*)"|\x27([^\x27]*)\x27|([^\\s>]+))','i').exec(s);
  return m ? decode(m[1] || m[2] || m[3] || '') : '';
}
function abs(s, base) {
  s = decode(s).trim(); base = base || C.url;
  if (!s || /^(?:javascript|data|mailto|tel|blob|file):/i.test(s) || s[0] === '#') return '';
  try { return new URL(s,base).href; } catch (_) {}
  var root = /^(https?:)\/\/([^/]+)/i.exec(base);
  if (!root) return '';
  if (/^https?:\/\//i.test(s)) return s;
  if (s.slice(0,2) === '//') return root[1] + s;
  if (s[0] === '?') return base.split(/[?#]/)[0] + s;
  var path = base.split(/[?#]/)[0].replace(/^https?:\/\/[^/]+/,'') || '/';
  var full = s[0] === '/' ? s : path.replace(/\/[^/]*$/, '/') + s;
  var parts = []; full.split('/').forEach(function(p){ if(p === '..') parts.pop(); else if(p !== '.') parts.push(p); });
  return root[1] + '//' + root[2] + parts.join('/');
}
function anchors(html, base, pattern) {
  html = html.replace(/<!--[^]*?-->|<(script|style)\b[^>]*>[\s\S]*?<\/\1>/gi,'');
  var re = /<a\b([^>]*)>([\s\S]*?)<\/a>/gi, out = [], seen = {}, m;
  var filter = pattern ? new RegExp(pattern, 'i') : null;
  while ((m = re.exec(html))) {
    var id = abs(attr(m[1],'href'),base), img = /<img\b([^>]*)>/i.exec(m[2]);
    var title = attr(m[1],'title') || text(m[2]) || (img && attr(img[1],'alt'));
    if (!id || !title || seen[id] || (filter && !filter.test(id))) continue;
    seen[id] = true;
    out.push({id:id,title:title,cover:img ? abs(attr(img[1],'data-original') || attr(img[1],'data-src') || attr(img[1],'src'),base) : ''});
  }
  return out;
}
function contentBlock(html, id) {
  var tags = /<(\/?)([a-z][\w-]*)\b([^>]*)>/gi, m, tag, depth=0, start=0;
  while((m=tags.exec(html))) {
    if(!tag) {
      if(!m[1] && (id ? attr(m[3],'id') === id : /^(article|main)$/i.test(m[2]))) {tag=m[2].toLowerCase();depth=1;start=tags.lastIndex;}
    } else if(m[2].toLowerCase() === tag) {
      depth += m[1] ? -1 : /\/\s*$/.test(m[3]) ? 0 : 1;
      if(depth === 0) return html.slice(start,m.index);
    }
  }
  if(id) throw new Error('找不到正文元素 ID：' + id);
  return html;
}
function meta(html, name) {
  var re=/<meta\b([^>]*)>/gi,m;
  while((m=re.exec(html))) if((attr(m[1],'name')||attr(m[1],'property')).toLowerCase()===name) return attr(m[1],'content');
  return '';
}
function htmlFilters(html) {
  var forms=html.match(/<form\b[^>]*>[\s\S]*?<\/form>/gi)||[];
  var form=forms[C.filterFormIndex],groups=[];
  if(!form) return {groups:groups};
  var re=/<select\b([^>]*)>([\s\S]*?)<\/select>/gi,m;
  while((m=re.exec(form))) {
    var key=attr(m[1],'name'); if((C.filterKeys||[]).indexOf(key)<0) continue;
    var options=[],optionRe=/<option\b([^>]*)>([\s\S]*?)<\/option>/gi,o;
    while((o=optionRe.exec(m[2]))) {
      if(/(?:^|\s)disabled(?:\s|=|$)/i.test(o[1]))continue;
      var title=text(o[2]),value=attr(o[1],'value');
      if(title)options.push({id:value,title:title});
    }
    if(options.length)groups.push({id:key,title:(C.filterNames||{})[key]||attr(m[1],'aria-label')||key,options:options});
  }
  return {groups:groups};
}
function verificationPage(html) {
  if(/cf-chl-|验证您是真人/i.test(html))return true;
  var m=/<title\b[^>]*>([\s\S]*?)<\/title>/i.exec(html),t=m?text(m[1]):'';
  return /^(?:Just a moment(?:\.\.\.)?|Attention Required(?:!|\s.*)?|安全验证|人机验证|访问验证|Security Verification|Verification Required|Verify (?:you are|you.re) human)$/i.test(t);
}
async function get(url, selector, purpose, referer) {
  if(C.useBrowser) {
    if(!LumeSource.web || !LumeSource.web.render)throw new Error('当前 App 不支持浏览器源运行环境');
    var options={url:url,includeHtml:true,timeoutMs:6000,purpose:purpose||'',script:'return await ('+browserDocument.toString()+')('+JSON.stringify(C.browserActions||{})+','+JSON.stringify(selector||'')+','+JSON.stringify(purpose||'')+');'};
    if(selector && !C.browserActions)options.waitForSelector=selector;
    var page=await LumeSource.web.render(options);
    if(!page || !page.html)throw new Error('浏览器没有返回页面；请在 App 网页视图中完成验证');
    var html=typeof page.result==='string'?page.result:page.html;
    if(verificationPage(html))throw new Error('NEED_WEBVIEW_VERIFY：站点需要人工验证，请在网页视图完成后重试');
    return html;
  }
  var r = await LumeSource.http.get(url, {headers:{Referer:referer||C.url}});
  if (r.status === 403 || r.status === 503) throw new Error('NEED_WEBVIEW_VERIFY：请在网页视图完成验证');
  if (r.status < 200 || r.status >= 300) throw new Error('抓取失败 HTTP ' + r.status + ' ' + url);
  if(verificationPage(r.body))throw new Error('NEED_WEBVIEW_VERIFY：站点需要人工验证，请在网页视图完成后重试');
  return r.body;
}
function template(s, page, keyword) { return s.replace(/\{page\}/g,String(page)).replace(/\{keyword\}/g,encodeURIComponent(keyword || '')); }
function item(v) { return {id:String(v.vod_id),title:v.vod_name,cover:abs(v.vod_pic),subtitle:v.vod_remarks || '',description:text(v.vod_content)}; }
async function api(params) { return JSON.parse(await get(C.api + (C.api.indexOf('?') >= 0 ? '&' : '?') + params)); }
async function apiDetail(id) { var d = await api('ac=detail&ids=' + encodeURIComponent(id)); if (!d.list || !d.list.length) throw new Error('接口没有返回详情'); return d.list[0]; }
function media(html, base) {
  html = html.replace(C.media === 'audio' ? /<video\b[^>]*>[\s\S]*?<\/video>/gi : /<audio\b[^>]*>[\s\S]*?<\/audio>/gi, '');
  var tag = /<(?:audio|video|source)\b([^>]*)>/gi, m;
  while ((m = tag.exec(html))) { var src = abs(attr(m[1],'src')||attr(m[1],'data-src'),base); if(src) return src; }
  var p = /\bplayer_[\w]+\s*=\s*(\{[^\n]*?\})\s*(?:;|<)/i.exec(html);
  if(p) { try { var v = JSON.parse(p[1]), u = v.url; if(String(v.encrypt) === '1') u = decodeURIComponent(u); if(String(v.encrypt) === '2') u = decodeURIComponent(atob(u)); if(/\.(?:m3u8|mp4|webm|mp3|m4a|m4b|aac|flac|ogg|opus|wav)(?:[?#]|$)/i.test(u)) return abs(u,base); } catch (_) {} }
  var structured=structuredMedia(html,base);if(structured)return structured;
  var embedded=payloadMedia(html,base)||playerLiteralMedia(html,base);if(embedded)return embedded;
  var named=meta(html,C.media==='audio'?'og:audio':'og:video')||meta(html,C.media==='audio'?'og:audio:url':'og:video:url');
  return /\.(?:m3u8|mp4|webm|mp3|m4a|m4b|aac|flac|ogg|opus|wav)(?:[?#]|$)/i.test(named)?abs(named,base):'';
}
async function resolveMedia(html,base,depth,seen) {
  var url=media(html,base);if(url)return {url:url,referer:base};
  if(depth>=2)return null;seen=seen||{};seen[base]=true;
  var frames=selectNodes(parseTree(html),'#player iframe,.player iframe,iframe#video,iframe[src*="/embed/"],iframe[src*="/player/"],iframe[src*="/play/"]');
  for(var i=0;i<frames.length&&i<2;i++) {
    var n=frames[i],at=abs(n.attrs.src||n.attrs['data-src']||'',base);
    if(!at||seen[at]||/advert|doubleclick|popunder|\/ads?\//i.test(at)||n.attrs.width==='0'||n.attrs.height==='0')continue;
    seen[at]=true;var child=await get(at,'','media',base),resolved=await resolveMedia(child,at,depth+1,seen);if(resolved)return resolved;
  }return null;
}
var LumeSource = {
  id:C.id, name:C.name, version:C.version||'1.0.0', category:C.category,
  async categories() {
    if(C.mode==='feed')return [{id:C.url,title:'全部'}];
    if(C.mode !== 'maccms') {
      var rows=C.categoryLinks ? anchors(await get(C.url,C.listSelector),C.url,C.categoryLinks) : [];
      return [{id:C.url,title:'全部'}].concat(rows.filter(function(r){return r.id!==C.url;}).map(function(r){return {id:r.id,title:r.title};}));
    }
    var d = await api('ac=list'); return (d.class || []).map(function(v){return {id:String(v.type_id),title:v.type_name};});
  },
  async filters() {
    if(C.mode==='feed')return {groups:[]};
    if(C.mode==='maccms' || !C.filterKeys || !C.filterKeys.length) return {groups:[]};
    return htmlFilters(await get(C.url,C.listSelector));
  },
  async home() { return (await this.list({page:1})).items; },
  async list(a) {
    a = a || {}; var page = Math.max(1,Number(a.page) || 1);
    var filters=a.filters||{};
    if(C.mode==='feed') {
      if(a.keyword||Object.keys(filters).length||(a.categoryId&&a.categoryId!==C.url))throw new Error('该媒体订阅未提供分类、筛选或搜索接口');
      var previous=pageLinks._feed||{},at=page===1?C.list:previous[page];if(!at)return {items:[],hasMore:false};
      var feed=await get(at),rows=feedItems(feed,at),link=firstNode(parseTree(feed),'link[rel=next]'),next=link&&abs(link.attrs.href,at);
      if(next){previous[page+1]=next;pageLinks._feed=previous;}return {items:remember(rows),hasMore:!!next};
    }
    if(C.mode === 'maccms') { if(Object.keys(filters).length)throw new Error('该接口未提供筛选规则，不能忽略筛选条件');var d = await api('ac=detail&pg='+page+'&t='+encodeURIComponent(a.categoryId || '')+'&wd='+encodeURIComponent(a.keyword || '')); return {items:remember((d.list || []).map(item)),hasMore:page < Number(d.pagecount)}; }
    if(a.keyword && !C.search) throw new Error('本站尚未配置搜索地址，请在制源工具填写带 {keyword} 的地址');
    var address = a.keyword ? C.search : C.list;
    if(!a.keyword && a.categoryId && a.categoryId!==C.url) {
      if(!C.categoryLinks || !new RegExp(C.categoryLinks,'i').test(a.categoryId))throw new Error('未识别的分类地址');
      address=abs(a.categoryId);
    }
    var pagingKey=JSON.stringify([address,a.keyword||'',filters]);
    if(!pageLinks[pagingKey]){if(Object.keys(pageLinks).length>=12)pageLinks={};pageLinks[pagingKey]={};}
    var savedPage=pageLinks[pagingKey][page];
    if(page > 1 && address.indexOf('{page}') < 0 && !savedPage)return {items:[],hasMore:false};
    var url = template(address,page,a.keyword),selected={};
    Object.keys(filters).forEach(function(key){
      if((C.filterKeys||[]).indexOf(key)<0)throw new Error('未适配的筛选项：'+key);
      selected[key]=filters[key];
    });
    if(Object.keys(selected).length) {
      if(!a.keyword && (!a.categoryId || a.categoryId===C.url))url=template(C.filterAction||url,page,'');
      url=setQuery(url,selected);
    }
    if(savedPage)url=savedPage;
    var html = await get(url,C.listSelector,'list'), rows = C.mode==='inline-media'?inlineMediaItems(html,url):ruleItems(html,url);
    if(!rows.length) {
      if(/no results|nothing found|没有找到|沒有找到|暂无数据|暫無資料|无搜索结果|無搜尋結果/i.test(text(html)))return {items:[],hasMore:false};
      throw new Error('没有识别到条目；网站可能动态加载或规则已失效');
    }
    var next=nextAddress(html,url);
    if(next&&page<100)pageLinks[pagingKey][page+1]=next;
    return {items:remember(rows),hasMore:!!next};
  },
  async detail(a) {
    if(C.mode==='inline-media'){if(!knownItems[a.id])await this.list({page:1});return knownItems[a.id]||{id:a.id,title:C.name,cover:'',mediaUrl:a.id};}
    if(C.mode==='feed'){if(!knownItems[a.id])await this.list({page:1});if(!knownItems[a.id])throw new Error('该条目已不在当前订阅中');return knownItems[a.id];}
    if(C.mode === 'maccms') return item(await apiDetail(a.id));
    var h = await get(a.id), heading = /<h1\b[^>]*>([\s\S]*?)<\/h1>/i.exec(h), title = /<title\b[^>]*>([\s\S]*?)<\/title>/i.exec(h);
    var found=knownItems[a.id];
    return {id:a.id,title:text(heading ? heading[1] : '')||text(title ? title[1] : '')||(found&&found.title)||a.id,cover:abs(meta(h,'og:image'),a.id)||(found?found.cover:''),description:meta(h,'description')||meta(h,'og:description')};
  },
  async chapters(a) {
    if(C.mode==='inline-media')return [{id:a.id,title:'播放'}];
    if(C.mode==='feed'){await this.detail(a);return [{id:a.id,title:'播放'}];}
    if(C.target === 'images') return [{id:a.id,title:'查看图集'}];
    if(C.mode === 'maccms') {
      var v = await apiDetail(a.id), names = String(v.vod_play_from || '').split('$$$'), out = [];
      String(v.vod_play_url || '').split('$$$').forEach(function(line,i){line.split('#').forEach(function(ep){var k=ep.indexOf('$'); if(k >= 0 && ep.slice(k+1)) out.push({id:ep.slice(k+1),title:(names[i] || '线路')+' · '+ep.slice(0,k)});});});
      return out;
    }
    var h = await get(a.id,C.chapterSelector,C.media==='images'?'chapters':'media');
    if(C.media!=='images'&&!C.chapterSelector&&media(h,a.id))return [{id:a.id,title:'播放'}];
    var rows = ruleChapters(h,a.id);
    if(rows.length)return rows.map(function(v){return {id:v.id,title:v.title};});
    if(C.media==='images')return [{id:a.id,title:'查看图片'}];
    if(await resolveMedia(h,a.id,0))return [{id:a.id,title:'播放'}];
    throw new Error('未识别到选集或媒体；当前可能是导航、人物或分类页，不能作为作品导出');
  },
  async content(a) {
    if(C.mode==='inline-media'){var row=knownItems[a.id]||{mediaUrl:a.chapterId||a.id,mediaHeaders:{Referer:C.url}};return {kind:C.media==='audio'?'audio':'video',url:row.mediaUrl,headers:row.mediaHeaders};}
    if(C.mode==='feed'){var entry=await this.detail({id:a.id||a.chapterId});return {kind:C.media==='audio'?'audio':'video',url:entry.mediaUrl,headers:{Referer:C.url}};}
    var url = abs(a.chapterId || a.id);
    if(C.media !== 'images' && /\.(?:m3u8|mp4|webm|mp3|m4a|m4b|aac|flac|ogg|opus|wav)(?:[?#]|$)/i.test(url)) return {kind:C.media === 'audio' ? 'audio' : 'video',url:url,headers:{Referer:C.url}};
    var h = await get(url,C.media==='images'?C.imageSelector:'',C.media==='images'?'images':'media');
    if(C.media !== 'images') { var v = await resolveMedia(h,url,0); if(!v) throw new Error('未找到公开音视频直链；此播放器需要站点专用适配'); return {kind:C.media === 'audio' ? 'audio' : 'video',url:v.url,headers:{Referer:v.referer}}; }
    // Limit extraction to a content block where one is recognizable.
    var body = contentBlock(h,C.contentId);
    var images=ruleImages(C.contentId?body:h,url,!!C.contentId);
    if(!images.length) throw new Error('未识别到漫画或图片，请配置内容元素 ID');
    var imageHeaders={}; images.forEach(function(src){imageHeaders[src]={Referer:url};});
    return {kind:'images',images:images,imageHeaders:imageHeaders};
  }
};
