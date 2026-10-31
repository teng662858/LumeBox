// Bounded HTML tree + a small, portable CSS subset for generated source files.
// Supports tag, .class, #id, attributes, descendant, child and comma selectors.
function parseTree(html) {
  var root={tag:'#document',attrs:{},children:[],parent:null},stack=[root],count=0;
  var re=/<!\[CDATA\[[\s\S]*?\]\]>|<!--[\s\S]*?-->|<![^>]*>|<\/?[a-z][^>]*>|[^<]+|</gi,m;
  var voids=/^(area|base|br|col|embed|hr|img|input|link|meta|param|source|track|wbr)$/;
  while((m=re.exec(html))) {
    var token=m[0],top=stack[stack.length-1];
    if(token.slice(0,9)==='<![CDATA['){top.children.push(token.slice(9,-3));continue;}
    if(token.slice(0,2)==='<!')continue;
    if(token[0]!=='<'){top.children.push(token);continue;}
    var tag=/^<(\/?)([\w:-]+)/.exec(token);if(!tag)continue;
    var name=tag[2].toLowerCase();
    if(tag[1]) {for(var i=stack.length-1;i>0;i--)if(stack[i].tag===name){stack.length=i;break;}continue;}
    if(++count>30000)throw new Error('网页元素过多，请使用具体列表或章节页');
    if(top.tag===name && /^(li|p|option|td|th)$/.test(name)){stack.pop();top=stack[stack.length-1];}
    var attrs={},a,ar=/([^\s=<>\/]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/g;
    ar.lastIndex=tag[0].length;
    while((a=ar.exec(token)))attrs[a[1].toLowerCase()]=decode(a[2]!==undefined?a[2]:a[3]!==undefined?a[3]:a[4]||'');
    if(attrs['class'])attrs['class']=attrs['class'].replace(/\s+/g,' ');
    var node={tag:name,attrs:attrs,children:[],parent:top};top.children.push(node);
    if(/^(script|style|textarea)$/.test(name)) {
      var end=new RegExp('</'+name+'\\s*>','ig');end.lastIndex=re.lastIndex;var close=end.exec(html);
      node.children.push(html.slice(re.lastIndex,close?close.index:html.length));re.lastIndex=close?end.lastIndex:html.length;continue;
    }
    if(!voids.test(name) && !/\/\s*>$/.test(token))stack.push(node);
  }
  return root;
}
function nodeText(node) {
  if(typeof node==='string')return decode(node);
  if(/^(script|style)$/.test(node.tag))return '';
  return node.children.map(nodeText).join(' ').replace(/\s+/g,' ').trim();
}
function nodeRawText(node) {return node.children.filter(function(v){return typeof v==='string';}).join('');}
function simpleMatches(node, spec) {
  if(!node||!node.attrs)return false;
  // XML feeds use namespace prefixes. CSS pseudo-classes remain unsupported.
  var namespace=/^([\w-]+:[\w-]+)(?=$|[.#\[])/.exec(spec);
  if(namespace){if(node.tag!==namespace[1].toLowerCase())return false;spec=spec.slice(namespace[1].length);}
  var ok=true;
  spec=spec.replace(/\[([\w:-]+)(?:([~*^$|]?=)["']?([^\]"']*)["']?)?\]/g,function(_,key,op,value){
    var actual=node.attrs[key.toLowerCase()];
    if(actual===undefined)ok=false;
    else if(op==='=' && actual!==value)ok=false;
    else if(op==='*=' && actual.indexOf(value)<0)ok=false;
    else if(op==='^=' && actual.indexOf(value)!==0)ok=false;
    else if(op==='$=' && actual.slice(-value.length)!==value)ok=false;
    else if(op==='~=' && actual.split(/\s+/).indexOf(value)<0)ok=false;
    return '';
  });
  var tag=/^[\w*-]+/.exec(spec);if(tag&&tag[0]!=='*'&&node.tag!==tag[0].toLowerCase())ok=false;
  var re=/([.#])([\w-]+)/g,m;
  while((m=re.exec(spec)))if(m[1]==='#'?node.attrs.id!==m[2]:(' '+(node.attrs['class']||'')+' ').indexOf(' '+m[2]+' ')<0)ok=false;
  if(/[:\[\]]/.test(spec))throw new Error('CSS 仅支持标签、class、ID、属性、后代和子元素选择器');
  return ok;
}
function selectNodes(root, selector) {
  if(!selector)return [];
  var groups=selector.split(',').map(function(s){return s.trim().replace(/\s*>\s*/g,' > ').split(/\s+/);}),out=[];
  function chain(node,tokens,index) {
    if(!simpleMatches(node,tokens[index]))return false;
    if(index===0)return true;
    if(tokens[index-1]==='>')return chain(node.parent,tokens,index-2);
    for(var p=node.parent;p;p=p.parent)if(chain(p,tokens,index-1))return true;
    return false;
  }
  function visit(node) {
    if(typeof node==='string')return;
    if(node!==root&&groups.some(function(g){return chain(node,g,g.length-1);}))out.push(node);
    node.children.forEach(visit);
  }
  visit(root);return out;
}
function firstNode(root, selector) {return selectNodes(root,selector)[0]||null;}
// Media feeds often expose HTML5 players directly and have no detail link.
// Prefer their real media cards over unrelated navigation/category thumbnails.
function inlineMediaItems(html,base) {
  var root=parseTree(html),tag=C.media==='audio'?'audio':'video',seen={},out=[];
  selectNodes(root,tag).forEach(function(node){
    var nested=firstNode(node,'source'),attrs=node.attrs;
    var src=abs(attrs['data-src']||attrs.src||(nested&&(nested.attrs['data-src']||nested.attrs.src))||'',base);
    if(!/^https?:\/\//i.test(src)||!(/\.(?:mp4|webm|m3u8|mp3|m4a|ogg|aac)(?:[?#]|$)/i.test(src))||seen[src])return;
    var cover=abs(attrs.poster||attrs['data-poster']||'',base),label=attrs.title||attrs['aria-label']||attrs['data-title']||attrs['data-caption']||attrs['data-cast-description']||'';
    if(!label&&node.parent){var title=firstNode(node.parent,'h2,h3,h4,.title');if(title)label=nodeText(title);}
    seen[src]=true;out.push({id:src,title:decode(label).trim()||'视频 '+(out.length+1),cover:cover,mediaUrl:src,coverHeaders:{Referer:base},mediaHeaders:{Referer:base}});
  });return out;
}
function imageUrl(node, base) {
  if(!node)return '';
  for(var keys=['data-original','data-lazy-src','data-src','data-url','data-background','poster','src'];keys.length;) {
    var value=abs(node.attrs[keys.shift()]||'',base);if(value)return value;
  }
  var set=node.attrs['data-srcset']||node.attrs.srcset||'';
  if(set)return abs(set.split(',').pop().trim().split(/\s+/)[0],base);
  var bg=/url\(\s*(['"]?)(.*?)\1\s*\)/i.exec(node.attrs.style||'');
  return bg?abs(bg[2],base):'';
}
function ruleItems(html, base) {
  if(C.structuredList)return structuredItems(html,base);
  if(!C.listSelector)return anchors(html,base,C.links).filter(function(r){return !navigationAddress(r.id);});
  var root=parseTree(html),seen={},out=[];
  selectNodes(root,C.listSelector).forEach(function(card){
    var link=card.tag==='a'&&card.attrs.href?card:null;
    if(!link){for(var parent=card.parent;parent;parent=parent.parent){if(parent.tag==='a'&&parent.attrs.href){link=parent;break;}}}
    if(!link)link=firstNode(card,C.linkSelector||'a[href]');
    if(!link)return;
    var id=abs(link.attrs.href,base);if(!id||seen[id]||navigationAddress(id)||(C.links&&!(new RegExp(C.links,'i')).test(id)))return;
    var image=firstNode(card,C.coverSelector||'img,source'),heading=firstNode(card,C.titleSelector||'h2,h3,h4,.title');
    var title=(heading&&nodeText(heading))||link.attrs.title||(image&&image.attrs.alt)||nodeText(link);
    if(!title)return;
    var cover=imageUrl(image,base);
    seen[id]=true;out.push({id:id,title:title,cover:cover,coverHeaders:cover?{Referer:base}:{}});
  });
  return out;
}
function navigationAddress(id) {
  var path=id.replace(/^https?:\/\/[^/]+/i,'').split(/[?#]/)[0]||'/';
  if(path==='/'&&!/[?&](?:p|id|video_id|vod_id|book_id|m)=[^&#]+/.test(id))return true;
  return /^\/(?:videos|movies|latest|recent|new|home)\/?$/i.test(path)||/\/(?:c|a-z|alphabet|privacy|terms|dmca|2257|contact|about|help|faq|vip-info|points|featured|recommended|accounts?|login|signup|register|search|tags?|categories|category|types?|genres?|authors?|actors?|models?|pornstars?|performers?|users?|cdn-cgi)(?:\/|$)/i.test(path);
}
function ruleChapters(html,base) {
  if(!C.chapterSelector)return anchors(html,base,C.chapters);
  var seen={},out=[];
  selectNodes(parseTree(html),C.chapterSelector).forEach(function(n){
    var link=n.tag==='a'?n:firstNode(n,'a[href]'),id=link&&abs(link.attrs.href,base),title=link&&(link.attrs.title||nodeText(link));
    if(id&&title&&!seen[id]){seen[id]=true;out.push({id:id,title:title});}
  });return out;
}
function ruleImages(html,base,scoped) {
  var root=parseTree(html),nodes=selectNodes(root,scoped?'img':C.imageSelector||'article img,main img'),seen={},out=[];
  if(!nodes.length&&!C.imageSelector)nodes=selectNodes(root,'img');
  nodes.forEach(function(n){var src=imageUrl(n,base);if(src&&!seen[src]){seen[src]=true;out.push(src);}});
  return out;
}
function nextAddress(html,base) {
  var nodes=selectNodes(parseTree(html),C.nextSelector||'a[rel=next],a.next,.next a,.pagination a');
  for(var i=0;i<nodes.length;i++) {
    var n=nodes[i],s=nodeText(n),url=abs(n.attrs.href,base);
    if(url&&url!==base&&(/next/i.test(n.attrs.rel||'')||/下一[页頁]|下[页頁]|next|^[›»]$/i.test(s)||/(^|\s)next(\s|$)/.test(n.attrs['class']||'')))return url;
  }
  var links=anchors(html,base,'');
  for(var j=0;j<links.length;j++)if(/^(下一[页頁]|下[页頁]|next|[›»])$/i.test(links[j].title)&&links[j].id!==base)return links[j].id;
  return '';
}
function structuredMedia(html,base) {
  var scripts=selectNodes(parseTree(html),'script[type="application/ld+json"]'),found='';
  function walk(value) {
    if(!value||found)return;
    if(Array.isArray(value)){value.forEach(walk);return;}
    if(typeof value!=='object')return;
    var type=value['@type'],wanted=C.media==='audio'?'AudioObject':'VideoObject';
    if((type===wanted||(Array.isArray(type)&&type.indexOf(wanted)>=0))&&typeof value.contentUrl==='string')found=abs(value.contentUrl,base);
    if(!found&&value['@graph'])walk(value['@graph']);
  }
  scripts.forEach(function(n){try{walk(JSON.parse(nodeRawText(n)));}catch(_){}});
  return found;
}
