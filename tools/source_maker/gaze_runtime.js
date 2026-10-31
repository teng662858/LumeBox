// 公开目录与默认线路选集。页面播放器持有 blob/临时签名；不导出 Cookie。
var C=__CONFIG__, gazeCache=Object.create(null);
function gazeText(s){return String(s||'').replace(/<[^>]*>/g,' ').replace(/&amp;/g,'&').replace(/&quot;/g,'"').replace(/&#39;|&#x27;/gi,"'").replace(/&nbsp;/g,' ').replace(/\s+/g,' ').trim();}
function gazeAttr(s,k){var m=new RegExp('(?:^|\\s)'+k+'\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\'|([^\\s>]+))','i').exec(s);return m?gazeText(m[1]===undefined?m[2]===undefined?m[3]:m[2]:m[1]):'';}
function gazeWork(id){var m=/^(?:https:\/\/gaze\.red)?\/?play\/([a-f0-9]{32})\/?$/i.exec(String(id||''));if(!m)throw new Error('注视影视作品地址无效');return 'https://gaze.red/play/'+m[1].toLowerCase();}
function gazeImage(s){s=String(s||'');return /^https?:\/\//i.test(s)?s:s[0]==='/'?'https://gaze.red'+s:'';}
function gazeCards(html){var rows=[],seen={},re=/<article\b[^>]*>([\s\S]*?)<\/article>/gi,m;
 while((m=re.exec(html))){var a=/<a\b[^>]*href\s*=\s*["'](?:https:\/\/gaze\.red)?\/?play\/([a-f0-9]{32})\/?["'][^>]*>/i.exec(m[1]),img=/<img\b[^>]*>/gi,im,cover='',title='';if(!a)continue;
 while((im=img.exec(m[1]))){var candidate=gazeImage(gazeAttr(im[0],'data-src')||gazeAttr(im[0],'src'));if(candidate&&!/placeholder|\/static\/img\/svg\//i.test(candidate)){cover=candidate;title=gazeAttr(im[0],'alt');break;}}
 var h=/<h[2-5]\b[^>]*>([\s\S]*?)<\/h[2-5]>/i.exec(m[1]);title=h?gazeText(h[1]):title;var id='https://gaze.red/play/'+a[1].toLowerCase();
 if(title&&cover&&!seen[id]){seen[id]=1;rows.push({id:id,title:title,cover:cover,coverHeaders:{Referer:'https://gaze.red/'}});}}
 return rows;}
function gazeMeta(html,name){var tags=html.match(/<meta\b[^>]*>/gi)||[];for(var i=0;i<tags.length;i++)if(gazeAttr(tags[i],'property')===name||gazeAttr(tags[i],'name')===name)return gazeAttr(tags[i],'content');return '';}
function gazeEpisodes(html,page){var start=/\bid=["']play-source-panel-g1["']/.exec(html);if(!start)return [];html=html.slice(start.index+start[0].length);var end=/\bid=["']play-source-panel-g\d+["']/.exec(html);if(end)html=html.slice(0,end.index);var re=/<button\b([^>]*)>([\s\S]*?)<\/button>/gi,m,out=[],seen={};while((m=re.exec(html))){var eid=gazeAttr(m[1],'data-id'),cls=gazeAttr(m[1],'class'),title=gazeText(m[2]);if(!/(^|\s)playbtn(?:\s|$)/.test(cls)||!/^\d+$/.test(eid)||!title||seen[eid])continue;seen[eid]=1;out.push({id:page+'#episode='+eid,title:title});}return out;}
async function gazeRender(url,selector,script){if(!LumeSource.web||typeof LumeSource.web.render!=='function')throw new Error('注视影视需要支持浏览器渲染的新版 LumeBox');var r=await LumeSource.web.render({url:url,headers:{Referer:'https://gaze.red/'},timeoutMs:8000,elementTimeoutMs:6500,waitForSelector:selector,script:script||'',includeHtml:true});var final=String(r.url||url);if(!/^https:\/\/gaze\.red(?:\/|$)/.test(final))throw new Error('注视影视跳转到了其他网站，请检查网址');return r;}
async function gazeDetail(id){var page=gazeWork(id),cached=gazeCache[page];if(cached&&Date.now()-cached.time<120000)return cached.row;
 var response=await gazeRender(page,'#play-source-panel-g1 .playbtn'),html=response.html||'',episodes=gazeEpisodes(html,page),h=/<h5\b[^>]*itemprop=["']name["'][^>]*>([\s\S]*?)<\/h5>/i.exec(html);
 if(!episodes.length)throw new Error('未读取到默认线路选集；请在网页视图完成验证后重试');
 var row={id:page,title:h?gazeText(h[1]):gazeMeta(html,'og:title').split(' - ')[0],cover:gazeImage(gazeMeta(html,'og:image')),coverHeaders:{Referer:'https://gaze.red/'},description:gazeMeta(html,'description'),chapters:episodes};
 if(Object.keys(gazeCache).length>=20)gazeCache=Object.create(null);gazeCache[page]={time:Date.now(),row:row};return row;}
var LumeSource={
 home:async function(){var r=await LumeSource.http.get('https://gaze.red/',{headers:{Referer:'https://gaze.red/'}}),items=gazeCards(r.body||'');if(!items.length)items=gazeCards((await gazeRender('https://gaze.red/','article')).html||'');if(!items.length)throw new Error('注视影视首页未读到作品');return [{title:'注视影视',items:items}];},
 categories:async function(){return [{id:'all',title:'全部影视'},{id:'1',title:'电影'},{id:'2',title:'剧集'},{id:'bangumi',title:'动漫'},{id:'chinese_cartoon',title:'国漫'}];},
 filters:async function(){return {groups:[{id:'sort',title:'排序',options:[{id:'default',title:'默认'},{id:'grade',title:'评分'},{id:'createtime',title:'入库时间'},{id:'updatetime',title:'更新时间'}]}]};},
 list:async function(a){a=a||{};var category=a.categoryId||'all',page=Math.floor(Number(a.page)||1),sort=(a.filters||{}).sort||'default';if(['all','1','2','bangumi','chinese_cartoon'].indexOf(category)<0||['default','grade','createtime','updatetime'].indexOf(sort)<0||page<1||page>10000)throw new Error('注视影视分类、排序或页码无效');
  var url='https://gaze.red/filter?mform='+encodeURIComponent(category)+'&sort='+sort+'&search='+encodeURIComponent(a.keyword||'');
  // Site pagination is a button action, not a guessed ?page= route.
  var script='var target='+page+'; var until=Date.now()+6000; while(true){ var nav=document.querySelector("#pagination2"), active=nav&&nav.querySelector("[aria-current=page]"), current=active?Number(active.dataset.page):1; var busy=document.querySelector("[aria-busy=true]"); if(current===target&&!busy)break; if(Date.now()>until)throw new Error("注视影视翻页等待超时"); if(!busy&&current!==target){var buttons=nav?Array.from(nav.querySelectorAll("button[data-page]")):[], choices=buttons.filter(function(b){var p=Number(b.dataset.page);return !b.disabled&&p>current&&p<=target;}).sort(function(a,b){return Number(b.dataset.page)-Number(a.dataset.page);});if(!choices.length)throw new Error("注视影视没有请求的页码");choices[0].click();} await new Promise(function(r){setTimeout(r,100);}); } return true;';
  var r=await gazeRender(url,'#pagination2',script),html=r.html||'',items=gazeCards(html),pages=0,re=/\bdata-page=["'](\d+)["']/g,m;while((m=re.exec(html)))pages=Math.max(pages,Number(m[1]));return {items:items,hasMore:page<pages};},
 detail:async function(a){return gazeDetail(a.id);},
 chapters:async function(a){return (await gazeDetail(a.id)).chapters;},
 content:async function(a){var page=gazeWork(a.id),m=/^(https:\/\/gaze\.red\/play\/[a-f0-9]{32})#episode=(\d+)$/.exec(String(a.chapterId||''));if(!m||m[1]!==page)throw new Error('注视影视选集不属于当前作品');if(!LumeSource.web||LumeSource.web.episodeSelection!==true)throw new Error('请升级 LumeBox：当前 App 不支持网页按钮选集，不能保证播放指定集数');return {kind:'webplayer',pageUrl:page,headers:{Referer:'https://gaze.red/'},webPlayerOptions:{episodeSelector:'#play-source-panel-g1 button.playbtn[data-id="'+m[2]+'"]'}};}
};
