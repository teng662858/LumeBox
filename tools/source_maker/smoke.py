"""Check the shipped Tk, HTML parser, QuickJS and runtime asset without network."""
import json
from pathlib import Path


def smoke(report):
    import ssl
    from network_tls import trust_context
    from pathlib import Path
    import certifi
    context = trust_context()
    assert context.check_hostname and context.verify_mode == ssl.CERT_REQUIRED
    assert Path(certifi.where()).is_file() and context.cert_store_stats()['x509_ca'] > 100
    from app import App
    from core import TARGETS, discover, generate, target_config
    from exports import export_source
    from verifier import execute

    class Fixture:
        def get(self, url):
            return url, '<title>打包验证</title><a href="/book/1"><img src="/cover.jpg" alt="验证作品"></a>'

    app = None
    try:
        config, rows, _ = discover('https://fixture.example/', 'audio', Fixture())
        app = App()
        app.attributes('-alpha', 0)
        app.load_config(config)
        app.show_rows(rows)
        app.update()
        layouts = []
        for geometry in ('980x760', '820x660'):
            app.geometry(geometry)
            app.update()
            assert not app.advanced_pane.winfo_ismapped()
            assert not app.log.winfo_ismapped()
            for button in (app.analyze_btn, app.export_btn, app.next_btn, app.current_page_btn, app.ai_btn):
                x, y = button.winfo_rootx() - app.winfo_rootx(), button.winfo_rooty() - app.winfo_rooty()
                assert button.winfo_ismapped(), button['text']
                assert 0 <= x and x + button.winfo_width() <= app.winfo_width(), (geometry, button['text'], x)
                assert 0 <= y and y + button.winfo_height() <= app.winfo_height(), (geometry, button['text'], y)
            layouts.append(geometry)
        app.prepare(show_preview=False)
        assert app.artifact and app.artifact[2].startswith(b'// LumeSource:')
        assert 'disabled' in app.export_btn.state(), 'Unverified source must not be exportable'
        app.validated_signature = app.artifact[0]
        app.refresh_export()
        assert 'disabled' not in app.export_btn.state()
        app.fields['name'].set('修改后需要重新生成')
        assert app.artifact is None and 'disabled' in app.export_btn.state()
        script = generate(app.collect())
        value = execute(script, 'LumeSource.list({page:1})', Fixture())
        assert value['items'][0]['title'] == '验证作品'
        assert value['items'][0]['id'] == 'https://fixture.example/book/1'
        literal = '<video></video><script>var source="https://media.example/lesson.m3u8";hls.loadSource(source);</script>'
        assert execute(script, 'playerLiteralMedia(' + json.dumps(literal) + ',C.url)') == 'https://media.example/lesson.m3u8'
        cms = dict(config, mode='mediacms', api='https://fixture.example/api', target='video', media='video')
        assert execute(generate(cms), 'LumeSource.filters()')['groups'][0]['id'] == 'sort_by'
        class PublicAPI:
            def get(self, url):
                return (url, "<script>MediaCMS.site={api:'/api'};MediaCMS.api={media:'/media'};</script>") if url.endswith('/') else (url, '{"results":[{"url":"/view?m=one","title":"Lesson","thumbnail_url":"/cover.jpg"}]}')
        detected, api_rows, _ = discover('https://fixture.example/', 'video', PublicAPI())
        assert detected['mode'] == 'mediacms' and api_rows[0]['cover'] == 'https://fixture.example/cover.jpg'
        formats = {}
        for label, target in TARGETS.items():
            candidate = target_config(config, target)
            if target in ('python', 'kazumi'):
                candidate.update(mode='maccms', api='https://fixture.example/api')
            extension, raw, _ = export_source(candidate, rows)
            assert raw
            if target == 'python':
                compile(raw, 'export.py', 'exec')
            formats[label] = extension
        import tempfile
        from adaptive_rules import AdaptiveFetcher, AdaptiveProfiles
        class Cards:
            def get(self, url):
                return url, '<title>Adaptive fixture</title><article class="video-card"><a href="/item/1">Lesson</a><img src="/cover.jpg"></article>'
        with tempfile.TemporaryDirectory() as directory:
            profiles = AdaptiveProfiles(directory)
            try:
                fetcher = AdaptiveFetcher(Cards(), profiles)
                adaptive_config, adaptive_rows, _ = discover('https://fixture.example/', 'video', fetcher)
                assert profiles.learn(adaptive_config, adaptive_rows, fetcher) == 1
                changed = '<title>Adaptive fixture</title><article class="changed-card"><a href="/item/1">Lesson</a><img src="/cover.jpg"></article>'
                selector, nodes = profiles.recover(changed, adaptive_config['url'], 'listSelector')
                assert selector == 'article.changed-card' and nodes
            finally:
                profiles.close()
        from app import ENGINES
        app.browser_actions = {'click': '#previous-site'}
        app.new_source()
        assert app.config_data is None and app.artifact is None and not app.rows
        assert not app.browser_actions and app.url.get() == ''
        assert 'disabled' in app.export_btn.state()
        from ai_assist import validate_rules
        from core import html_config
        ai_html = '<article class="video-card"><a href="/item/1"><img src="/one.jpg">Lesson</a></article>'
        ai_config, ai_rows = validate_rules(html_config('https://fixture.example/'), ai_html,
            {'listSelector':'article.video-card','linkSelector':'a[href]','coverSelector':'img'}, 'list')
        assert ai_config['aiAssisted'] and len(ai_rows) == 1
        from mcp_backend import evaluate_result
        assert evaluate_result({'content':[{'type':'text','text':'### Result\n"LUME_JSON:{\\"ok\\":true}"'}]})['ok']
        gaze_config = dict(config, mode='gaze', id='gaze_video', name='注视影视', target='video', category='video', media='video', url='https://gaze.red/', list='https://gaze.red/', search='', contentCategory='movie')
        gaze_script = generate(gaze_config)
        gaze_page = 'https://gaze.red/play/' + 'ab' * 16
        gaze_content = execute(gaze_script, 'LumeSource.content(' + json.dumps({'id': gaze_page, 'chapterId': gaze_page + '#episode=2'}) + ')')
        assert gaze_content['kind'] == 'webplayer' and 'data-id="2"' in gaze_content['webPlayerOptions']['episodeSelector']
        Path(report).write_text(json.dumps({'ok': True, 'gui': app.title(), 'items': value['items'], 'formats': formats, 'layouts': layouts, 'conversion_and_stale_export': True, 'adaptive_relocation': True, 'engine_options':len(ENGINES), 'source_bytes': len(script.encode())}, ensure_ascii=False, indent=2), encoding='utf-8')
        return True
    except Exception as e:
        import traceback
        Path(report).write_text(json.dumps({'ok': False, 'error': str(e), 'traceback':traceback.format_exc()}, ensure_ascii=False), encoding='utf-8')
        return False
    finally:
        if app:
            app.close_app()
