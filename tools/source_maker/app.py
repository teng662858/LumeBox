"""Native Windows GUI. Fetching stays on a worker; Tk runs only on the main thread."""
import json
import os
import queue
import threading
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

from core import TARGETS, BrowserRequired, Fetcher, discover, generate, html_items, target_config, source_filename
from exports import export_source

ENGINES = {'推荐浏览器（Edge）': 'playwright', '内置浏览器': 'webview', 'Playwright': 'playwright', 'Playwright MCP（需 Node.js）': 'mcp-playwright', 'Selenium': 'selenium',
    'Scrapling HTTP': 'scrapling-fetcher', 'Scrapling 异步 HTTP': 'scrapling-async',
    'Scrapling HTTP 会话': 'scrapling-session', 'Scrapling 异步 HTTP 会话': 'scrapling-async-session',
    'Scrapling 浏览器': 'scrapling-browser', 'Scrapling 异步浏览器': 'scrapling-async-browser',
    'Scrapling 浏览器会话': 'scrapling-browser-session', 'Scrapling 异步浏览器会话': 'scrapling-async-browser-session'}


class TaskFetcher:
    def __init__(self, fetcher, cancel):
        self.fetcher, self.cancel = fetcher, cancel

    def __getattr__(self, name):
        return getattr(self.fetcher, name)

    def request(self, options):
        if self.cancel and self.cancel.is_set():
            raise InterruptedError('已取消制作')
        value = self.fetcher.request(options)
        if self.cancel and self.cancel.is_set():
            raise InterruptedError('已取消制作')
        return value

    def get(self, *args, **kwargs):
        if self.cancel and self.cancel.is_set():
            raise InterruptedError('已取消制作')
        from adaptive_rules import AdaptiveFetcher
        if isinstance(self.fetcher, (Fetcher, AdaptiveFetcher)):
            kwargs['cancel_event'] = self.cancel
        result = self.fetcher.get(*args, **kwargs)
        if self.cancel and self.cancel.is_set():
            raise InterruptedError('已取消制作')
        return result


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title('LumeBox 制源工坊 0.8.2')
        self.geometry('980x760')
        self.minsize(820, 660)
        self.configure(bg='#f4f6fa')
        self.events = queue.Queue()
        self.config_data = None
        self.rows = []
        self.artifact = None
        self.validated_signature = None
        self.busy = False
        self.browser = None
        self.fetcher = Fetcher()
        self.browser_actions = {}
        self.ai_settings = {'endpoint': '', 'model': '', 'key': ''}
        self.updates = queue.Queue()
        self.batch_stop = None
        self.input_revision = 0
        self.loading_config = False
        self.advanced_visible = False
        self.details_visible = False
        self.failed_config = None
        self.last_category = '视频'
        self.last_saved = None
        self.operation_id = 0
        self.operation_cancel = None
        self.worker_context = threading.local()
        from adaptive_rules import AdaptiveProfiles
        self.adaptive_store = AdaptiveProfiles()
        self.adaptive_enabled = True
        self.protocol('WM_DELETE_WINDOW', self.close_app)
        self.output_dir = Path.home() / 'Documents' / 'LumeBox Sources'
        style = ttk.Style(self)
        style.theme_use('clam')
        style.configure('.', font=('Microsoft YaHei UI', 10), background='#f4f6fa')
        style.configure('TButton', padding=(12, 8))
        style.configure('Accent.TButton', foreground='white', background='#4d5eea')
        style.configure('Treeview', rowheight=36, background='white', fieldbackground='white')
        style.configure('TEntry', padding=7)
        shell = ttk.Frame(self, padding=22)
        shell.pack(fill='both', expand=True)
        header = ttk.Frame(shell)
        header.pack(fill='x')
        ttk.Label(header, text='LumeBox 制源工坊', font=('Microsoft YaHei UI', 22, 'bold')).pack(side='left')
        self.advanced_btn = ttk.Button(header, text='高级设置', command=self.toggle_advanced)
        self.advanced_btn.pack(side='right')
        ttk.Label(shell, text='填入网址，自动检查，保存后导入 LumeBox。', foreground='#68738a').pack(anchor='w', pady=(4, 18))

        actions = ttk.Frame(shell)
        actions.pack(side='bottom', fill='x', pady=(14, 0))
        self.conversion_status = tk.StringVar(value='默认生成 JS；只有你确认后才尝试 PY。')
        ttk.Label(actions, textvariable=self.conversion_status, foreground='#68738a', wraplength=730).pack(anchor='w', pady=(0, 10))
        self.export_btn = ttk.Button(actions, text='保存源文件', style='Accent.TButton', command=self.export, state='disabled')
        self.export_btn.pack(side='right')
        self.next_btn = ttk.Button(actions, text='制作下一个源', command=self.new_source)
        self.next_btn.pack(side='right', padx=(0, 8))
        ttk.Label(actions, text='保存后，在 LumeBox 对应的源管理中导入文件。', foreground='#68738a').pack(side='left')

        form = ttk.LabelFrame(shell, text='1  填写网站', padding=14)
        form.pack(fill='x')
        bar = ttk.Frame(form)
        bar.pack(fill='x')
        self.url = tk.StringVar()
        self.url_entry = ttk.Entry(bar, textvariable=self.url, font=('Microsoft YaHei UI', 11))
        self.url_entry.pack(side='left', fill='x', expand=True)
        self.url_entry.bind('<Return>', lambda _: self.make_source())
        self.category = tk.StringVar(value='视频')
        self.target_box = ttk.Combobox(bar, textvariable=self.category, values=['视频', '漫画', '有声小说', '图片'], state='readonly', width=8)
        self.target_box.pack(side='left', padx=8)
        self.analyze_btn = ttk.Button(bar, text='开始制作', style='Accent.TButton', command=self.make_source)
        self.analyze_btn.pack(side='left')
        self.cancel_btn = ttk.Button(bar, text='取消', command=self.cancel_operation, state='disabled', width=5)
        self.cancel_btn.pack(side='left', padx=(6, 0))
        ttk.Label(form, text='例如 https://example.com/videos，优先填写有作品封面的列表页。', foreground='#68738a').pack(anchor='w', pady=(8, 0))
        self.browser_engine = tk.StringVar(value='推荐浏览器（Edge）')
        browser_tools = ttk.Frame(form)
        browser_tools.pack(fill='x', pady=(8, 0))
        self.browser_btn = ttk.Button(browser_tools, text='网页需要登录或加载不全？用浏览器重试', command=lambda: self.verify_in_browser(auto_verify=True))
        self.browser_btn.pack(side='left')
        self.current_page_btn = ttk.Button(browser_tools, text='读取浏览器当前页', command=self.read_browser_page)
        self.current_page_btn.pack(side='left', padx=(8, 0))
        self.ai_btn = ttk.Button(browser_tools, text='AI 辅助识别', command=self.ai_dialog)
        self.ai_btn.pack(side='left', padx=(8, 0))
        self.status = tk.StringVar(value='准备就绪，填入网址后点击“开始制作”。')
        ttk.Label(shell, textvariable=self.status, wraplength=900, foreground='#4d5eea').pack(anchor='w', pady=(14, 8))
        self.progress = ttk.Progressbar(shell, mode='indeterminate')
        self.progress.pack(fill='x', pady=(0, 12))

        self.panes = ttk.Panedwindow(shell, orient='horizontal')
        self.panes.pack(fill='both', expand=True)
        self.left = ttk.Frame(self.panes)
        self.panes.add(self.left, weight=3)
        self.preview_heading = ttk.Frame(self.left)
        self.preview_heading.pack(fill='x', pady=(0, 8))
        ttk.Label(self.preview_heading, text='2  确认识别结果', font=('Microsoft YaHei UI', 13, 'bold')).pack(side='left')
        self.details_btn = ttk.Button(self.preview_heading, text='查看详情', command=self.toggle_details)
        self.details_btn.pack(side='right')
        name_row = ttk.Frame(self.left)
        name_row.pack(fill='x', pady=(0, 10))
        ttk.Label(name_row, text='源名称').pack(side='left', padx=(0, 10))
        self.fields = {'name': tk.StringVar()}
        self.name_entry = ttk.Entry(name_row, textvariable=self.fields['name'])
        self.name_entry.pack(side='left', fill='x', expand=True)
        ttk.Label(name_row, text='JS 分类').pack(side='left', padx=(12, 6))
        self.content_category = tk.StringVar(value='自动识别')
        self.content_category_box = ttk.Combobox(name_row, textvariable=self.content_category,
            values=['自动识别', '影视', '成人', '待分类'], state='readonly', width=9)
        self.content_category_box.pack(side='left')
        self.browser_help = ttk.LabelFrame(self.left, text='在浏览器里完成后，回来继续', padding=10)
        ttk.Label(self.browser_help, text='在浏览器中完成网页验证、看到作品列表后，点击“已完成，继续制作”。', wraplength=640).pack(anchor='w')
        browser_actions = ttk.Frame(self.browser_help)
        browser_actions.pack(fill='x', pady=(8, 0))
        self.continue_btn = ttk.Button(browser_actions, text='已完成，继续制作', command=self.accept_browser)
        self.continue_btn.pack(side='left')
        ttk.Button(browser_actions, text='取消浏览器操作', command=self.cancel_browser).pack(side='left', padx=8)
        self.python_btn = ttk.Button(self.left, text='尝试 PY 方案（需你确认）', command=self.confirm_python)
        self.treeframe = ttk.Frame(self.left)
        self.treeframe.pack(fill='both', expand=True)
        self.tree = ttk.Treeview(self.treeframe, columns=('title', 'url'), displaycolumns=('title',), show='headings', selectmode='browse')
        self.tree.heading('title', text='识别到的作品')
        self.tree.heading('url', text='条目地址 / ID')
        self.tree.column('title', width=260)
        self.tree.column('url', width=240)
        scroll = ttk.Scrollbar(self.treeframe, command=self.tree.yview)
        self.tree.configure(yscrollcommand=scroll.set)
        self.tree.pack(side='left', fill='both', expand=True)
        scroll.pack(side='right', fill='y')
        self.details_frame = ttk.Frame(self.left)
        self.log = tk.Text(self.details_frame, height=6, wrap='word', font=('Microsoft YaHei UI', 9), relief='flat', padx=10, pady=8, state='disabled')
        self.log.pack(fill='x')

        self.advanced_pane = ttk.Frame(self.panes, padding=(16, 0, 0, 0))
        canvas = tk.Canvas(self.advanced_pane, highlightthickness=0, bg='#f4f6fa', width=350)
        settings_scroll = ttk.Scrollbar(self.advanced_pane, orient='vertical', command=canvas.yview)
        canvas.configure(yscrollcommand=settings_scroll.set)
        settings_scroll.pack(side='right', fill='y')
        canvas.pack(side='left', fill='both', expand=True)
        right = ttk.Frame(canvas)
        settings_window = canvas.create_window((0, 0), window=right, anchor='nw')
        right.bind('<Configure>', lambda _: canvas.configure(scrollregion=canvas.bbox('all')))
        canvas.bind('<Configure>', lambda e: canvas.itemconfigure(settings_window, width=e.width))
        canvas.bind('<MouseWheel>', lambda e: canvas.yview_scroll(-int(e.delta / 120), 'units'))
        self.settings_canvas = canvas
        ttk.Label(right, text='高级设置 · 按需使用', font=('Microsoft YaHei UI', 13, 'bold')).pack(anchor='w', pady=(0, 8))
        ttk.Label(right, text='输出类型 / 格式').pack(anchor='w')
        ttk.Combobox(right, textvariable=self.category, values=list(TARGETS), state='readonly').pack(fill='x', pady=(3, 8))
        ttk.Label(right, text='浏览器与采集引擎').pack(anchor='w')
        ttk.Combobox(right, textvariable=self.browser_engine, values=list(ENGINES), state='readonly').pack(fill='x', pady=(3, 6))
        self.buttons = [self.browser_btn, self.current_page_btn, self.ai_btn]
        for label, callback in [('连接当前引擎', lambda: self.verify_in_browser(auto_verify=True)), ('结束浏览器会话', self.end_browser), ('浏览器操作 / 接口记录', self.browser_options_dialog)]:
            button = ttk.Button(right, text=label, command=callback)
            button.pack(fill='x', pady=3)
            self.buttons.append(button)
        adaptive_value = tk.BooleanVar(value=True)
        ttk.Checkbutton(right, text='记住已验证规则，帮助下次识别', variable=adaptive_value, command=lambda: setattr(self, 'adaptive_enabled', adaptive_value.get())).pack(anchor='w', pady=8)
        ttk.Button(right, text='忘记本站样本', command=lambda: self.attempt(self.forget_profile)).pack(fill='x')
        labels = [('id', '源 ID'), ('list', '列表网址 · {page} 表示页数'), ('search', '搜索网址 · {keyword} 表示关键词'), ('links', '列表链接规则 · 正则'), ('categoryLinks', '分类链接规则 · 正则'), ('chapters', '章节 / 选集链接规则 · 正则'), ('contentId', '漫画 / 图片内容元素 ID · 可选')]
        for key, label in labels:
            ttk.Label(right, text=label, foreground='#68738a').pack(anchor='w', pady=(8, 2))
            value = tk.StringVar()
            ttk.Entry(right, textvariable=value).pack(fill='x')
            self.fields[key] = value
        self.target_note = tk.StringVar(value='默认输出 JS，不会自动切换 PY。')
        ttk.Label(right, textvariable=self.target_note, wraplength=320, foreground='#68738a').pack(anchor='w', pady=10)
        for label, callback in [('AI 辅助识别规则', self.ai_dialog), ('编辑 Kazumi XPath', self.edit_kazumi), ('高级解析规则 · CSS', self.edit_rules), ('查看各引擎功能范围', self.show_capabilities), ('仅重新识别', self.analyze), ('重新预览', self.preview), ('保存工程', self.save_project), ('打开工程', self.open_project), ('批量制作', self.batch_dialog)]:
            button = ttk.Button(right, text=label, command=callback)
            button.pack(fill='x', pady=3)
            self.buttons.append(button)
        ttk.Button(right, text='暂停批量任务', command=lambda: self.batch_stop.set() if self.batch_stop else None).pack(fill='x', pady=3)
        self.generate_btn = ttk.Button(right, text='查看源代码草稿', command=self.prepare)
        self.generate_btn.pack(fill='x', pady=3)
        self.verify_btn = ttk.Button(right, text='重新检查当前规则', command=self.test_first)
        self.verify_btn.pack(fill='x', pady=3)
        self.buttons.extend([self.generate_btn, self.verify_btn])
        for value in self.fields.values():
            value.trace_add('write', lambda *_: self.invalidate())
        self.url.trace_add('write', lambda *_: self.invalidate())
        self.category.trace_add('write', lambda *_: self.target_changed())
        self.content_category.trace_add('write', lambda *_: self.invalidate())
        self.browser_engine.trace_add('write', lambda *_: self.invalidate())
        self.drain_timer = self.after(100, self.drain)
        self.url_entry.focus_set()

    def toggle_advanced(self):
        self.advanced_visible = not self.advanced_visible
        if self.advanced_visible:
            self.panes.add(self.advanced_pane, weight=2)
            self.advanced_btn.configure(text='收起高级设置')
            self.tree.configure(displaycolumns=('title', 'url'))
        else:
            self.panes.forget(self.advanced_pane)
            self.advanced_btn.configure(text='高级设置')
            self.tree.configure(displaycolumns=('title',))

    def toggle_details(self):
        self.details_visible = not self.details_visible
        if self.details_visible:
            self.details_frame.pack(side='bottom', fill='x', before=self.treeframe, pady=(8, 0))
        else:
            self.details_frame.pack_forget()
        self.details_btn.configure(text='收起详情' if self.details_visible else '查看详情')

    def make_source(self):
        if self.busy:
            return
        def start():
            from core import validate_url
            url = validate_url(self.url.get())
            if self.config_data and url != self.config_data['url']:
                self.clear_source(keep_url=True)
            self.detach_other_browser(url)
            if not self.browser and self.browser_engine.get() not in ('内置浏览器', '推荐浏览器（Edge）'):
                self.analyze(auto_verify=True)
            elif self.config_data and url == self.config_data['url'] and self.rows:
                self.test_first()
            else:
                self.analyze(auto_verify=True)
        self.attempt(start)

    def release_browser(self):
        browser, self.browser = self.browser, None
        if browser:
            browser.cancel()
            threading.Thread(target=browser.close, daemon=True).start()
        self.browser_help.pack_forget()

    def detach_other_browser(self, url):
        from browser_session import same_site
        if self.browser and (not same_site(self.browser.url, url) or self.browser.closed.is_set()):
            self.release_browser()

    def clear_source(self, keep_url=False):
        # Invalidate the worker before clearing fields: its late callback is obsolete.
        self.cancel_operation()
        self.config_data = None
        self.rows = []
        self.artifact = self.validated_signature = self.failed_config = None
        self.browser_actions = {}
        self.loading_config = True
        try:
            for value in self.fields.values():
                value.set('')
            if not keep_url:
                self.url.set('')
            self.content_category.set('自动识别')
            if self.category.get() in ('PY', '漫画 PY'):
                self.category.set('漫画' if self.category.get() == '漫画 PY' else '视频')
        finally:
            self.loading_config = False
        self.target_changed()
        self.tree.delete(*self.tree.get_children())
        self.log.configure(state='normal')
        self.log.delete('1.0', 'end')
        self.log.configure(state='disabled')
        if self.details_visible:
            self.toggle_details()
        self.conversion_status.set('默认生成 JS；只有你确认后才尝试 PY。')
        self.status.set('准备制作下一个源，填入网址后点击“开始制作”。')
        self.url_entry.focus_set()

    def new_source(self):
        self.clear_source()

    def read_browser_page(self):
        def start():
            if self.busy:
                return
            browser = self.browser
            if not browser or not browser.ready:
                raise ValueError('请先用浏览器重试并完成连接，再在该窗口打开作品列表页。')
            category = TARGETS[self.category.get()]
            def run():
                url, html = browser.current_page()
                from browser_session import CurrentPageFetcher
                config, rows, message = discover(url, category, self.active_fetcher(CurrentPageFetcher(browser, url, html)))
                config['useBrowser'] = True
                return config, rows, message
            def done(result):
                config, rows, message = result
                self.load_config(config)
                self.show_rows(rows)
                self.note('已读取浏览器当前页并更新列表入口；仍需检查详情、选集和内容。')
                self.note(message)
                self.test_first()
            self.work(run, done)
        self.attempt(start)

    def cancel_browser(self):
        self.cancel_operation()

    def cancel_operation(self):
        self.operation_id += 1
        if self.operation_cancel:
            self.operation_cancel.set()
        self.input_revision += 1
        if self.batch_stop:
            self.batch_stop.set()
        self.release_browser()
        self.busy = False
        self.progress.stop()
        for button in [self.analyze_btn, self.python_btn] + self.buttons:
            button.configure(state='normal')
        self.cancel_btn.configure(state='disabled')
        self.invalidate()
        self.browser_help.pack_forget()
        self.status.set('已取消。可以直接修改网址，重新开始制作。')

    def confirm_python(self):
        if self.busy or not self.failed_config:
            return
        if not messagebox.askyesno('是否尝试 PY？', '当前 JS 检查未通过。是否由你确认尝试 PY？\n\n只有 PY 也检查通过后才允许保存；不同意会继续保留 JS。', parent=self):
            return
        self.test_first(allow_python=True)

    def note(self, message):
        self.log.configure(state='normal')
        self.log.insert('end', message + '\n')
        self.log.see('end')
        self.log.configure(state='disabled')

    def close_app(self):
        self.after_cancel(self.drain_timer)
        if self.operation_cancel:
            self.operation_cancel.set()
        if self.batch_stop:
            self.batch_stop.set()
        if self.browser:
            browser = self.browser
            browser.cancel()
            threading.Thread(target=browser.close, daemon=True).start()
        self.adaptive_store.close()
        self.destroy()

    def active_fetcher(self, base=None):
        base = base or (self.browser if self.browser else self.fetcher)
        if self.adaptive_enabled:
            from adaptive_rules import AdaptiveFetcher
            base = AdaptiveFetcher(base, self.adaptive_store)
        return TaskFetcher(base, getattr(self.worker_context, 'cancel', None))

    def forget_profile(self):
        from core import validate_url
        self.adaptive_store.forget(validate_url(self.url.get()))
        self.note('已忘记本站已学习的解析样本，下次通过验证后会重新学习。')

    def browser_options_dialog(self):
        dialog = tk.Toplevel(self)
        dialog.title('浏览器操作与接口响应')
        dialog.geometry('660x420')
        ttk.Label(dialog, text='用于动态列表加载；设置会保存到工程和浏览器 JS 源。\n每页最多点击 3 次、滚动 3 次。HTTP 模式不执行浏览器操作。', wraplength=600).pack(padx=16, pady=12)
        values = {}
        for key, label in [('click','加载更多按钮 CSS（可留空）'), ('clicks','点击次数 0～3'), ('scroll','滚动次数 0～3'), ('wait','操作后等待出现的 CSS（可留空）')]:
            ttk.Label(dialog, text=label).pack(anchor='w', padx=16)
            values[key] = tk.StringVar(value=str(self.browser_actions.get(key, 0 if key in ('clicks', 'scroll') else '')))
            ttk.Entry(dialog, textvariable=values[key]).pack(fill='x', padx=16, pady=(0, 6))
        def save():
            data = {key: value.get().strip() for key, value in values.items()}
            for key in ('clicks','scroll'):
                data[key] = int(data[key])
                if not 0 <= data[key] <= 3:
                    raise ValueError('次数必须在 0～3 之间')
            self.browser_actions = data
            if self.browser:
                self.browser.actions = data
            self.invalidate()
            dialog.destroy()
        def inspect():
            if not self.browser:
                raise ValueError('请先连接 Playwright、Selenium 或 Scrapling 浏览器')
            def done(rows):
                self.note('接口记录只用于辅助适配，不会自动写入源：\n' + json.dumps(rows, ensure_ascii=False, indent=2))
                self.status.set(f'已读取 {len(rows)} 条 JSON 接口响应，见日志；常见敏感字段已隐藏')
            self.work(self.browser.network, done)
        row = ttk.Frame(dialog)
        row.pack(fill='x', padx=16, pady=12)
        ttk.Button(row, text='读取接口响应（不含请求头）', command=lambda: self.attempt(inspect)).pack(side='left')
        ttk.Button(row, text='保存操作', command=lambda: self.attempt(save)).pack(side='right')

    def ai_dialog(self):
        dialog = tk.Toplevel(self)
        dialog.title('AI 辅助规则 · 可选')
        dialog.geometry('710x470')
        ttk.Label(dialog, text='填写兼容 Chat Completions 的完整接口地址、模型名和密钥。\n点击分析会向该服务发送当前页面的精简结构（不含脚本、正文、输入值和 Cookie）。\n密钥仅保留在本次软件运行内，不保存到工程或源文件。模型服务可能收费。', wraplength=660).pack(anchor='w', padx=16, pady=14)
        values = {}
        for key, label in [('endpoint', '完整接口地址（如服务商提供的 /v1/chat/completions）'), ('model', '模型名'), ('key', '密钥（本地无鉴权模型可留空）')]:
            ttk.Label(dialog, text=label).pack(anchor='w', padx=16)
            values[key] = tk.StringVar(value=self.ai_settings[key])
            ttk.Entry(dialog, textvariable=values[key], show='*' if key == 'key' else '').pack(fill='x', padx=16, pady=(2, 8))
        role = tk.StringVar(value='列表页')
        ttk.Label(dialog, text='浏览器当前页面用途；详情/阅读页需先识别已有源').pack(anchor='w', padx=16)
        ttk.Combobox(dialog, textvariable=role, values=['列表页', '详情 / 选集页', '漫画 / 图片页'], state='readonly').pack(fill='x', padx=16)
        def start():
            self.ai_settings = {key: value.get().strip() for key, value in values.items()}
            selected = {'列表页':'list', '详情 / 选集页':'chapters', '漫画 / 图片页':'images'}[role.get()]
            self.ai_analyze(selected)
            dialog.destroy()
        ttk.Button(dialog, text='发送页面结构并分析', command=lambda: self.attempt(start)).pack(pady=16)

    def ai_analyze(self, role='list'):
        if self.busy:
            return
        from core import validate_url, html_config
        from browser_session import same_site
        from ai_assist import propose, validate_rules
        url = validate_url(self.url.get())
        if role != 'list' and not self.config_data:
            raise ValueError('请先识别列表或打开工程，再在浏览器中进入详情/阅读页')
        settings = dict(self.ai_settings)
        config = self.collect() if self.config_data else None
        target = TARGETS[self.category.get()]
        if target not in ('video', 'comic', 'images', 'audio', 'module'):
            raise ValueError('AI CSS 辅助目前支持视频、漫画、图片、有声小说的 JS 或模块输出；请先选择相应格式')
        browser = self.browser
        rows = list(self.rows)
        def run():
            if browser:
                final, html = browser.current_page()
            else:
                final, html = self.active_fetcher().get(url)
            if not same_site(url, final):
                raise ValueError('当前页面属于其他站点，请重新连接')
            base = config if config and role != 'list' else html_config(final, target, html)
            if base['mode'] != 'html':
                raise ValueError('AI CSS 辅助仅用于 HTML 源，不能覆盖已有接口协议')
            base = dict(base, useBrowser=bool(browser and browser.browser_mode))
            rules = propose(settings, html, final, role, self.worker_context.cancel)
            candidate, extracted = validate_rules(base, html, rules, role)
            return candidate, extracted if extracted is not None else rows, rules
        def done(result):
            candidate, extracted, rules = result
            preview = json.dumps(rules, ensure_ascii=False, indent=2)
            if not messagebox.askyesno('应用 AI 规则并检查？', f'页面结构检查通过，候选作品 {len(extracted)} 条。\n\n{preview}\n\n是否应用并继续验证？通过前不能导出。', parent=self):
                self.status.set('已保留原规则，未应用 AI 建议。')
                return
            self.load_config(candidate)
            self.show_rows(extracted)
            self.note('已应用 AI 提出的 CSS 规则；正在抽查实际链路。')
            self.test_first()
        self.work(run, done)

    def show_capabilities(self):
        dialog = tk.Toplevel(self)
        dialog.title('已接入的能力与使用范围')
        dialog.geometry('800x530')
        text = tk.Text(dialog, wrap='word', padx=18, pady=18, font=('Microsoft YaHei UI', 11))
        text.pack(fill='both', expand=True)
        text.insert('1.0', '''Playwright / Selenium
真实浏览器、手动登录与验证、会话 Cookie、点击加载更多、滚动、等待元素、同站 JSON 接口响应记录。
主界面可读取手动导航后的当前页，更新制源入口并重新验证；内置浏览器也支持。Scrapling 不提供手动导航标签页。

Playwright MCP / AI 辅助
实际接入 Microsoft Playwright MCP 0.0.83：需 Node.js 18+ 与 install_mcp.ps1 安装的本机依赖。提供隔离浏览器、手动验证、DOM 读取、点击/滚动/等待和制源验证；当前 MCP 通道不记录 JSON 响应体。AI 辅助需要自己填写兼容接口、模型和密钥，发送精简页面结构，返回 CSS 后先本地检查，再由你应用并验证；密钥不保存到工程或源。

Scrapling 0.5
Fetcher、AsyncFetcher、HTTP 同步/异步会话；StealthyFetcher 同步/异步浏览器抓取与 StealthySession / AsyncStealthySession。浏览器支持同样的页面操作与接口记录，验证仍由你手动完成。

自动适应
验证通过后学习列表卡片、章节和漫画图片区域。以后重新识别同一网址时尝试匹配变化的结构，并生成普通 CSS；无法可靠恢复或源验证失败时阻止导出。学习数据保存在本机，已导入手机的源不会自行安装 Scrapling 或自动更新。

Scrapy
最多 10 个站点的公开入口采集；可调并发、间隔、重试，自动限速、robots 规则、进度、暂停与任务文件续作；已导出文件校验完整后复用。当前请求完成后暂停后续处理。

转换
默认保持 JS；检查失败不会切换 PY，必须由你确认后才尝试。漫画默认 JS，确认后可输出漫画 PY。分类、筛选、分页、封面、详情、选集和内容都需要对应规则。抓取成功不等于源已可用，检查媒体地址不等于实际起播。

范围
这是制源工作流的集成，并非所有框架 API 的图形化编辑器。当前只接入上述 Playwright MCP 工具子集，分布式部署、远程爬虫集群、其他 MCP 服务、任意专用加密播放器等没有接入。''')
        text.configure(state='disabled')

    def accept_browser(self):
        if self.browser and not self.browser.ready:
            self.browser.accept()
            self.status.set('正在检查当前网页；如验证未通过，请继续在浏览器中操作')
        elif self.browser and not self.busy:
            self.browser_help.pack_forget()
            self.make_source()

    def end_browser(self):
        if self.busy:
            self.cancel_operation()
            return
        if self.browser:
            browser, self.browser = self.browser, None
            browser.cancel()
            threading.Thread(target=browser.close, daemon=True).start()
            self.invalidate()
            self.note('浏览器会话已结束。动态源再次测试前需重新连接所选引擎并完成验证。')

    def batch_dialog(self):
        dialog = tk.Toplevel(self)
        dialog.title('批量制源 · 最多 10 个公开站点')
        dialog.geometry('650x420')
        ttk.Label(dialog, text='每行一个列表网址。按当前模块识别、验证，通过的才导出。\n需要登录或手动验证的站点，请返回主界面单独处理。', wraplength=600).pack(padx=16, pady=16)
        urls = tk.Text(dialog, height=10)
        urls.pack(fill='both', expand=True, padx=16)
        settings_frame = ttk.Frame(dialog)
        settings_frame.pack(fill='x', padx=16, pady=8)
        settings_values = {}
        for key, label, default in [('concurrency','并发 1～4','2'), ('delay','间隔秒 .3～5','.5'), ('retries','失败重试 0～2','1')]:
            ttk.Label(settings_frame, text=label).pack(side='left')
            settings_values[key] = tk.StringVar(value=default)
            ttk.Entry(settings_frame, textvariable=settings_values[key], width=4).pack(side='left', padx=(2, 8))
        def run():
            values = list(dict.fromkeys(u.strip() for u in urls.get('1.0', 'end').splitlines() if u.strip()))
            from core import validate_url
            for value in values:
                validate_url(value)
            if not 1 <= len(values) <= 10:
                raise ValueError('请输入 1～10 个网址')
            directory = filedialog.askdirectory(parent=dialog, title='选择批量导出目录')
            if not directory:
                return
            target = TARGETS[self.category.get()]
            settings = {'concurrency': int(settings_values['concurrency'].get()), 'delay': float(settings_values['delay'].get()), 'retries': int(settings_values['retries'].get())}
            self.batch_stop = threading.Event()
            dialog.destroy()
            from batch_crawler import batch_convert
            def done(reports):
                passed = sum(r['ok'] for r in reports)
                state = '已暂停，可选择相同目录继续' if self.batch_stop.is_set() else '完成'
                self.status.set(f'批量{state}：{passed}/{len(reports)} 个通过，结果在 {directory}')
                self.note(json.dumps(reports, ensure_ascii=False, indent=2))
            self.work(lambda: batch_convert(values, target, directory, settings, self.batch_stop, self.updates.put), done)
        ttk.Button(dialog, text='选择目录并开始', command=lambda: self.attempt(run)).pack(pady=16)
        ttk.Button(dialog, text='暂停当前批量任务', command=lambda: self.batch_stop.set() if self.batch_stop else None).pack()

    def verify_in_browser(self, auto_verify=False):
        from core import validate_url
        def start():
            url = validate_url(self.url.get())
            self.detach_other_browser(url)
            from browser_session import BrowserSession
            target = TARGETS[self.category.get()]
            engine = ENGINES[self.browser_engine.get()]
            previous = self.browser
            def run():
                cancel = self.worker_context.cancel
                if previous:
                    previous.close()
                def opened(session):
                    if cancel.is_set():
                        session.cancel()
                    else:
                        self.browser = session
                browser = BrowserSession(url, engine=engine, on_open=opened, cancel_event=cancel)
                browser.actions = dict(self.browser_actions)
                try:
                    c, rows, message = discover(browser.url, target, self.active_fetcher(base=browser))
                    c['useBrowser'] = browser.browser_mode
                    return c, rows, message
                except Exception:
                    browser.close()
                    if self.browser is browser:
                        self.browser = None
                    raise
            def done(result):
                c, rows, message = result
                self.load_config(c)
                self.show_rows(rows)
                self.note('采集引擎已连接。HTTP 模式直接读取页面；浏览器模式支持动态网页。Cookie 不写入源文件，手机 App 上需重新验证。')
                self.note(message)
                self.browser_help.pack_forget()
                if auto_verify:
                    self.test_first()
            self.work(run, done)
            if self.details_visible:
                self.toggle_details()
            self.browser_help.pack(fill='x', before=self.treeframe, pady=(0, 10))
            self.status.set('请在浏览器里打开作品列表，然后点“已完成，继续制作”。')
        self.attempt(start)

    def invalidate(self):
        if self.loading_config:
            return
        self.input_revision += 1
        self.artifact = None
        self.validated_signature = None
        self.failed_config = None
        self.python_btn.pack_forget()
        self.export_btn.configure(state='disabled')
        self.conversion_status.set('已修改内容，请点“开始制作”重新检查。' if self.config_data else '默认生成 JS；只有你确认后才尝试 PY。')

    def fingerprint(self, config):
        return json.dumps([config, self.rows], ensure_ascii=False, sort_keys=True)

    def refresh_export(self):
        ready = self.artifact and self.artifact[0] == self.validated_signature
        self.export_btn.configure(state='normal' if ready else 'disabled')

    def prepare(self, show_preview=True):
        def convert():
            c = self.collect()
            extension, data, route = export_source(c, self.rows)
            self.artifact = (self.fingerprint(c), extension, data, route)
            self.refresh_export()
            checked = '抽样验证已通过' if self.validated_signature == self.artifact[0] else '草稿，验证通过后才能导出'
            filename = source_filename(c, extension)
            self.conversion_status.set(f'已生成 {filename} · {len(data):,} 字节 · {checked}')
            self.note(f'源代码草稿已生成：{extension}。这不代表网站已适配；需抽样验证作品、选集和内容后才能导出。\n导入位置：{route}')
            if show_preview:
                self.show_source(filename, data, extension, route)
        self.attempt(convert)

    def show_source(self, filename, data, extension, route):
        dialog = tk.Toplevel(self)
        dialog.title('源已生成 · ' + filename)
        dialog.geometry('900x640')
        ttk.Label(dialog, text=filename + ' · 尚需验证抓取链路', font=('Microsoft YaHei UI', 13, 'bold')).pack(anchor='w', padx=16, pady=12)
        ttk.Label(dialog, text='导入位置：' + route, wraplength=850).pack(anchor='w', padx=16)
        frame = ttk.Frame(dialog, padding=16)
        frame.pack(fill='both', expand=True)
        code = tk.Text(frame, wrap='none', font=('Consolas', 10), relief='flat')
        scroll = ttk.Scrollbar(frame, command=code.yview)
        code.configure(yscrollcommand=scroll.set)
        scroll.pack(side='right', fill='y')
        code.pack(fill='both', expand=True)
        if extension == '.zip':
            import io
            import zipfile
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                display = '猫源 ZIP 文件：\n' + '\n'.join(archive.namelist()) + '\n\n--- index.js ---\n' + archive.read('index.js').decode('utf-8')
        else:
            display = data.decode('utf-8')
        code.insert('1.0', display)
        code.configure(state='disabled')
        buttons = ttk.Frame(dialog, padding=(16, 0, 16, 16))
        buttons.pack(side='bottom', fill='x', before=frame)
        ttk.Button(buttons, text='返回验证', command=dialog.destroy).pack(side='left')
        ttk.Button(buttons, text='导出源文件', style='Accent.TButton', command=self.export).pack(side='right')

    def work(self, fn, done):
        if self.busy:
            return
        self.busy = True
        revision = self.input_revision
        self.operation_id += 1
        operation = self.operation_id
        cancel = self.operation_cancel = threading.Event()
        for b in [self.analyze_btn, self.export_btn, self.python_btn] + self.buttons:
            b.configure(state='disabled')
        self.progress.start(12)
        self.cancel_btn.configure(state='normal')
        self.status.set('正在识别并检查内容，请稍候…')
        def worker():
            self.worker_context.cancel = cancel
            try:
                self.events.put((done, fn(), None, revision, operation))
            except Exception as e:
                self.events.put((done, None, e, revision, operation))
        threading.Thread(target=worker, daemon=True).start()

    def drain(self):
        while True:
            try:
                self.note(self.updates.get_nowait())
            except queue.Empty:
                break
        try:
            done, value, error, revision, operation = self.events.get_nowait()
            if operation != self.operation_id:
                self.drain_timer = self.after(100, self.drain)
                return
            self.busy = False
            self.progress.stop()
            self.cancel_btn.configure(state='disabled')
            for b in [self.analyze_btn, self.export_btn, self.python_btn] + self.buttons:
                b.configure(state='normal')
            self.refresh_export()
            if revision != self.input_revision:
                self.status.set('输入已改变，请点“开始制作”重新检查。')
                self.note('输入已改变，已丢弃上一次操作的结果，避免保存旧网站或旧规则。')
            elif error:
                self.validated_signature = None
                self.refresh_export()
                if self.artifact:
                    self.conversion_status.set('验证未通过，已阻止导出 · 可保存工程继续适配')
                self.status.set('检查未通过：' + str(error).splitlines()[0][:180])
                self.note(str(error))
                if self.browser and getattr(self.browser, 'ready', False) and '人工验证' in str(error):
                    self.browser_help.pack(fill='x', before=self.treeframe, pady=(0, 10))
                if not self.details_visible:
                    self.toggle_details()
                if self.failed_config and self.failed_config.get('target') in ('video', 'comic') and not self.failed_config.get('useBrowser'):
                    self.python_btn.pack(anchor='w', before=self.treeframe, pady=(0, 10))
                if isinstance(error, BrowserRequired) and self.browser_engine.get() == '推荐浏览器（Edge）' and not getattr(self.browser, 'browser_mode', False):
                    if error.target_url:
                        self.url.set(error.target_url)
                        self.note('已识别入口跳转，继续读取实际列表网址：' + error.target_url)
                    self.note('已识别为动态列表，将用推荐浏览器继续；不会切换源格式。')
                    self.verify_in_browser(auto_verify=True)
            else:
                try:
                    done(value)
                except Exception as e:
                    self.status.set('操作未完成：' + str(e))
                    self.note(str(e))
        except queue.Empty:
            pass
        self.drain_timer = self.after(100, self.drain)

    def show_rows(self, rows):
        self.invalidate()
        self.rows = rows
        self.tree.delete(*self.tree.get_children())
        for row in rows:
            self.tree.insert('', 'end', values=(row['title'], row['id']))
        self.status.set(f'识别到 {len(rows)} 个候选作品，正在准备检查。')

    def load_config(self, config):
        if config.get('category') == 'novel':
            raise ValueError('旧工程是文字小说格式，当前 App 不支持；请重新选择有声小说并识别网址')
        self.config_data = config
        self.browser_actions = dict(config.get('browserActions', self.browser_actions))
        if self.browser:
            self.browser.actions = dict(self.browser_actions)
        self.loading_config = True
        try:
            self.url.set(config['url'])
            target = config.get('target', config['category'])
            self.category.set(next(k for k, v in TARGETS.items() if v == target))
            for k, v in self.fields.items():
                v.set(config.get(k, ''))
            self.content_category.set({'movie':'影视', 'adult':'成人', 'unclassified':'待分类'}.get(config.get('contentCategory'), '自动识别'))
        finally:
            self.loading_config = False
        self.last_category = self.category.get()
        self.target_changed()

    def target_changed(self):
        self.content_category_box.configure(state='readonly' if self.category.get() == '视频' else 'disabled')
        if not self.loading_config and self.category.get() in ('PY', '漫画 PY') and self.last_category != self.category.get():
            if not messagebox.askyesno('是否切换为 PY？', '默认保持 JS。确定要把这次输出切换为 PY 吗？', parent=self):
                self.category.set(self.last_category)
                return
        if self.loading_config:
            return
        self.last_category = self.category.get()
        if hasattr(self, 'export_btn'):
            self.invalidate()
        notes = {'audio': '有声小说 → JS · category=video / kind=audio',
                 'comic': '漫画 → JS · category=comic / 图片章节',
                 'images': '图片 → JS · category=comic / 详情即图集；导入后可分组为美图',
                 'video': '视频 → JS · category=video / 视频直链',
                 'python': '已由你确认使用 PY 视频源。支持公开 HTML 与苹果 CMS。',
                 'comic_python': '已由你确认使用漫画 PY。导入漫画源管理，章节返回阅读区图片列表。',
                 'module': '模块 → .cjs · CommonJS 源对象导出',
                 'cat': '猫源 → ZIP · Node start() / index.config.js / MD5',
                 'kazumi': 'Kazumi → JSON · XPath 或 JSON API 规则',
                 'web': '网页 → HTML · 导航快照，点击访问原网页'}
        self.target_note.set(notes[TARGETS[self.category.get()]])

    def edit_rules(self):
        if not self.config_data:
            return
        dialog = tk.Toplevel(self)
        dialog.title('高级解析规则 · 保存后重新生成和验证')
        dialog.geometry('760x620')
        ttk.Label(dialog, text='支持标签、.class、#id、[属性]、后代、> 和逗号；留空使用通用解析。', wraplength=700).pack(anchor='w', padx=18, pady=10)
        values = {}
        for key, label in [('listSelector','列表卡片'), ('linkSelector','卡片内作品链接'), ('titleSelector','卡片内标题'), ('coverSelector','卡片内封面'), ('chapterSelector','详情页章节链接'), ('imageSelector','章节内漫画图片'), ('nextSelector','下一页链接')]:
            ttk.Label(dialog, text=label).pack(anchor='w', padx=18, pady=(5, 1))
            values[key] = tk.StringVar(value=self.config_data.get(key, ''))
            ttk.Entry(dialog, textvariable=values[key]).pack(fill='x', padx=18)
        def save():
            self.config_data.update({k: v.get().strip() for k, v in values.items()})
            self.invalidate()
            self.note('解析规则已保存，需重新预览、生成并验证。')
            dialog.destroy()
        ttk.Button(dialog, text='保存规则', command=save).pack(pady=14)

    def edit_kazumi(self):
        if not self.config_data:
            return
        dialog = tk.Toplevel(self)
        dialog.title('Kazumi XPath 规则')
        dialog.geometry('700x240')
        values = {}
        for key, label, default in [('searchXPath', '搜索结果链接 XPath', '//a[@href]'), ('chapterXPath', '章节链接 XPath', "//a[contains(@href,'/play/') or contains(@href,'/vodplay/')]")]:
            ttk.Label(dialog, text=label).pack(anchor='w', padx=18, pady=(12, 2))
            values[key] = tk.StringVar(value=self.config_data.get(key, default))
            ttk.Entry(dialog, textvariable=values[key]).pack(fill='x', padx=18)
        def save():
            self.config_data.update({k: v.get().strip() for k, v in values.items()})
            self.invalidate()
            dialog.destroy()
        ttk.Button(dialog, text='保存规则', command=save).pack(pady=18)

    def collect(self):
        if not self.config_data:
            raise ValueError('请先输入网址并识别，或打开已保存的工程')
        if self.url.get().strip() != self.config_data['url']:
            raise ValueError('顶部网址已改变，请点“开始制作”重新检查该网站。')
        config = dict(self.config_data)
        if any(self.browser_actions.values()):
            config['browserActions'] = dict(self.browser_actions)
        else:
            config.pop('browserActions', None)
        config.update({k: v.get().strip() for k, v in self.fields.items()})
        config['contentCategory'] = {'影视':'movie', '成人':'adult', '待分类':'unclassified'}.get(self.content_category.get(), '')
        config = target_config(config, TARGETS[self.category.get()])
        if config['mode'] == 'maccms' and config['media'] == 'images':
            raise ValueError('视频接口无法作为漫画或图片源')
        generate(config)
        return config

    def analyze(self, auto_verify=False):
        self.detach_other_browser(self.url.get())
        if not self.browser and self.browser_engine.get() not in ('内置浏览器', '推荐浏览器（Edge）'):
            self.verify_in_browser(auto_verify=auto_verify)
            return
        url, category = self.url.get(), TARGETS[self.category.get()]
        def done(result):
            config, rows, message = result
            if self.browser and config['mode'] == 'html':
                config['useBrowser'] = self.browser.browser_mode
            self.load_config(config)
            self.show_rows(rows)
            self.note(message)
            if auto_verify:
                self.test_first()
        self.work(lambda: discover(url, category, self.active_fetcher()), done)

    def attempt(self, fn):
        try:
            fn()
        except Exception as e:
            messagebox.showerror('无法完成', str(e), parent=self)

    def preview(self):
        def start():
            c = self.collect()
            if c.get('useBrowser') and not self.browser:
                raise ValueError('该工程使用浏览器会话，请先点击“用浏览器重试”。')
            def run():
                f = self.active_fetcher()
                if c['mode'] == 'maccms':
                    sep = '&' if '?' in c['api'] else '?'
                    d = json.loads(f.get(c['api'] + sep + 'ac=detail&pg=1')[1])
                    return [{'id': str(v['vod_id']), 'title': v['vod_name'], 'cover': v.get('vod_pic', '')} for v in d.get('list', [])]
                from verifier import execute
                return execute(generate(c), 'LumeSource.list({page:1}).then(function(v){return v.items;})', f)
            self.work(run, self.show_rows)
        self.attempt(start)

    def test_first(self, allow_python=False):
        def start():
            c = self.collect()
            if not self.rows and c['target'] != 'web':
                raise ValueError('没有找到作品。请改填作品列表页，或用浏览器重试。')
            if c.get('useBrowser') and not self.browser:
                raise ValueError('请先连接所选引擎并完成验证恢复浏览器会话')
            from verifier import verify_with_fallback
            rows = list(self.rows)
            signature = self.fingerprint(c)
            retry_browser = self.browser_engine.get() == '推荐浏览器（Edge）'
            self.failed_config = c
            self.validated_signature = None
            self.refresh_export()
            def done(result):
                checked, report = result
                self.note(report)
                if self.fingerprint(self.collect()) == signature:
                    if checked != c:
                        self.load_config(checked)
                    self.prepare(show_preview=False)
                    signature_now = self.fingerprint(self.collect())
                    self.validated_signature = signature_now
                    self.refresh_export()
                    self.failed_config = None
                    self.python_btn.pack_forget()
                    extension = self.artifact[1]
                    self.status.set(f'检查通过 · {len(rows)} 个候选作品 · 可以保存 {extension} 源文件了。')
                    self.conversion_status.set('已抽样检查详情、选集和内容地址；导入 App 后可实际播放或阅读。')
            def run():
                fetcher = self.active_fetcher()
                try:
                    checked, report = verify_with_fallback(c, rows, fetcher, allow_python=allow_python)
                except ValueError as error:
                    if retry_browser and c['mode'] == 'html' and not c.get('useBrowser') and not allow_python:
                        import re
                        pages = list(getattr(fetcher, 'pages', {}).values())
                        if not pages and rows:
                            try:
                                pages = [fetcher.get(rows[0]['id'])[1]]
                            except ValueError:
                                pass
                        dynamic = any(re.search(r'<iframe\b|id\s*=\s*[\"\x27]kt_player|class\s*=\s*[\"\x27][^\"\x27]*\bplayer\b', page, re.I) for page in pages)
                        if dynamic or re.search(r'HTTP 403|NEED_WEBVIEW_VERIFY|人工验证|证书校验', str(error)):
                            raise BrowserRequired('静态页面未读到可用播放器，将在浏览器中继续验证：' + str(error), c['url']) from error
                    raise
                if self.adaptive_enabled and hasattr(fetcher, 'pages'):
                    try:
                        count = self.adaptive_store.learn(checked, rows, fetcher)
                        report += f'\nScrapling 已记住 {count} 组规则样本；将来重新识别时尝试适应改版，恢复后仍需验证。'
                    except Exception as error:
                        report += '\n解析验证通过，样本学习未完成：' + str(error)
                return checked, report
            self.work(run, done)
        self.attempt(start)

    def save_project(self):
        def save():
            c = self.collect()
            p = filedialog.asksaveasfilename(parent=self, title='保存制源工程', defaultextension='.json', initialfile=c['id'] + '.project.json', filetypes=[('制源工程', '*.json')])
            if p:
                Path(p).write_text(json.dumps(c, ensure_ascii=False, indent=2), encoding='utf-8')
                self.note('工程已保存：' + p)
        self.attempt(save)

    def open_project(self):
        def load():
            p = filedialog.askopenfilename(parent=self, filetypes=[('制源工程', '*.json')])
            if p:
                c = json.loads(Path(p).read_text(encoding='utf-8-sig'))
                generate(c)
                if c.get('target') in ('python', 'comic_python') and not messagebox.askyesno('打开 PY 工程？', '这个工程使用 PY。确定要打开并继续使用 PY 吗？', parent=self):
                    return
                self.load_config(c)
                self.show_rows([])
                self.note('工程已打开，请重新预览。')
        self.attempt(load)

    def export(self):
        def save():
            c = self.collect()
            if not self.artifact or self.artifact[0] != self.fingerprint(c):
                raise ValueError('请先点击“开始制作”，检查通过后再保存。')
            if self.validated_signature != self.artifact[0]:
                raise ValueError('该源尚未检查通过。请点“开始制作”重新检查。')
            _, extension, data, route = self.artifact
            self.output_dir.mkdir(parents=True, exist_ok=True)
            p = filedialog.asksaveasfilename(parent=self, title='导出到 LumeBox', initialdir=self.output_dir, initialfile=source_filename(c, extension), defaultextension=extension, filetypes=[('LumeBox 源文件', '*' + extension)])
            if p:
                Path(p).write_bytes(data)
                self.last_saved = Path(p)
                self.status.set('导出完成 · 可点击“制作下一个源”继续，无需关闭软件。')
                self.note('已导出：' + p)
                messagebox.showinfo('导出完成', '导入位置：' + route + '\n\n' + p, parent=self)
        self.attempt(save)


