"""Discovery and portable LumeSource generation; no credentials in exported files."""
import hashlib
import json
import re
import sys
import io
import gzip
import zlib
import threading
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from collections import Counter
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qsl, urlencode, urljoin, urlsplit, urlunsplit, quote
from urllib.request import Request, build_opener, HTTPCookieProcessor, HTTPRedirectHandler, HTTPSHandler
from http.cookiejar import CookieJar

from bs4 import BeautifulSoup

TARGETS = {'有声小说': 'audio', '漫画': 'comic', '图片': 'images', '视频': 'video',
           'PY': 'python', '漫画 PY': 'comic_python', '模块': 'module', '猫源': 'cat', 'Kazumi': 'kazumi', '网页': 'web'}
SECTIONS = {'audio': 'video', 'comic': 'comic', 'images': 'comic', 'video': 'video',
            'python': 'video', 'comic_python': 'comic', 'module': 'video', 'cat': 'cat', 'kazumi': 'video', 'web': 'video'}


def target_config(config, target):
    if target not in SECTIONS:
        raise ValueError('不支持的模块：' + str(target))
    config = dict(config)
    config.update(target=target, category=SECTIONS[target],
                  media='audio' if target == 'audio' else 'images' if target in ('comic', 'images', 'comic_python') else 'video')
    return config


def api_base(url):
    parts = urlsplit(url)
    query = [(k, v) for k, v in parse_qsl(parts.query, keep_blank_values=True)
             if k.lower() not in ('ac', 'ids', 'wd', 'pg', 't')]
    return urlunsplit((parts.scheme, parts.netloc, parts.path, urlencode(query), ''))


def source_filename(config, extension):
    name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', '_', config['name']).strip().rstrip('. ')
    name = name[:100].rstrip('. ') or config['id']
    if re.match(r'^(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)', name, re.I):
        name = '_' + name
    return name + extension


def site_name(soup, url):
    """Prefer the site's brand and strip domain/SEO suffixes from page titles."""
    brand = soup.select_one('meta[property="og:site_name"],meta[name="application-name"]')
    title = (brand.get('content', '') if brand else '') or (soup.title.get_text(' ', strip=True) if soup.title else '')
    title = re.sub(r'\s+', ' ', title).strip()
    def domain_badge(match):
        inner = match.group(0)[1:-1].strip()
        return '' if re.fullmatch(r'(?:https?://)?(?:[\w-]+\.)+[a-zA-Z]{2,63}(?:[/?:][^\s]*)?', inner) else match.group(0)
    title = re.sub(r'[【\[(（][^】\])）]+[】\])）]', domain_badge, title)
    title = re.split(r'\s+[-–—|｜_]\s+|[|｜]', title, maxsplit=1)[0].strip()
    return title or urlsplit(url).hostname or url

MAX_BYTES = 6 * 1024 * 1024
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130.0 Safari/537.36'


class BrowserRequired(ValueError):
    """The HTML has navigation but no evidence of actual catalogue entries."""
    def __init__(self, message, target_url=None):
        super().__init__(message)
        self.target_url = target_url


def entry_redirect(html, base):
    """Recognize a tiny, unambiguous redirect stub without executing JavaScript."""
    if len(html) > 16384:
        return None
    soup = BeautifulSoup(html, 'html.parser')
    if soup.select('a[href],img,video,audio,iframe,form'):
        return None
    targets = []
    for meta in soup.select('meta[http-equiv]'):
        if meta.get('http-equiv', '').lower() == 'refresh':
            m = re.fullmatch(r'''\s*[012](?:\.0)?\s*;\s*url\s*=\s*['"]?([^'"<>]+)['"]?\s*''', meta.get('content', ''), re.I)
            if m:
                targets.append(m[1].strip())
    literal = r'''["']([^"'\n<>]+)["']'''
    for script in soup.find_all('script'):
        raw = script.get_text()
        direct = re.fullmatch(r'\s*(?:(?:window|top)\.)?location(?:\.href)?\s*=\s*' + literal + r'\s*;?\s*', raw)
        call = re.fullmatch(r'\s*(?:(?:window|top)\.)?location\.(?:replace|assign)\(\s*' + literal + r'\s*\)\s*;?\s*', raw)
        if direct or call:
            targets.append((direct or call)[1])
        elif raw.strip():
            return None
    if len(set(targets)) != 1:
        return None
    try:
        target = validate_url(urljoin(base, targets[0]))
        return target if target != base else None
    except ValueError:
        return None


