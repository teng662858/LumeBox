"""Identify advertised public CMS APIs; never probe a list of guessed endpoints."""
import json
import re
from urllib.parse import urljoin, urlsplit, urlunsplit, parse_qsl, urlencode

from bs4 import BeautifulSoup


def api_path(endpoint, path, params=None):
    """Append a declared REST route for both pretty and query permalinks."""
    p = urlsplit(endpoint)
    query = dict(parse_qsl(p.query, keep_blank_values=True))
    if 'rest_route' in query:
        query['rest_route'] = query['rest_route'].rstrip('/') + path
        route = p.path
    else:
        route = p.path.rstrip('/') + path
    query.update(params or {})
    return urlunsplit((p.scheme, p.netloc, route, urlencode(query), ''))


def advertised_platform(config, html, fetcher):
    if config['target'] not in ('video', 'audio', 'module', 'cat'):
        return None
    base = config['url']
    if config['target'] == 'video' and urlsplit(base).hostname == 'gaze.red':
        rows, seen = [], set()
        for card in BeautifulSoup(html, 'html.parser').select('article'):
            link, image, heading = card.select_one('a[href]'), card.select_one('img[data-src]') or card.select_one('img[alt]:not([src*="/static/img/svg/"])'), card.select_one('h2,h3,h4,h5')
            address = urljoin(base, link.get('href', '')) if link else ''
            if not re.fullmatch(r'https://gaze\.red/play/[a-f0-9]{32}/?', address) or address in seen:
                continue
            title = heading.get_text(' ', strip=True) if heading else image.get('alt', '') if image else ''
            cover = urljoin(base, image.get('data-src') or image.get('src') or '') if image else ''
            if title and image and cover:
                seen.add(address)
                rows.append(dict(id=address, title=title, cover=cover, coverHeaders={'Referer': 'https://gaze.red/'}))
        if not rows:
            raise ValueError('注视影视未读到作品卡片，请在浏览器完成验证后读取当前页')
        config.update(mode='gaze', id='gaze_video', name='注视影视', url='https://gaze.red/',
                      contentCategory='movie', profile='注视影视网页播放器', useBrowser=True, version='1.0.2')
        return config, rows, '专用适配：公开目录、浏览器筛选和默认线路按钮选集；播放交给源站网页播放器，需要新版 App 选集支持。不把 blob 地址导出为媒体直链。'
    if config['target'] == 'video' and urlsplit(base).hostname in ('yeguodj.com','www.yeguodj.com'):
        from core import html_items
        rows = html_items(html, base, r'/drama/detail/\d+/?$')
        rows = [x for x in rows if x.get('cover')][:40]
        if not rows:
            raise ValueError('页面没有真实短剧卡片，请填写野果短剧首页')
        config.update(mode='yeguo', api='https://www.yeguodj.com/api.php', url='https://yeguodj.com',
                      name='野果短剧',contentCategory='adult',profile='野果短剧公开接口',useBrowser=False,version='1.0.2')
        return config, rows, '已适配野果短剧公开接口的响应格式、加密封面、主题分类、多组筛选、分页、详情和选集；仅使用站点实际下发的播放地址，锁定集转源站。关键词搜索尚未适配。'
    if config['target'] == 'video' and urlsplit(base).hostname == 'yklyo880.lldj1.xyz':
        origin = urlunsplit((*urlsplit(base)[:2], '', '', ''))
        data = json.loads(fetcher.get(origin + '/api/v1/dramas?sort=hot&size=20&page=1')[1])
        if isinstance(data, dict) and isinstance(data.get('data'), dict):
            data = data['data']
        rows = [{'id': str(x['id']), 'title': str(x['title']),
                 'cover': urljoin(origin, x.get('cover') or x.get('cover_url') or ''),
                 'coverHeaders': {'Referer': origin + '/'}}
                for x in data.get('list', []) if x.get('id') is not None and x.get('title')]
        if not rows:
            raise ValueError('短剧接口没有返回有效作品，请稍后重试')
        config.update(mode='zhilian', api=origin + '/api/v1', url=origin,
                      name='栀莲短剧', contentCategory='adult', profile='栀莲短剧游客接口',
                      useBrowser=False, version='1.0.1')
        return config, rows, '已适配短剧游客登录、分类、搜索、选集和获准播放的地址；锁定集交回源站，仍须抽样检查。'
    site = re.search(r'MediaCMS\.site\s*=\s*\{([\s\S]{0,5000}?)\};', html)
    if site and 'MediaCMS.api' in html:
        api = re.search(r'''\bapi\s*:\s*['"]([^'"]+)['"]''', site[1])
        if api:
            endpoint = urljoin(base, api[1]).rstrip('/')
            if urlsplit(endpoint).netloc != urlsplit(base).netloc:
                raise ValueError('页面声明了跨站 API，请核对实际站点网址')
            kind = 'audio' if config['media'] == 'audio' else 'video'
            data = json.loads(fetcher.get(endpoint + '/media?media_type=' + kind)[1])
            if isinstance(data, dict) and isinstance(data.get('results'), list):
                rows = [dict(id=x['url'], title=x['title'], cover=urljoin(base, x.get('thumbnail_url') or ''),
                    coverHeaders={'Referer': base}) for x in data['results'] if x.get('url') and x.get('title')]
                if not rows:
                    raise ValueError('站点 API 没有对应内容类型的公开作品')
                config.update(mode='mediacms', api=endpoint, profile='MediaCMS 公开接口', useBrowser=False, version='1.0.1')
                return config, rows, '已识别 MediaCMS：封面、分类、分页、搜索、排序与时长筛选由公开接口读取。'
    soup = BeautifulSoup(html, 'html.parser')
    discovery = soup.find('link', attrs={'rel': 'https://api.w.org/'})
    if discovery and discovery.get('href'):
        endpoint = urljoin(base, discovery['href'])
        if urlsplit(endpoint).netloc != urlsplit(base).netloc:
            return None
        root = json.loads(fetcher.get(endpoint)[1])
        if isinstance(root, dict) and 'wp/v2' in root.get('namespaces', []):
            endpoint = api_path(endpoint, '/wp/v2')
            posts = json.loads(fetcher.get(api_path(endpoint, '/posts', {'_embed': 1, 'per_page': 20}))[1])
            if isinstance(posts, list) and posts:
                config.update(mode='wordpress', api=endpoint, profile='WordPress REST', useBrowser=False)
                rows = []
                for x in posts:
                    media = x.get('_embedded', {}).get('wp:featuredmedia', [])
                    rows.append({'id': str(x['id']), 'title': BeautifulSoup(x.get('title', {}).get('rendered', ''), 'html.parser').get_text(),
                        'cover': media[0].get('source_url', '') if media else '', 'coverHeaders': {'Referer': base}})
                return config, rows, '已识别 WordPress REST：分类与封面已读取，正文仍须通过音视频或图片检查，普通文章不算可用作品。'
    return None
