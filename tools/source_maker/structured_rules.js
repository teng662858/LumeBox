// Read public JSON and literal player configuration. Never evaluate site scripts.
function literalString(token) {
  if(!token||token.length>16384)return '';
  try {if(token[0]==='"')return JSON.parse(token);}catch(_){}
  if(token[0]!=="'"||token[token.length-1]!=="'")return '';
  return token.slice(1,-1).replace(/\\(?:u([a-f\d]{4})|x([a-f\d]{2})|([\\/'"nrt]))/gi,function(_,u,x,c){return u||x?String.fromCharCode(parseInt(u||x,16)):({n:'\n',r:'\r',t:'\t'}[c]||c);});
}
function jsonLiteralAt(source,start) {
  var depth=0,quoted=false,escaped=false;
  for(var i=start;i<source.length&&i-start<2097152;i++) {
    var c=source[i];if(quoted){if(escaped)escaped=false;else if(c==='\\')escaped=true;else if(c==='"')quoted=false;continue;}
    if(c==='"'){quoted=true;continue;}if(c==='{'||c==='[')depth++;if(c==='}'||c===']'){depth--;if(depth===0){try{return JSON.parse(source.slice(start,i+1));}catch(_){return null;}}}
  }return null;
}
function nuxtPayload(table) {
  // Nuxt's inline JSON uses devalue references, not plain nested JSON. Read a
  // bounded data subset; never run custom reducers or application code.
  if(!Array.isArray(table)||!table.length||table.length>12000)return null;
  var cache=Object.create(null),loading=Object.create(null),budget=48000;
  function read(index,depth){
    if(--budget<0||depth>64)throw new Error('Nuxt 数据超过解析范围');
    if(typeof index!=='number'||!Number.isInteger(index))throw new Error('Nuxt 引用无效');
    if(index===-1||index===-2||index===-3||index===-4||index===-5)return null;
    if(index===-6)return 0;
    if(index<0||index>=table.length)throw new Error('Nuxt 引用越界');
    if(Object.prototype.hasOwnProperty.call(cache,index))return cache[index];
    if(loading[index])throw new Error('Nuxt 包装器循环引用');
    var cell=table[index],out;
    if(!cell||typeof cell!=='object'){cache[index]=cell;return cell;}
    loading[index]=true;
    if(Array.isArray(cell)){
      if(typeof cell[0]==='string'){
        var tag=cell[0];
        if(/^(?:Reactive|ShallowReactive|Ref|ShallowRef|NuxtError)$/.test(tag))out=read(cell[1],depth+1);
        else if(tag==='EmptyRef'||tag==='EmptyShallowRef'){
          var empty=typeof cell[1]==='number'?read(cell[1],depth+1):cell[1];
          try{out=empty==='_'?null:empty==='0n'?'0':JSON.parse(empty);}catch(_){out=null;}
        }else if(tag==='Date'||tag==='URL'||tag==='BigInt')out=typeof cell[1]==='string'?cell[1]:null;
        else if(tag==='Set'||tag==='Map'){
          out=[];cache[index]=out;
          for(var j=1;j<cell.length;j++)out.push(read(cell[j],depth+1));
        }else if(tag==='null'){
          if(cell.length%2!==1)throw new Error('Nuxt 对象格式无效');
          out=Object.create(null);cache[index]=out;
          for(var k=1;k<cell.length;k+=2){if(typeof cell[k]!=='string'||cell[k]==='__proto__')throw new Error('Nuxt 对象属性无效');out[cell[k]]=read(cell[k+1],depth+1);}
        }else out=null; // Unknown site-specific reducers are deliberately opaque.
      }else{
        out=[];cache[index]=out;
        for(var i=0;i<cell.length;i++)out.push(read(cell[i],depth+1));
      }
    }else{
      out=Object.create(null);cache[index]=out;
      Object.keys(cell).forEach(function(key){if(key==='__proto__')throw new Error('Nuxt 对象属性无效');out[key]=read(cell[key],depth+1);});
    }
    cache[index]=out;delete loading[index];return out;
  }
  return read(0,0);
}
function publicPayloads(html) {
  var values=[],nodes=selectNodes(parseTree(html),'script'),initial=/\b(?:window\.)?(?:__INITIAL_STATE__|__PRELOADED_STATE__|__NUXT__)\s*=\s*([\[{])/g;
  nodes.forEach(function(n){var raw=nodeRawText(n),type=(n.attrs.type||'').toLowerCase();
    if(type==='application/json'||type==='application/ld+json'){
      try{var parsed=JSON.parse(raw),nuxt=n.attrs.id==='__NUXT_DATA__'||n.attrs['data-nuxt-data']!==undefined;values.push(nuxt?nuxtPayload(parsed):parsed);}catch(_){}return;
    }
    var m;initial.lastIndex=0;while((m=initial.exec(raw))){var v=jsonLiteralAt(raw,initial.lastIndex-1);if(v)values.push(v);}
  });return values;
}
function visitPayloads(values,visitor) {
  var remaining=12000;
  function walk(v,path,depth){if(!v||typeof v!=='object'||depth>14||--remaining<0)return;visitor(v,path);if(Array.isArray(v)){v.slice(0,1000).forEach(function(x,i){walk(x,path.concat(i),depth+1);});}else Object.keys(v).slice(0,100).forEach(function(k){if(k!=='__proto__'&&k!=='constructor')walk(v[k],path.concat(k),depth+1);});}
  values.forEach(function(v,i){walk(v,[i],0);});
}
function payloadImage(v,base){if(Array.isArray(v))return payloadImage(v[0],base);if(v&&typeof v==='object')return abs(v.url||v.src||v.contentUrl||'',base);return typeof v==='string'?abs(v,base):'';}
function structuredItems(html,base) {
  var best=[],bestScore=0;
  visitPayloads(publicPayloads(html),function(v,path){
    if(!Array.isArray(v)||!v.length)return;
    var out=[],seen={};v.slice(0,1000).forEach(function(x){
      if(!x||typeof x!=='object')return;x=x.node||x.item||x.attributes||x;
      var raw=x.url||x.link||x.href||x.detailUrl||x.detail_url||x.canonicalUrl;
      if(typeof raw!=='string'||!(/^(?:https?:\/\/|\/[^/]|\.\.?\/)/i.test(raw)))return;
      var id=abs(raw,base),title=x.title||x.name||x.headline;
      if(title&&typeof title==='object')title=title.rendered;
      if(!id||typeof title!=='string'||!title.trim()||seen[id]||/\/(?:search|categories|category|tags?|login|accounts?|authors?|users?)(?:\/|\?|$)/i.test(id))return;
      if(C.links&&!(new RegExp(C.links,'i')).test(id))return;
      var cover=payloadImage(x.thumbnailUrl||x.thumbnail_url||x.cover||x.coverUrl||x.poster||x.image,base);
      // A named URL alone may be site navigation. Require artwork or a work schema.
      if(!cover&&!/VideoObject|AudioObject|Book|Comic|Movie|TVSeries/.test(String(x['@type']||'')))return;
      seen[id]=true;out.push({id:id,title:text(title),cover:cover,coverHeaders:cover?{Referer:base}:{}});
    });var score=out.length+out.filter(function(x){return x.cover;}).length*3;
    if(score>bestScore){bestScore=score;best=out;}
  });return best;
}
function payloadMedia(html,base) {
  var candidates=[];
  visitPayloads(publicPayloads(html),function(v,path){
    if(Array.isArray(v))return;
    // Recommendations and ads are not the current work's playback source.
    if(path.some(function(k){return /recommend|related|advert|banner/i.test(String(k));}))return;
    ['contentUrl','playUrl','play_url','videoUrl','video_url','audioUrl','audio_url','file','src'].forEach(function(k){
      var u=v[k];if(typeof u!=='string')return;
      if(/\.(?:m3u8|mpd|mp4|webm|mp3|m4a|m4b|aac|flac|ogg|opus|wav)(?:[?#]|$)/i.test(u))candidates.push(abs(u,base));
    });
  });return candidates.filter(Boolean)[0]||'';
}
function playerLiteralMedia(html,base) {
  // KVS exposes this work's public source in a flashvars object. Read literals
  // only; function/ wrappers and license transformations are not direct URLs.
  if(/id\s*=\s*["']kt_player["']/i.test(html)){
    var fv=/\b(?:var|let|const)\s+flashvars\s*=\s*\{([\s\S]*?)\}\s*;/.exec(html);
    if(fv){var kvs=/\b(?:video_url|video_alt_url)\s*:\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')/g,match;
      while((match=kvs.exec(fv[1]))){var publicUrl=literalString(match[1]);if(/^https?:\/\//i.test(publicUrl)&&!/\bfunction\//i.test(publicUrl)&&/\.(?:mp4|m3u8|webm)\/?(?:[?#]|$)/i.test(publicUrl))return abs(publicUrl,base);}
    }
  }
  if(!/<(?:video|audio)\b/i.test(html)&&!/jwplayer\s*\(|videojs\s*\(/i.test(html))return '';
  var nodes=selectNodes(parseTree(html),'script'),found='';
  nodes.forEach(function(n){if(found||n.attrs.src)return;var raw=nodeRawText(n);
    // Inspect only scripts actually using a player, not unrelated ad scripts.
    if(!/\.loadSource\s*\(|\.src\s*=|jwplayer\s*\(|videojs\s*\(/.test(raw))return;
    var literal='(?:"(?:[^"\\\\]|\\\\.)*"|\x27(?:[^\x27\\\\]|\\\\.)*\x27)',expression=literal,vars={},m;
    for(var level=0;level<2;level++)expression='(?:'+literal+'|(?:atob|decodeURIComponent)\\(\\s*'+expression+'\\s*\\))';
    function read(s,depth){if(depth>3)return '';var wrap=/^(atob|decodeURIComponent)\(\s*([\s\S]*)\s*\)$/.exec(s);if(!wrap)return literalString(s);try{var v=read(wrap[2].trim(),depth+1);return wrap[1]==='atob'?atob(v):decodeURIComponent(v);}catch(_){return '';}}
    var declarations=new RegExp('\\b(?:var|let|const)\\s+([\\w$]+)\\s*=\\s*('+expression+')(?=\\s*[,;\\n]|\\s*$)','g');
    while((m=declarations.exec(raw)))vars[m[1]]=read(m[2],0);
    var calls=new RegExp('(?:\\.loadSource\\s*\\(\\s*|\\.src\\s*=\\s*)('+expression+'|[\\w$]+)(?=\\s*[,);]|\\s*$)','g');
    while((m=calls.exec(raw))){var value=vars[m[1]]||read(m[1],0);if(/\.(?:m3u8|mpd|mp4|webm|mp3|m4a|aac|flac|ogg|wav)(?:[?#]|$)/i.test(value)){found=abs(value,base);break;}}
    if(!found&&/jwplayer\s*\(|videojs\s*\(/.test(raw)){
      var files=new RegExp('(?:["\x27]?(?:file|src)["\x27]?)\\s*:\\s*('+expression+')(?=\\s*[,}])','g');
      while((m=files.exec(raw))){var u=read(m[1],0);if(/\.(?:m3u8|mpd|mp4|webm|mp3|m4a|aac|flac|ogg|wav)(?:[?#]|$)/i.test(u)){found=abs(u,base);break;}}
    }
  });return found;
}
function feedItems(html,base) {
  var root=parseTree(html),out=[],seen={},channel=firstNode(root,'channel'),channelArt=firstNode(channel||root,'itunes:image,media:thumbnail,image');
  function artwork(n){if(!n)return '';var u=n.attrs.href||n.attrs.url;return abs(u||(firstNode(n,'url')&&nodeText(firstNode(n,'url')))||'',base);}
  selectNodes(root,'item,entry').forEach(function(n){
    var title=firstNode(n,'title'),enclosures=selectNodes(n,'enclosure,link[rel=enclosure],media:content'),media='';
    for(var i=0;i<enclosures.length;i++){var e=enclosures[i],u=abs(e.attrs.url||e.attrs.href||'',base),type=e.attrs.type||'';
      if(u&&((C.media==='audio'?/^audio\//:/^video\//).test(type)||(C.media==='audio'?/\.(?:mp3|m4a|m4b|aac|ogg|opus|flac|wav)(?:[?#]|$)/i:/\.(?:mp4|webm|m3u8|mpd)(?:[?#]|$)/i).test(u))){media=u;break;}}
    if(!media||!title||seen[media])return;seen[media]=true;
    var cover=artwork(firstNode(n,'itunes:image,media:thumbnail'))||artwork(channelArt),description=firstNode(n,'description,summary');
    out.push({id:media,title:nodeText(title),cover:cover,coverHeaders:cover?{Referer:base}:{},mediaUrl:media,description:description?nodeText(description):''});
  });return out;
}
