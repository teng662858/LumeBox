"""Export by the actual import paths in SourcePackage, CatLocalBundle and HtmlHomeImport."""
import hashlib
import html
import io
import json
import sys
import zipfile
from pathlib import Path

from core import generate, target_config


def resource(name):
    return (Path(getattr(sys, '_MEIPASS', Path(__file__).parent)) / name).read_text(encoding='utf-8')


def kazumi(config):
    c = config
    rule = {'name': c['name'], 'version': '1.0.0', 'api': '1', 'baseURL': c['url'],
            'useNativePlayer': True, 'usePost': False, 'useLegacyParser': False,
            'searchList': c.get('searchXPath', '//a[@href]'),
            'searchName': '@title | .//img/@alt | .//text()[normalize-space()]', 'searchResult': '.',
            'chapterRoads': '/html/body', 'chapterResult': c.get('chapterXPath', "//a[contains(@href,'/play/') or contains(@href,'/vodplay/')]")}
    if c['mode'] == 'maccms':
        rule.update(searchMode='api', chapterMode='api',
            searchApiConfig={'request': {'url': c['api'], 'method': 'GET', 'query': {'ac': 'detail', 'wd': '@keyword', 'pg': '@page'}},
                             'listPath': '$.list[*]', 'namePath': '$.vod_name', 'sourcePath': '$.vod_id'},
            chapterApiConfig={'request': {'url': c['api'], 'method': 'GET', 'query': {'ac': 'detail', 'ids': '@source'}},
                              'format': 'delimited', 'roadNamesPath': '$.list[0].vod_play_from', 'roadEpisodesPath': '$.list[0].vod_play_url'})
    else:
        if '{keyword}' not in c['search']:
            raise ValueError('Kazumi 规则需要真实搜索地址，请填写含 {keyword} 的搜索网址后导出')
        rule['searchURL'] = c['search'].replace('{keyword}', '@keyword').replace('{page}', '1')
    return json.dumps(rule, ensure_ascii=False, indent=2)


def export_source(config, rows=()):
    c = target_config(config, config.get('target', config['category']))
    script = generate(c)  # Shared metadata/rule validation.
    target = c['target']
    if c['mode'] == 'gaze' and target != 'video':
        raise ValueError('注视影视目前只支持视频 JS 网页播放，请保持 JS 格式')
    if c['mode'] in ('zhilian','yeguo') and target != 'video':
        raise ValueError('该短剧游客接口目前只支持视频 JS，请保持 JS 格式')
    if c['mode'] in ('mediacms', 'wordpress', 'feed','inline-media') and target not in ('video', 'audio', 'module'):
        raise ValueError('该公开接口目前支持 JS 或模块导出；其他格式尚未通过验证，请保持 JS')
    if c.get('useBrowser') and target in ('cat', 'python', 'comic_python'):
        raise ValueError('浏览器会话源目前请导出 JS 或模块；PY / Node 猫源尚未适配浏览器模式')
    if target == 'web':
        cards = []
        for row in rows:
            # Navigation snapshot: no third-party script or untrusted markup is copied.
            from core import validate_url
            try:
                address = validate_url(str(row['id']))
            except ValueError:
                continue
            cards.append('<a href="' + html.escape(address, quote=True) + '">' + html.escape(row['title']) + '</a>')
        page = '<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>' + html.escape(c['name']) + '</title><style>body{font:16px system-ui;background:#111827;color:#eef2ff;margin:24px}a{display:block;background:#25304a;color:#e0e7ff;padding:16px;margin:10px 0;border-radius:12px;text-decoration:none}</style><h1>' + html.escape(c['name']) + '</h1><p>抓取时的导航快照；点击条目访问原网页。</p><a href="' + html.escape(c['url'], quote=True) + '">打开网站首页</a>' + ''.join(cards) + '</html>'
        if len(page.encode()) > 2 * 1024 * 1024:
            raise ValueError('网页导出超过 App 的 2MB 限制')
        return '.html', page.encode(), '视频源选择 → 网页 → 导入 HTML 文件'
    if target == 'kazumi':
        return '.json', kazumi(c).encode(), '视频源选择 → Kazumi → 导入规则 JSON'
    if target in ('python', 'comic_python'):
        meta = json.loads(script.splitlines()[0].split(': ', 1)[1])
        body = '# LumeRuntime: python\n# LumeSource: ' + json.dumps(meta, ensure_ascii=False) + '\n'
        body += 'CONFIG = ' + repr(c) + '\n' + resource('python_runtime.py')
        route = '漫画板块 → 源管理 → 导入 .py 文件' if target == 'comic_python' else '视频源选择 → PY → 导入 .py 文件'
        return '.py', body.encode(), route
    if target == 'module':
        # Module scope must read HTTP from the host global, not a local exported object.
        body = script.replace('var LumeSource = {', 'var GeneratedSource = {').replace('LumeSource.http.get', 'globalThis.LumeSource.http.get').replace('LumeSource.web', 'globalThis.LumeSource.web')
        body += '\nmodule.exports = GeneratedSource;\n'
        return '.cjs', ('// LumeRuntime: module\n' + body).encode(), '视频源选择 → 模块 → 导入 .cjs 文件'
    if target == 'cat':
        source = script.replace('var LumeSource = {', 'var GeneratedSource = {').replace('LumeSource.http.get', '__nodeGet')
        body = resource('cat_runtime.cjs').replace('__SOURCE_SCRIPT__', source)
        output = io.BytesIO()
        with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
            for name, value in {'index.js': body, 'index.config.js': 'module.exports = {};\n'}.items():
                raw = value.encode()
                archive.writestr(name, raw)
                archive.writestr(name + '.md5', hashlib.md5(raw).hexdigest())
        return '.zip', output.getvalue(), '视频源选择 → 猫源 → 猫源订阅 → 导入本地 ZIP'
    return '.js', script.encode(), '对应板块源管理 → 导入 JS 文件' + ('；图片源导入后可分组为美图' if target == 'images' else '')
