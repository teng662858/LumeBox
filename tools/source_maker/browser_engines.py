"""Optional real-browser providers. No stealth settings or CAPTCHA automation."""
import json
import sys
import time


SNAPSHOT_SCRIPT = '({html:document.contentType.includes("json")?document.body.innerText:document.documentElement.outerHTML,ready:document.readyState,ua:navigator.userAgent,title:document.title})'


def navigation_interrupted(error):
    message = str(error).lower()
    return any(part in message for part in (
        'execution context was destroyed', 'cannot find context with specified id',
        'most likely because of a navigation', 'interrupted by another navigation',
        'net::err_aborted',
    ))


def playwright_snapshot(page, attempts=8):
    """Only replay a read, never replay clicks after their document navigated."""
    for attempt in range(attempts):
        try:
            return page.evaluate(SNAPSHOT_SCRIPT)
        except Exception as error:
            if not navigation_interrupted(error) or attempt + 1 >= attempts:
                raise
            page.wait_for_timeout(250)


def run_automation_worker(options, send):
    from core import validate_url
    from browser_session import same_site, LIMIT
    url = validate_url(options['url'])
    engine = options['engine']
    owner = None
    browser = None
    driver = None
    network = []
    started = False
    from browser_actions import program, network_row
    from page_verification import requires_verification, MESSAGE
    try:
        if engine == 'playwright':
            from playwright.sync_api import sync_playwright
            owner = sync_playwright().start()
            browser = owner.chromium.launch(channel='msedge', headless=bool(options.get('hidden_test')))
            context = browser.new_context()
            page = context.new_page()
            started = True
            def record(response):
                try:
                    if response.request.resource_type not in ('fetch', 'xhr') or not same_site(url, response.url):
                        return
                    raw = response.body()
                    if len(raw) <= 256 * 1024:
                        network.append(network_row(response.url, response.status, json.loads(raw)))
                        del network[:-20]
                except Exception:
                    pass
            page.on('response', record)
            page.set_default_timeout(15000)
            def navigate(target, selector=''):
                if page.url != target:
                    try:
                        page.goto(target, wait_until='domcontentloaded', timeout=18000)
                    except Exception as error:
                        if not navigation_interrupted(error):
                            raise
                        # Client-side redirects can replace the document between
                        # DOMContentLoaded and the first evaluation.
                        playwright_snapshot(page)
                if selector:
                    page.locator(selector).first.wait_for(state='attached', timeout=12000)
                else:
                    page.wait_for_timeout(450)
            navigate(url)
            current = lambda: page.url
            capture = lambda: playwright_snapshot(page)
            cookies = lambda: context.cookies([page.url])
            def apply_actions(actions, selector, purpose=''):
                try:
                    return page.evaluate(program(actions, selector, purpose))
                except Exception as error:
                    if not navigation_interrupted(error):
                        raise
                    # The action may already have navigated. Wait for its new
                    # document instead of clicking or scrolling a second time.
                    return playwright_snapshot(page)
        elif engine == 'selenium':
            import os
            os.environ.setdefault('SE_TIMEOUT', '25')
            from selenium import webdriver
            from selenium.webdriver.edge.options import Options
            from selenium.webdriver.common.by import By
            from selenium.webdriver.support.ui import WebDriverWait
            settings = Options()
            settings.set_capability('ms:loggingPrefs', {'performance': 'ALL'})
            if options.get('hidden_test'):
                settings.add_argument('--headless=new')
            driver = webdriver.Edge(options=settings)
            started = True
            driver.execute_cdp_cmd('Network.enable', {})
            driver.set_page_load_timeout(18)
            def navigate(target, selector=''):
                if driver.current_url != target:
                    driver.get(target)
                WebDriverWait(driver, 15).until(lambda d: d.execute_script('return document.readyState') == 'complete')
                if selector:
                    WebDriverWait(driver, 12).until(lambda d: d.find_elements(By.CSS_SELECTOR, selector))
                else:
                    time.sleep(.45)
            navigate(url)
            current = lambda: driver.current_url
            capture = lambda: driver.execute_script('return {html:document.contentType.includes("json")?document.body.innerText:document.documentElement.outerHTML,ready:document.readyState,ua:navigator.userAgent,title:document.title};')
            cookies = driver.get_cookies
            def apply_actions(actions, selector, purpose=''):
                driver.set_script_timeout(8)
                value = driver.execute_async_script('var done=arguments[0];' + program(actions, selector, purpose) + '.then(done,function(e){done({error:String(e)});});')
                if isinstance(value, dict) and value.get('error'):
                    raise ValueError(value['error'])
                return value
        else:
            raise ValueError('未知浏览器引擎')

        def collect_network():
            if engine != 'selenium':
                return
            for event in driver.get_log('performance'):
                try:
                    message = json.loads(event['message'])['message']
                    response = message['params'].get('response', {})
                    if message['method'] != 'Network.responseReceived' or message['params'].get('type') not in ('XHR', 'Fetch') or not same_site(url, response.get('url', '')):
                        continue
                    body = driver.execute_cdp_cmd('Network.getResponseBody', {'requestId': message['params']['requestId']})
                    raw = body['body']
                    if body.get('base64Encoded'):
                        import base64
                        raw = base64.b64decode(raw).decode()
                    if len(raw.encode('utf-8')) <= 256 * 1024:
                        network.append(network_row(response['url'], response['status'], json.loads(raw)))
                except Exception:
                    pass
            del network[:-20]

        accepted = False
        def accept():
            nonlocal accepted
            try:
                info = capture()
            except Exception as error:
                if not navigation_interrupted(error):
                    raise
                send({'event': 'notice', 'message': '页面正在跳转，请等作品列表出现后再次继续'})
                return
            if not same_site(url, current()) or info['ready'] not in ('interactive', 'complete'):
                send({'event': 'notice', 'message': '请回到目标站点，等页面加载完成后继续'})
                return
            if requires_verification(info['html']):
                send({'event': 'notice', 'message': '页面仍在验证，请手动完成后继续'})
                return
            accepted = True
            send({'ok': True, 'url': current(), 'user_agent': info['ua'], 'cookie_count': len(cookies())})

        if options.get('hidden_test'):
            accept()
        for line in sys.stdin:
            request = json.loads(line)
            if request['action'] == 'close':
                break
            if request['action'] == 'accept':
                if not accepted:
                    accept()
                continue
            if request['action'] == 'snapshot':
                try:
                    if not accepted:
                        raise ValueError('请先完成网页验证')
                    info = capture()
                    collect_network()
                    location = current()
                    if not same_site(url, location):
                        raise ValueError('当前页属于其他站点，请返回原站点或重新连接')
                    if len(info['html'].encode('utf-8')) > LIMIT:
                        raise ValueError('网页超过 6MB')
                    if info['ready'] not in ('interactive', 'complete') or requires_verification(info['html']):
                        raise ValueError('页面尚未加载或验证完成，请稍后重试')
                    send({'ok': True, 'url': location, 'html': info['html']})
                except Exception as error:
                    send({'ok': False, 'error': str(error)})
                continue
            if request['action'] == 'network':
                collect_network()
                send({'ok': True, 'network': network})
                continue
            if request['action'] == 'embed':
                try:
                    target = validate_url(request['url'])
                    if engine != 'playwright':
                        raise ValueError('跨站播放器 DOM 读取当前仅支持推荐浏览器 / Playwright')
                    # Read an already loaded frame, never navigate the main session
                    # to an arbitrary foreign URL or copy its cookies elsewhere.
                    frames = [frame for frame in page.frames if frame != page.main_frame and frame.url == target]
                    if not frames:
                        raise ValueError('源站声明的播放器尚未加载，或发生跨站跳转；需要人工验证或单独适配')
                    frame = frames[0]
                    frame.evaluate(program({}, '', 'media'))
                    info = frame.evaluate(SNAPSHOT_SCRIPT)
                    if requires_verification(info['html']):
                        raise ValueError(MESSAGE)
                    if len(info['html'].encode('utf-8')) > LIMIT:
                        raise ValueError('播放器页面超过 6MB')
                    send({'ok': True, 'url': frame.url, 'html': info['html']})
                except Exception as error:
                    send({'ok': False, 'error': str(error)})
                continue
            try:
                if not accepted:
                    raise ValueError('请先完成网页验证')
                target = validate_url(request['url'])
                if not same_site(url, target):
                    raise ValueError('当前会话不能访问其他站点')
                collect_network()
                navigate(target, '' if request.get('actions') else request.get('selector', ''))
                if request.get('actions') or request.get('purpose'):
                    apply_actions(request.get('actions'), request.get('selector', ''), request.get('purpose', ''))
                info = capture()
                collect_network()
                if requires_verification(info['html']):
                    raise ValueError(MESSAGE)
                if len(info['html'].encode()) > LIMIT:
                    raise ValueError('网页超过 6MB')
                if not same_site(url, current()):
                    raise ValueError('网页跳转到其他站点，已停止采集')
                send({'ok': True, 'url': current(), 'html': info['html']})
            except Exception as e:
                send({'ok': False, 'error': str(e)})
    except Exception as e:
        stage = ' 页面加载或采集失败：' if started else ' 无法启动：'
        send({'ok': False, 'error': engine + stage + str(e)})
    finally:
        if driver:
            driver.quit()
        if browser:
            browser.close()
        if owner:
            owner.stop()