def navigation_link(url):
    p = urlsplit(url)
    root_without_item = not p.path.strip('/') and not any(k in ('p', 'id', 'video_id', 'vod_id', 'book_id', 'm') and v for k, v in parse_qsl(p.query))
    catalogue_index = bool(re.fullmatch(r'/(?:videos|movies|latest|recent|new|home)/?', p.path, re.I))
    return root_without_item or catalogue_index or bool(re.search(
        r'/(?:c|a-z|alphabet|privacy|terms|dmca|2257|contact|about|help|faq|vip-info|points|featured|recommended|accounts?|login|signup|register|search|tags?|categories|category|types?|genres?|authors?|actors?|models?|pornstars?|performers?|users?|cdn-cgi)(?:/|$)',
        p.path, re.I))


def validate_url(value):
    value = value.strip()
    if '://' not in value:
        value = 'https://' + value
    p = urlsplit(value)
    if p.scheme not in ('http', 'https') or not p.hostname or p.username or p.password:
        raise ValueError('请输入有效的 http(s) 网址，不要在网址中包含账号密码')
    return value


def request_url(value):
    """Encode Unicode URLs once; preserve already escaped paths and queries."""
    parts = urlsplit(validate_url(value))
    host = parts.hostname.encode('idna').decode('ascii')
    if ':' in host:
        host = '[' + host + ']'
    if parts.port is not None:
        host += ':' + str(parts.port)
    return urlunsplit((parts.scheme, host,
        quote(parts.path, safe="/%:@!$&'()*+,;=-._~"),
        quote(parts.query, safe="%=&?/:;+,$@!()*'[]~-."), ''))


class EncodedRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return super().redirect_request(req, fp, code, msg, headers, request_url(newurl))


class Fetcher:
    def __init__(self, cancel_event=None):
        from network_tls import trust_context
        self.opener = build_opener(EncodedRedirects(), HTTPCookieProcessor(CookieJar()), HTTPSHandler(context=trust_context()))
        self.cancel_event = cancel_event

    def request(self, options):
        """Script HTTP contract, including guest POST and observable 401 status."""
        if self.cancel_event and self.cancel_event.is_set():
            raise InterruptedError('已取消制作')
        headers = {'User-Agent': UA, 'Accept-Encoding': 'identity'}
        headers.update(options.get('headers') or {})
        body = options.get('body')
        request = Request(request_url(options['url']),
                          data=str(body).encode('utf-8') if body is not None else None,
                          headers=headers, method=options.get('method', 'GET'))
        try:
            response = self.opener.open(request, timeout=18)
        except HTTPError as error:
            response = error
        except URLError as error:
            from network_tls import certificate_error, CertificateTrustError
            if certificate_error(error):
                raise CertificateTrustError(error) from error
            raise
        with response as r:
            raw = r.read(MAX_BYTES + 1)
            if len(raw) > MAX_BYTES:
                raise ValueError('接口响应超过 6MB')
            if self.cancel_event and self.cancel_event.is_set():
                raise InterruptedError('已取消制作')
            return {'status': r.status, 'url': r.url, 'headers': dict(r.headers),
                    'body': raw.decode(r.headers.get_content_charset() or 'utf-8', errors='replace')}

    def get(self, url, cancel_event=None):
        cancel = cancel_event or self.cancel_event or threading.Event()
        for attempt in range(2):
            if cancel.is_set():
                raise InterruptedError('已取消制作')
            try:
                return self._get(url)
            except HTTPError as e:
                code, wait = e.code, e.headers.get('Retry-After', '')
                e.close()
                delay = 1
                if wait:
                    try:
                        delay = max(0, float(wait))
                    except ValueError:
                        try:
                            delay = max(0, (parsedate_to_datetime(wait) - datetime.now(timezone.utc)).total_seconds())
                        except (ValueError, TypeError, OverflowError):
                            delay = 1
                if code in (429, 502, 503, 504) and attempt == 0 and delay <= 8:
                    if cancel.wait(delay):
                        raise InterruptedError('已取消制作')
                    continue
                hint = '；站点要求等待后重试' if code == 429 or delay > 8 else '；可能需要登录、网页验证或稍后重试'
                raise ValueError(f'站点返回 HTTP {code}' + hint) from e
            except (URLError, TimeoutError) as e:
                from network_tls import certificate_error, CertificateTrustError
                if certificate_error(e):
                    raise CertificateTrustError(e) from e
                if attempt == 0:
                    if cancel.wait(.5):
                        raise InterruptedError('已取消制作')
                    continue
                raise ValueError('无法连接：' + str(getattr(e, 'reason', e))) from e

    def _get(self, url):
        url = request_url(url)
        with self.opener.open(Request(url, headers={'User-Agent': UA, 'Accept': 'text/html,application/json', 'Accept-Encoding': 'identity'}), timeout=18) as r:
            raw = r.read(MAX_BYTES + 1)
            if len(raw) > MAX_BYTES:
                raise ValueError('页面超过 6MB，请改填具体的列表页')
            encoding = r.headers.get('Content-Encoding', '').lower().strip()
            if encoding == 'gzip':
                raw = gzip.GzipFile(fileobj=io.BytesIO(raw)).read(MAX_BYTES + 1)
            elif encoding == 'deflate':
                decoder = zlib.decompressobj()
                raw = decoder.decompress(raw, MAX_BYTES + 1)
            elif encoding and encoding != 'identity':
                raise ValueError('站点返回未支持的压缩格式 ' + encoding + '，请使用浏览器重试')
            if len(raw) > MAX_BYTES:
                raise ValueError('解压后的页面超过 6MB，请改填具体的列表页')
            charset = r.headers.get_content_charset()
            if not charset:
                m = re.search(br'charset\s*=\s*["\x27]?([\w-]+)', raw[:8192], re.I)
                charset = m.group(1).decode('ascii') if m else 'utf-8'
            try:
                body = raw.decode('utf-8-sig' if raw.startswith(b'\xef\xbb\xbf') else charset, errors='replace')
            except LookupError:
                body = raw.decode('utf-8', errors='replace')
            from page_verification import requires_verification, MESSAGE
            if requires_verification(body):
                raise ValueError(MESSAGE)
            return r.url, body


