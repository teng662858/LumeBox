"""Infer reusable rules from advertised HTML structures, never execute page JS."""
import re
from urllib.parse import urljoin, urlsplit

from bs4 import BeautifulSoup

CARD_PRESETS = [
    ('影视卡片', '.module-item, .module-poster-item, a.stui-vodlist__thumb, a.myui-vodlist__thumb'),
    ('漫画书目', '.page-item-detail, .manga-card, .comic-item, .book-item'),
    ('图文目录', '.video-item, .video-card, .post-item, article.type-post'),
    ('缩略图作品卡片', '.onevideothumb, a.clip-link'),
    ('Bootstrap 作品卡片', '.card'),
    ('缩略图目录', '.item.big, .coll-art, .item.thumb, .list_box a'),
    ('语义作品卡片', 'article'),
]
CHAPTER_PRESETS = ['.wp-manga-chapter a', '#chapterlist a', '.chapter-list a', '.chapters a',
                   '.module-play-list a', '.playlist a', '.stui-content__playlist a', '.myui-content__list a',
                   'a[href*="/player/"][href*="episode="]']
IMAGE_PRESETS = ['.reading-content img', '.chapter-content img', '.reader-area img', '.comic-reader img', '#manga-reader img', 'article img', 'main img']


def inferred_cards(html, base, adaptive_store=None):
    from core import navigation_link
    from scrapling import Selector
    soup = Selector(html, url=base, adaptive=False)
    best = None
    presets = list(CARD_PRESETS)
    if adaptive_store:
        selector, nodes = adaptive_store.recover(html, base, 'listSelector')
        if nodes:
            presets.insert(0, ('已学习 / 自动适应', selector))
    for label, selector in presets:
        rows, seen = [], set()
        for card in soup.css(selector):
            links = card.css('a[href]')
            outer = card.xpath('ancestor::a[@href][1]')
            link = card if card.attrib.get('href') else outer[0] if outer else links[0] if links else None
            if not link:
                continue
            url = urljoin(base, link.attrib['href'])
            if selector == 'article' and urlsplit(url).netloc != urlsplit(base).netloc:
                continue
            if urlsplit(url).scheme not in ('http', 'https') or url in seen or navigation_link(url):
                continue
            images, headings = card.css('img,source,[style*="background-image"],[data-background],video[poster]'), card.css('h2,h3,h4,h5,.title,.card-title')
            img = images[0] if images else None
            heading = headings[0] if headings else None
            title = (heading.get_all_text() if heading else '') or link.attrib.get('title') or (img.attrib.get('alt') if img else '') or link.get_all_text()
            title = re.sub(r'\s+', ' ', title).strip()
            if not title:
                continue
            seen.add(url)
            cover = ''
            if img:
                cover = next((img.attrib.get(k) for k in ('data-original','data-lazy-src','data-src','data-background','poster','src') if img.attrib.get(k) and not img.attrib.get(k).startswith('data:')), '')
                if not cover:
                    srcset = img.attrib.get('data-srcset') or img.attrib.get('srcset') or ''
                    cover = srcset.split(',')[-1].strip().split(' ')[0] if srcset else ''
                if not cover:
                    background = re.search(r'''url\(\s*['"]?([^'"\)]+)''', img.attrib.get('style', ''), re.I)
                    cover = background[1].strip() if background else ''
            row = {'id': url, 'title': title, 'cover': urljoin(base, cover) if cover else ''}
            if cover:
                row['coverHeaders'] = {'Referer': base}
            rows.append(row)
        if rows:
            score = len(rows) + sum(bool(r['cover']) for r in rows) * 3
            if best is None or score > best[0]:
                best = score, label, selector, rows
    if not best:
        return {}, []
    return {'profile': best[1], 'desktopParser': 'Scrapling', 'listSelector': best[2], 'linkSelector': 'a[href]',
            'titleSelector': 'h2,h3,h4,h5,.title,.card-title', 'coverSelector': 'img,source,[style*="background-image"],[data-background],video[poster]'}, best[3]


def inspect_pages(config, rows, fetcher):
    if not rows:
        return
    sample = rows[0]['id']
    if urlsplit(sample).netloc != urlsplit(config['url']).netloc:
        return
    try:
        final, html = fetcher.get(sample, purpose='chapters') if getattr(fetcher, 'browser_mode', False) else fetcher.get(sample)
        soup = BeautifulSoup(html, 'html.parser')
        chapters = []
        chapter_presets = list(CHAPTER_PRESETS)
        store = getattr(fetcher, 'adaptive_store', None)
        if store:
            selector, nodes = store.recover(html, config['url'], 'chapterSelector')
            if nodes:
                chapter_presets.insert(0, selector)
        for selector in chapter_presets:
            links = soup.select(selector)
            if links:
                config['chapterSelector'] = selector
                chapters = links
                break
        if not chapters:
            # A public player already identifies a single work. Incidental
            # episode words in recommendation titles must not redefine its URL
            # family as a chapter list.
            if config['media'] != 'images':
                from core import generate
                from verifier import execute
                import json
                if execute(generate(config), 'media(' + json.dumps(html) + ',C.url)'):
                    return
            # Only accept advertised chapter-like titles, not arbitrary navigation.
            from core import navigation_link
            links = [a for a in soup.select('a[href]') if len(a.get_text(' ', strip=True)) <= 40
                     and re.search(r'^(?:第\s*[\d一二三四五六七八九十百]+\s*[章话話集回卷]|(?:chapter|episode)\s*\d)', a.get_text(' ', strip=True), re.I)
                     and not navigation_link(urljoin(final, a['href']))]
            if links:
                from core import guess_pattern
                chapter_rows = [{'id': urljoin(final, a['href']), 'title': a.get_text(strip=True), 'cover': ''} for a in links]
                config['chapters'] = guess_pattern(chapter_rows, final)
                chapters = links
        if config['media'] != 'images':
            return
        if chapters:
            address = urljoin(final, chapters[0]['href'])
            if urlsplit(address).netloc == urlsplit(config['url']).netloc:
                _, html = fetcher.get(address)
                soup = BeautifulSoup(html, 'html.parser')
        image_presets = list(IMAGE_PRESETS)
        if store:
            selector, nodes = store.recover(html, config['url'], 'imageSelector')
            if nodes:
                image_presets.insert(0, selector)
        for selector in image_presets:
            if soup.select(selector):
                config['imageSelector'] = selector
                break
    except Exception as e:
        config['inspectionNote'] = '详情抽查尚未完成：' + str(e)
