"""Run generated JavaScript in embedded QuickJS with LumeBox's HTTP contract."""
import base64
import json
import time

import quickjs

from core import Fetcher


def execute(script, expression, fetcher=None):
    fetcher = fetcher or Fetcher()
    context = quickjs.Context()
    context.set_memory_limit(48 * 1024 * 1024)
    context.set_max_stack_size(1024 * 1024)
    started = time.monotonic()

    def fetch(url, selector='', purpose=''):
        if time.monotonic() - started > 65:
            raise ValueError('测试超过 65 秒，请稍后重试')
        try:
            if getattr(fetcher, 'browser_mode', False):
                final, body = fetcher.get(url, selector=selector, purpose=purpose)
            else:
                final, body = fetcher.get(url, selector=selector) if hasattr(fetcher, 'accept') or getattr(fetcher, 'supports_selector', False) else fetcher.get(url)
            return json.dumps({'status': 200, 'url': final, 'body': body})
        except Exception as e:
            # Preserve actionable errors across the Python/JS boundary.
            return json.dumps({'error': str(e)})

    context.add_callable('__fetch', fetch)
    def request(raw):
        try:
            if time.monotonic() - started > 65:
                raise ValueError('接口检查超时')
            return json.dumps(fetcher.request(json.loads(raw)))
        except Exception as error:
            return json.dumps({'error': str(error)})
    def aes(raw):
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        from cryptography.hazmat.primitives.padding import PKCS7
        p = json.loads(raw)
        cipher = Cipher(algorithms.AES(base64.b64decode(p['key'])), modes.CBC(base64.b64decode(p['iv'])))
        operation = cipher.decryptor()
        value = operation.update(base64.b64decode(p['data'])) + operation.finalize()
        if p.get('padding') != 'none':
            unpad = PKCS7(128).unpadder()
            value = unpad.update(value) + unpad.finalize()
        return base64.b64encode(value).decode()
    context.add_callable('__aes', aes)
    context.add_callable('__b64encode', lambda x: base64.b64encode(x.encode()).decode())
    context.add_callable('__b64decode', lambda x: base64.b64decode(x).decode())
    context.add_callable('__request', request)
    context.add_callable('atob', lambda value: base64.b64decode(value).decode('latin1'))
    context.eval('''
      var __host = {get:async function(url, selector, purpose) {
        var r=JSON.parse(__fetch(url,typeof selector==='string'?selector:'',purpose||'')); if(r.error) throw new Error(r.error); return r;
      },request:async function(options){var r=JSON.parse(__request(JSON.stringify(options)));if(r.error)throw new Error(r.error);return r;},
      post:async function(url,body,options){return __host.request(Object.assign({},options||{},{url:url,body:body,method:'POST'}));}};
    ''')
    context.eval(script)
    context.eval('LumeSource.tools={aes:async function(p){return __aes(JSON.stringify(p));},base64Encode:async function(v){return __b64encode(v);},base64Decode:async function(v){return __b64decode(v);}}; LumeSource.http = __host; var __files=Object.create(null); LumeSource.fs={readText:async function(p){return __files[p]||"";},writeText:async function(p,v){__files[p]=v;}}; LumeSource.web={episodeSelection:true,render:async function(o){var r=await __host.get(o.url,o.waitForSelector||\'\',o.purpose||\'\');return {html:r.body,url:r.url};}}; var __result=null, __error=null, __done=false;')
    context.eval('(async function(){try{__result=JSON.stringify(await (' + expression + '));}catch(e){__error=String(e);}finally{__done=true;}})();')
    jobs = 0
    while context.execute_pending_job():
        jobs += 1
        if jobs > 2000 or time.monotonic() - started > 90:
            raise ValueError('测试超时')
    error = context.eval('__error')
    if error:
        raise ValueError(error)
    if not context.eval('__done'):
        raise ValueError('脚本未完成执行')
    return json.loads(context.eval('__result'))