def html_items(html, base, pattern=''):
    soup = BeautifulSoup(html, 'html.parser')
    out, seen = [], set()
    rule = re.compile(pattern, re.I) if pattern else None
    for a in soup.select('a[href]'):
        href = a.get('href', '').strip()
        if not href or href.startswith(('#', 'javascript:', 'mailto:', 'tel:', 'data:')):
            continue
        url = urljoin(base, href)
        image = a.find('img')
        title = a.get('title') or a.get_text(' ', strip=True) or (image.get('alt') if image else '')
        if not title or url in seen or (rule and not rule.search(url)):
            continue
        seen.add(url)
        cover = (image.get('data-original') or image.get('data-src') or image.get('src') or '') if image else ''
        out.append({'id': url, 'title': title, 'cover': urljoin(base, cover) if cover else ''})
    return out


def guess_pattern(rows, base):
    host = urlsplit(base).netloc
    groups = Counter()
    for r in rows:
        p = urlsplit(r['id'])
        if p.netloc != host or not p.path.strip('/'):
            continue
        if navigation_link(r['id']):
            continue
        # Group card links even when a site's detail slug contains no numeric ID.
        numeric = re.search(r'/\d+/', p.path)
        if numeric:
            path = re.escape(p.path[:numeric.start()]) + r'/[^/?#]+(?:/[^?#]*)?'
        elif '/' in p.path.strip('/'):
            path = re.escape(p.path.rstrip('/').rsplit('/', 1)[0]) + r'/[^/?#]+/?'
        elif re.fullmatch(r'/[a-fA-F0-9]{24,64}/?', p.path):
            path = r'/[a-fA-F0-9]{24,64}/?'
        elif re.search(r'\.html?$', p.path, re.I):
            path = r'/[^/?#]+\.html?'
        else:
            path = re.sub(r'\d+', lambda _: r'\d+', re.escape(p.path))
        groups[path] += 3 if r['cover'] else 1
    if not groups:
        return re.escape(urlsplit(base).scheme + '://' + host) + r'/[^#]+'
    return '^' + re.escape(urlsplit(base).scheme + '://' + host) + groups.most_common(1)[0][0] + r'(?:[?#]|$)'


def html_config(url, category='video', html=''):
    config = {'url': url, 'id': 'web-' + hashlib.sha256(url.encode()).hexdigest()[:12],
        'name': site_name(BeautifulSoup(html, 'html.parser'), url), 'category': category,
        'mode': 'html', 'api': '', 'list': url, 'search': '', 'links': '',
        'chapters': r'(?:/play/|/vodplay/|/chapter/|/read/|/\d+/\d+\.html)', 'contentId': '',
        'categoryLinks': r'/(?:category|categories|catalog|type|genre)/',
        'filterFormIndex': -1, 'filterAction': '', 'filterKeys': [], 'filterNames': {}}
    return target_config(config, category)


