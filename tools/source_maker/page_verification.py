"""Recognize challenge responses; never solve or accept a verification automatically."""
import re


def requires_verification(html):
    if re.search(r'cf-chl-|验证您是真人', html, re.I):
        return True
    title = re.search(r'<title\b[^>]*>([\s\S]*?)</title>', html, re.I)
    text = re.sub(r'<[^>]*>', '', title[1]).strip() if title else ''
    return bool(re.search(r'^(?:Just a moment(?:\.\.\.)?|Attention Required(?:!|\s.*)?|安全验证|人机验证|访问验证|Security Verification|Verification Required|Verify (?:you are|you.re) human)$', text, re.I))


MESSAGE = '站点需要人工验证。请在浏览器中完成验证，回到工具点击“已完成，继续制作”；验证未完成前不能保存源。'