def verify(script, fetcher=None):
    result = execute(script, '''(async function(){
      var stage='分类';
      try {
      var cats = await LumeSource.categories();
      stage='筛选';
      var filters=typeof LumeSource.filters==='function' ? await LumeSource.filters({}) : {groups:[]};
      var groups=filters.groups||[];
      stage='列表';
      var list = await LumeSource.list({page:1});
      if(!list.items.length) throw new Error('列表为空');
      var samples=list.items.slice(0,3), last,covered=0,listCovered=0,categoryChecks=0,filterChecks=[],webPlayers=0;
      for(var i=0;i<samples.length;i++) {
      var first=samples[i];stage='详情（样本 '+(i+1)+'/'+samples.length+'）';
      var detail = await LumeSource.detail({id:first.id});
      if(!detail || !detail.title) throw new Error('详情没有标题');
      if(first.cover || detail.cover)covered++;
      if(first.cover)listCovered++;
      stage='选集（样本 '+(i+1)+'/'+samples.length+'）';
      var chapters = await LumeSource.chapters({id:first.id});
      if(!chapters.length) throw new Error('没有识别到章节或播放线路');
      stage='内容（样本 '+(i+1)+'/'+samples.length+'）';
      var content = await LumeSource.content({id:first.id,chapterId:chapters[0].id});
      if(content.kind==='images' && !content.images.length) throw new Error('图片为空');
      if((content.kind==='video' || content.kind==='audio') && !content.url) throw new Error('媒体地址为空');
      if(content.kind==='webplayer'){if(!/^https?:/.test(content.pageUrl||''))throw new Error('网页播放地址为空');webPlayers++;}
      if(['images','video','audio','webplayer'].indexOf(content.kind)<0)throw new Error('正文类型不受支持');
      last={categories:cats.filter(function(c){return c.id!==C.url&&c.id!=='all';}).length,filters:groups.length,items:list.items.length,title:detail.title,chapters:chapters.length,kind:content.kind,samples:samples.length,
        size:content.kind==='images' ? content.images.length : content.url};
      }
      var realCats=cats.filter(function(c){return c.id!==C.url&&c.id!=='all';});
      if(realCats.length) {
        stage='分类切换';var cat=realCats[realCats.length-1],catList=await LumeSource.list({page:1,categoryId:cat.id});
        if(!catList||!Array.isArray(catList.items))throw new Error('分类没有返回列表');
        categoryChecks=1;
      }
      for(var g=0;g<groups.length;g++) {
        stage='筛选回传 '+(g+1)+'/'+groups.length;var selected={},group=groups[g], option=group.options.filter(function(o){return o.id;})[0];
        if(option){selected[group.id]=option.id;var chosen=await LumeSource.list({page:1,filters:selected});if(!chosen||!Array.isArray(chosen.items))throw new Error('筛选没有返回列表');filterChecks.push({group:group.id,count:chosen.items.length,changed:JSON.stringify(chosen.items.map(function(x){return x.id;}))!==JSON.stringify(list.items.map(function(x){return x.id;}))});}
      }
      last.webPlayers=webPlayers;last.covered=covered;last.listCovered=listCovered;last.categoryChecks=categoryChecks;last.filterChecks=filterChecks;return last;
      } catch(e) {throw new Error(stage+'失败：'+String(e.message||e));}
    })()''', fetcher)
    size = str(result['size']) if result['kind'] == 'images' else '已提取媒体地址（未验证实际播放）'
    category = str(result['categories']) if result['categories'] else '未识别（仅全部）'
    filters = str(result['filters']) if result['filters'] else '未适配'
    cover = f"列表封面 {result['listCovered']}/{result['samples']}、含详情封面 {result['covered']}/{result['samples']}（仅检查地址，未下载图片）"
    changed = sum(x['changed'] for x in result['filterChecks'])
    note = f"；分类抽查 {result['categoryChecks']}，筛选回传 {len(result['filterChecks'])} 组、结果变化 {changed} 组（不代表其余筛选已证明生效）"
    if result['webPlayers']:
        size = f"直连媒体 {result['samples'] - result['webPlayers']} 条、源站网页播放 {result['webPlayers']} 条（登录、付费权限和实际播放未验证）"
    if result['listCovered'] < result['samples']:
        note += '；部分列表封面缺失，仍需适配'
    return f"抽样链路通过 {result['samples']} 条：分类 {category} / 筛选 {filters} / 列表 {result['items']} / {cover} / 章节 {result['chapters']} / 正文 {result['kind']} {size}" + note


def verify_config(config, rows, fetcher=None):
    from core import generate
    from exports import export_source
    extension, raw, route = export_source(config, rows)
    target = config.get('target', config['category'])
    if target == 'web':
        return f'HTML 导航快照已生成，{len(rows)} 个链接，{len(raw)} 字节。导入位置：{route}。网页打开效果需在 App 中检查。'
    if target in ('python', 'comic_python'):
        namespace = {}
        exec(compile(raw, 'generated.py', 'exec'), namespace)
        spider = namespace['Spider']()
        if fetcher:
            spider._get = lambda url: fetcher.get(url)[1]
            def api(**params):
                from urllib.parse import urlencode
                url = config['api'] + ('&' if '?' in config['api'] else '?') + urlencode(params)
                return json.loads(fetcher.get(url)[1])
            spider._api = api
        home = spider.homeVideoContent()
        samples = home.get('list', [])[:3]
        if not samples:
            raise ValueError('PY 列表为空')
        for first in samples:
            detail = spider.detailContent([str(first['vod_id'])])['list'][0]
            episode = detail['vod_play_url'].split('$$$')[0].split('#')[0].split('$', 1)[1]
            if target == 'comic_python':
                content = spider.imageContent(episode)
                if not content.get('images'):
                    raise ValueError('漫画 PY 没有返回章节图片')
            else:
                content = spider.playerContent('', episode, [])
                if not content.get('url'):
                    raise ValueError('PY Spider 没有返回媒体地址')
        if target == 'comic_python':
            return f'漫画 PY 抽样通过 {len(samples)} 条：列表、详情、章节、图片地址；图片未逐张下载。'
        return f'PY Spider 抽样通过 {len(samples)} 条：列表、详情、选集、媒体地址；未验证实际播放。'
    if target == 'module':
        return verify(raw.decode().replace('module.exports = GeneratedSource;', 'var LumeSource = GeneratedSource;'), fetcher)
    result = verify(generate(config), fetcher)
    if target == 'kazumi':
        result += '\n已生成 Kazumi JSON；XPath 的浏览器解析与实际播放仍需在 App 中验证。'
    elif target == 'cat':
        result += '\n已生成 Node 猫源 ZIP；本次仅检查抓取链路，Node 服务启动需在 App 中验证。'
    return result


def verify_with_fallback(config, rows, fetcher=None, *, allow_python=False):
    from core import target_config
    try:
        return config, verify_config(config, rows, fetcher)
    except Exception as first:
        if not allow_python or config.get('target') not in ('video', 'comic') or config.get('useBrowser'):
            raise
        candidate = target_config(config, 'comic_python' if config['target'] == 'comic' else 'python')
        try:
            result = verify_config(candidate, rows, fetcher)
        except Exception as second:
            raise ValueError('JS 未通过：' + str(first) + '\nPY 备用方案也未通过：' + str(second)) from second
        return candidate, 'JS 未通过：' + str(first) + '\n经你确认后尝试 PY 备用方案。' + result