def discover(url, category='video', fetcher=None, *, follow_catalogue=True):
    if category == 'novel':
        raise ValueError('当前 LumeBox 不支持文字小说，请选择有声小说')
    fetcher = fetcher or Fetcher()
    try:
        final, html = fetcher.get(url, purpose='list') if getattr(fetcher, 'browser_mode', False) else fetcher.get(url)
    except ValueError as error:
        from network_tls import CertificateTrustError
        if not getattr(fetcher, 'browser_mode', False) and (isinstance(error, CertificateTrustError) or re.search(r'HTTP 403|人工验证|网页验证', str(error))):
            raise BrowserRequired(str(error)) from error
        raise
    redirects = []
    if not getattr(fetcher, 'browser_mode', False):
        for _ in range(3):
            target = entry_redirect(html, final)
            if not target:
                break
            if target in redirects:
                raise ValueError('入口网页反复跳转，请填写最终作品列表网址')
            redirects.append(final)
            final, html = fetcher.get(target)
    soup = BeautifulSoup(html, 'html.parser')
    # Some directory gateways send every entry through the same redirect stub.
    # Require two agreeing samples and no visual works, then rediscover that entry.
    if not redirects and not getattr(fetcher, 'browser_mode', False) and not soup.select('img,video,audio'):
        candidates = [x for x in html_items(html, final) if not navigation_link(x['id'])
                      and urlsplit(x['id']).netloc == urlsplit(final).netloc][:2]
        targets = []
        if len(candidates) == 2:
            for candidate in candidates:
                try:
                    at, body = fetcher.get(candidate['id'])
                    target = entry_redirect(body, at)
                    if target:
                        targets.append(target)
                except (ValueError, URLError):
                    break
        if len(targets) == 2 and targets[0] == targets[1]:
            redirects.append(final)
            final, html = fetcher.get(targets[0])
            soup = BeautifulSoup(html, 'html.parser')
    config = html_config(final, category, html)
    if redirects:
        config['entryRedirects'] = redirects
    if category in ('audio', 'video', 'module') and re.search(r'<(?:rss|feed)\b', html, re.I):
        from verifier import execute
        feed_rows = execute(generate(config), 'feedItems(' + json.dumps(html) + ',C.url)')
        if feed_rows:
            config.update(mode='feed', profile='RSS / Atom 公开媒体订阅')
            return config, feed_rows, '已识别公开媒体订阅：标题、封面与 enclosure 媒体；不提供的分类和搜索会明确提示。'
    from platforms import advertised_platform
    platform = advertised_platform(config, html, fetcher)
    if platform:
        return platform
    for index, form in enumerate(soup.select('form')):
        selects = form.select('select[name]')
        action = urljoin(final, form.get('action') or final)
        if selects and form.get('method', 'get').lower() == 'get' and urlsplit(action).netloc == urlsplit(final).netloc:
            config.update(filterFormIndex=index, filterAction=action,
                          filterKeys=[select['name'] for select in selects])
            for select in selects:
                label = soup.find('label', attrs={'for': select.get('id', '')})
                config['filterNames'][select['name']] = select.get('aria-label') or (label.get_text(strip=True) if label else '') or select.get('title') or select['name']
            break
    for form in soup.select('form'):
        if form.get('method', 'get').lower() != 'get':
            continue
        field = form.find('input', attrs={'name': re.compile(r'^(wd|q|keyword|search|query)$', re.I)})
        if field:
            action = urljoin(final, form.get('action') or final)
            config['search'] = action + ('&' if '?' in action else '?') + field['name'] + '={keyword}'
            # A common GET form intercepts submit and builds a path using one
            # encodeURIComponent(input.value) variable. Read that literal only.
            if field.get('id'):
                for script in soup.find_all('script'):
                    raw = script.get_text()
                    if not re.search(r'''getElementById\(\s*['"]''' + re.escape(field['id']) + r'''['"]\s*\)\.value''', raw):
                        continue
                    route = re.search(r'''(?:window\.)?location\.href\s*=\s*`([^`$]+)\$\{encodeURIComponent\(\w+\)\}([^`$]*)`''', raw)
                    if route:
                        template_url = urljoin(final, route[1] + '{keyword}' + route[2])
                        if urlsplit(template_url).netloc == urlsplit(final).netloc:
                            config['search'] = template_url
                        break
            break
    if config['media'] in ('video', 'audio') and category in ('video','audio','module') and re.search(r'<(?:video|audio)\b', html, re.I):
        from verifier import execute
        inline = execute(generate(config), 'inlineMediaItems(' + json.dumps(html) + ',C.url)')
        if len(inline) >= 3 and sum(bool(x.get('cover')) for x in inline) >= 3:
            config.update(mode='inline-media', profile='HTML5 媒体流卡片',
                          categoryLinks=r'/(?:channel|category|categories|tag|genre)/')
            return config, inline, '已识别 HTML5 媒体卡片：直接使用公开媒体和 poster 封面，导航链接作为分类；分页仅沿网页明确给出的下一页，不能把频道当作品。'
    if category == 'web':
        rows = html_items(html, final)
        return config, rows, '网页入口已抓取；导出 HTML 导航页，通过 App 的网页模块导入。'
    # Only probe a CMS endpoint when the page advertises that engine; never scan paths.
    candidates = [final] if html.lstrip().startswith('{') else []
    if re.search(r'maccms|mac_url|player_aaaa|/voddetail/|/vodplay/', html, re.I):
        candidates.append(urljoin(final, '/api.php/provide/vod/'))
    for candidate in candidates:
        try:
            data = json.loads(html if candidate == final else fetcher.get(candidate)[1])
            if isinstance(data, dict) and data.get('list') and 'vod_id' in data['list'][0]:
                if category in ('comic', 'images', 'comic_python'):
                    raise ValueError('这是视频接口，请选择视频、PY、模块、猫源或 Kazumi')
                config.update(mode='maccms', api=api_base(candidate))
                rows = [{'id': str(v['vod_id']), 'title': v.get('vod_name', ''), 'cover': urljoin(final, v.get('vod_pic') or '')} for v in data['list']]
                return config, rows, '已识别苹果 CMS 接口，可实时获取分类、分页、搜索和播放线路。'
        except (ValueError, KeyError, TypeError, IndexError):
            continue
    all_rows = [r for r in html_items(html, final) if not navigation_link(r['id'])]
    from rule_detection import inferred_cards, inspect_pages
    rule_config, card_rows = inferred_cards(html, final, getattr(fetcher, 'adaptive_store', None))
    config.update(rule_config)
    # Category/search navigation may share the same visual card style as works.
    taxonomy = [urljoin(final, a['href']) for a in soup.select('nav a[href],.collapse a[href],header a[href],.dropdown-menu a[href]')
                if re.search(r'/(?:category|categories|catalog|type|genre|tags?|search|show)/[^/?#]+', urlsplit(a['href']).path, re.I)]
    if taxonomy:
        paths = sorted(set(re.escape(urlsplit(x).path.rsplit('/', 1)[0]) + r'/[^/?#]+' for x in taxonomy
                           if urlsplit(x).netloc == urlsplit(final).netloc))
        if paths:
            config['categoryLinks'] = '(?:' + '|'.join(paths) + ')'
    if card_rows:
        all_rows = card_rows
    if not all_rows or (not card_rows and re.search(r'__NEXT_DATA__|__NUXT_DATA__|data-nuxt-data|__INITIAL_STATE__|application/(?:ld\+)?json', html)):
        from verifier import execute
        payload_rows = execute(generate(config), 'structuredItems(' + json.dumps(html) + ',C.url)')
        if payload_rows:
            config.update(structuredList=True, profile='公开结构化 JSON')
            card_rows = all_rows = payload_rows
    if follow_catalogue and not card_rows and sum(bool(row.get('cover')) for row in all_rows) < 3:
        candidates = []
        for a in soup.select('a[href]'):
            candidate = urljoin(final, a['href'])
            parts = urlsplit(candidate)
            if parts.netloc == urlsplit(final).netloc and candidate != final and re.fullmatch(r'/(?:videos?|movies?|latest|recent|new)/?', parts.path) and candidate not in candidates:
                candidates.append(candidate)
        for candidate in candidates[:2]:
            try:
                return discover(candidate, category, fetcher, follow_catalogue=False)
            except (ValueError, URLError):
                continue
        if candidates:
            raise BrowserRequired('首页主要是分类导航；已找到列表入口，请在浏览器中继续读取真实作品', candidates[0])
    if not all_rows:
        if len(soup.select('button')) >= 5 and soup.select('.track-step,.choose-block,.wv-destination'):
            raise ValueError('当前是多步选择或推广落地页，未发现作品目录；请手动进入实际作品列表后，填写该列表的网址。')
        raise BrowserRequired('网页只有导航或动态加载入口，尚未读到作品列表；请在浏览器中继续。' + ('已识别入口跳转，转到实际站点。' if redirects else ''), final if redirects else None)
    # Large taxonomy menus must not outvote actual thumbnail-bearing works.
    # Without a known card layout, require several visual entries before
    # preferring them; a lone logo/banner is not evidence of a work catalogue.
    visual_rows = [row for row in all_rows if row.get('cover')]
    pattern_rows = card_rows or (visual_rows if len(visual_rows) >= 3 else all_rows)
    config['links'] = guess_pattern(pattern_rows, final)
    rows = card_rows or [row for row in html_items(html, final, config['links']) if not navigation_link(row['id'])]
    if not rows:
        raise BrowserRequired('没有识别到作品链接，页面可能动态加载；请在浏览器中继续或进入实际作品列表')
    path = urlsplit(rows[0]['id']).path
    prefix = path.rsplit('/', 1)[0] + '/' if '/' in path.strip('/') else re.split(r'\d', path, maxsplit=1)[0]
    if "'" not in prefix:
        config['searchXPath'] = "//a[contains(@href,'" + prefix + "')]"
    config['chapterXPath'] = "//a[contains(@href,'/play/') or contains(@href,'/vodplay/') or contains(@href,'/chapter/')]"
    inspect_pages(config, rows, fetcher)
    categories = html_items(html, final, config['categoryLinks'])
    profile = config.get('profile', '通用链接')
    return config, rows, f'规则方案：{profile}。分类链接 {len(categories)} 个，标准 GET 筛选组 {len(config["filterKeys"])} 个；已检查首条详情及漫画阅读区。未识别能力尚未适配，请抽样验证。' + config.get('inspectionNote', '')