if __name__ == '__main__':
    import sys
    if len(sys.argv) == 4 and sys.argv[1] == '--https-check':
        from network_tls import trust_context
        from core import validate_url
        try:
            url = validate_url(sys.argv[2])
            if not url.startswith('https://'):
                raise ValueError('检查网址必须使用 HTTPS')
            final, html = Fetcher().get(url)
            report = {'ok': True, 'url': final, 'body_bytes': len(html.encode('utf-8')),
                'verified_tls': True, 'root_certificates': trust_context().cert_store_stats()['x509_ca']}
        except Exception as error:
            report = {'ok': False, 'error': str(error)}
        Path(sys.argv[3]).write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
        sys.exit(0 if report['ok'] else 1)
    if len(sys.argv) == 3 and sys.argv[1] == '--engine-check':
        from browser_check import browser_checks
        try:
            results = browser_checks(sys.argv[2])
        except Exception as error:
            results = {'self_check': {'ok': False, 'error': str(error)}}
            Path(sys.argv[2]).write_text(json.dumps(results, ensure_ascii=False), encoding='utf-8')
        sys.exit(0 if all(value['ok'] for value in results.values()) else 1)
    if '--scrapy-worker' in sys.argv:
        from batch_crawler import run_scrapy_worker
        run_scrapy_worker()
        sys.exit(0)
    if '--browser-worker' in sys.argv:
        from browser_session import run_worker
        run_worker()
        sys.exit(0)
    if len(sys.argv) == 3 and sys.argv[1] == '--self-test':
        from smoke import smoke
        sys.exit(0 if smoke(sys.argv[2]) else 1)
    if os.name == 'nt':
        import ctypes
        ctypes.windll.shcore.SetProcessDpiAwareness(1)
    App().mainloop()