def generate(config):
    config = dict(config)
    if config.get('category') == 'novel':
        raise ValueError('旧工程使用文字小说模式，请重新选择有声小说并识别网址')
    config = target_config(config, config.get('target', config['category']))
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', config['id']):
        raise ValueError('源 ID 只能包含英文字母、数字、短横线和下划线，最多 64 位')
    if not config['name'].strip():
        raise ValueError('请填写源名称')
    for key in ('links', 'chapters', 'categoryLinks'):
        re.compile(config.get(key, ''))
    for key in ('url', 'list'):
        validate_url(config[key])
    if config['search']:
        validate_url(config['search'])
    if config['mode'] in ('maccms', 'mediacms', 'wordpress'):
        validate_url(config['api'])
    root = Path(getattr(sys, '_MEIPASS', Path(__file__).parent))
    api_mode = config['mode'] in ('mediacms', 'wordpress')
    runtime = (root / ('gaze_runtime.js' if config['mode'] == 'gaze' else 'yeguo_runtime.js' if config['mode'] == 'yeguo' else 'drama_runtime.js' if config['mode'] == 'zhilian' else 'api_runtime.js' if api_mode else 'runtime.js')).read_text(encoding='utf-8')
    helpers = (root / 'html_rules.js').read_text(encoding='utf-8')
    helpers += '\n' + (root / 'page_actions.js').read_text(encoding='utf-8')
    helpers += '\n' + (root / 'structured_rules.js').read_text(encoding='utf-8')
    identity = {k: config[k] for k in ('id', 'name', 'category')}
    identity.update(version=config.get('version', '1.0.0'), mirrors=[config['url']])
    identity['mediaType'] = config['media']
    if config['mode'] == 'gaze':
        identity['icon'] = 'https://gaze.red/favicon.png'
    content_category = config.get('contentCategory', '')
    if config['target'] == 'video' and content_category:
        if content_category not in ('movie', 'adult', 'unclassified'):
            raise ValueError('JS 内容分类应为影视、成人或待分类')
        identity['contentCategory'] = content_category
    if config['target'] == 'images':
        identity['group'] = '美图'
    return '// LumeSource: ' + json.dumps(identity, ensure_ascii=False) + '\n// LumeRuntime: javascript\n' + helpers + '\n' + runtime.replace('__CONFIG__', json.dumps(config, ensure_ascii=False), 1)
