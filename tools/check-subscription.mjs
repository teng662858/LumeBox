// 订阅端到端复验：从【线上订阅清单】拉，落到临时目录，再跑一遍五个入口。
// 这一步是把「仓库推上去了」变成「订阅真能用」的验收。
//
// 用法：
//   node tools/check-subscription.mjs
//   node tools/check-subscription.mjs --manifest https://raw.githubusercontent.com/teng662858/LumeBox-Sources/main/subscriptions/videos.txt
//   node tools/check-subscription.mjs --manifest https://<自建线路>/subscriptions/all.json
//   node tools/check-subscription.mjs --list-only        # 只校验清单与文件完整性，不跑入口
//
// 清单可以是纯文本（一行一个脚本地址），也可以是总订阅 JSON（lume.total-subscription，
// 与 App 的 _totalUrls 同口径）；总订阅里的分清单会被展开一层。
// 说明：欧乐 / 华视两个站直连会被 WAF 拦（403），这里按已知情况自动挂代理；
// 代理地址可用 LUME_PROXY 覆盖（默认 http://127.0.0.1:7890）。
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';

const run = promisify(execFile);
const PROXY = process.env.LUME_PROXY || 'http://127.0.0.1:7890';
const DEFAULT_MANIFEST =
  'https://raw.githubusercontent.com/teng662858/LumeBox-Sources/main/subscriptions/videos.txt';

// 需要挂代理的源 id（用 App 同款 Dart 栈实测得出，见 tools/site_reachability.dart）
const NEED_PROXY = new Set(['olehdtv', 'huavod', 'hentai2w']);

// 每个源用来验搜索的关键词（挑站上真实存在的片名）。
const KEYWORDS = {
  'ysxq-boju': '庆余年',
  a123tv: '寒战',
  fdzys: '九门',
  duanju2: '儿媳',
  olehdtv: '空枪',
  huavod: '希望',
  hentai2w: 'princess',
};

const argv = process.argv.slice(2);
const manifest = argv.indexOf('--manifest') >= 0 ? argv[argv.indexOf('--manifest') + 1] : DEFAULT_MANIFEST;
const listOnly = argv.includes('--list-only');

const UA =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

async function fetchText(url) {
  const res = await fetch(url, { headers: { 'User-Agent': UA }, signal: AbortSignal.timeout(30000) });
  if (!res.ok) throw new Error(`HTTP ${res.status} ${url}`);
  // 只读一次 body（读完 text 再读 arrayBuffer 会报 Body is unusable）。
  const bytes = Buffer.from(await res.arrayBuffer());
  return { text: bytes.toString('utf8'), bytes };
}

// 清单解析口径与 App 的 SourceSubscription.urlsIn 一致：一行一个地址，# / // 开头是注释。
function urlsIn(text) {
  const urls = [];
  for (const raw of text.split('\n')) {
    const line = raw.trim();
    if (!line || line.startsWith('#') || line.startsWith('//')) continue;
    if (!/^https?:\/\//i.test(line)) continue;
    urls.push(line);
  }
  return urls;
}

// 总订阅 JSON：与 App 的 _totalUrls 同口径（只认 comic / video，条目可以是字符串或 {url,enabled}）。
function totalUrls(text) {
  const clean = text.replace(/^\uFEFF/, '').trim();
  if (!clean.startsWith('{')) return null;
  let data;
  try {
    data = JSON.parse(clean);
  } catch (_) {
    return null;
  }
  if (!data || data.format !== 'lume.total-subscription') return null;
  const sections = data.sections;
  if (data.version !== 1 || !sections || typeof sections !== 'object' || Array.isArray(sections)) {
    throw new Error('总订阅格式错误（version/sections）');
  }
  const urls = [];
  for (const [key, entries] of Object.entries(sections)) {
    if (key === 'novel') continue;
    if (!['comic', 'video'].includes(key)) throw new Error(`总订阅包含未知板块：${key}`);
    if (!Array.isArray(entries)) throw new Error(`总订阅板块 ${key} 不是数组`);
    for (const raw of entries) {
      if (raw && typeof raw === 'object' && raw.enabled === false) continue;
      const url = typeof raw === 'string' ? raw : raw && typeof raw === 'object' ? raw.url : null;
      if (typeof url !== 'string' || !/^https?:\/\//i.test(url)) {
        throw new Error(`总订阅板块 ${key} 含无效地址：${JSON.stringify(raw)}`);
      }
      urls.push(url);
    }
  }
  return urls;
}

// 拉一份清单：总订阅 JSON 展开一层到分清单，分清单再取脚本地址。
async function resolveManifest(url, depth = 0) {
  if (depth > 2) throw new Error(`清单嵌套过深：${url}`);
  const { text, bytes } = await fetchText(url);
  const nested = totalUrls(text);
  if (nested) {
    const scripts = [];
    const manifests = [];
    let total = bytes;
    for (const entry of nested) {
      const resolved = await resolveManifest(entry, depth + 1);
      manifests.push(entry);
      scripts.push(...resolved.urls);
      total += resolved.bytes;
    }
    return { urls: scripts, manifests, bytes: total };
  }
  const scripts = urlsIn(text);
  if (!scripts.length) throw new Error(`清单里没有可用地址：${url}`);
  return { urls: scripts, manifests: [], bytes };
}

function identityOf(script) {
  const match = /^\s*(?:\/\/|#)\s*LumeSource:\s*(\{[^\n]+\})\s*$/m.exec(script);
  if (!match) return { id: '', name: '', category: '' };
  try {
    const data = JSON.parse(match[1]);
    return { id: data.id ?? '', name: data.name ?? '', category: data.category ?? '', mirrors: data.mirrors ?? [],
      runtime: /^\s*#\s*LumeRuntime:\s*python\s*$/m.test(script) ? 'python' : 'javascript' };
  } catch (_) {
    return { id: '', name: '', category: '' };
  }
}

console.log(`订阅清单：${manifest}`);
const resolved = await resolveManifest(manifest);
const urls = [...new Set(resolved.urls)];
for (const entry of resolved.manifests) console.log(`  分清单：${entry}`);
console.log(`清单里 ${urls.length} 条地址（${resolved.bytes.length} 字节）\n`);

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lume-sub-'));
const rows = [];
// 总订阅会把漫画/图源/听书/影视并在一次检查里，不能一律要求 video。
// 也不按目录硬卡：仓库里听书脚本的头部写的是 video，分类以清单所在板块为准。
const VALID_CATEGORIES = new Set(['video', 'movie', 'comic', 'photo', 'audiobook']);

for (const url of urls) {
  const file = path.join(dir, decodeURIComponent(new URL(url).pathname).split('/').pop() || 'source.js');
  try {
    const { bytes, text } = await fetchText(url);
    fs.writeFileSync(file, bytes);
    const identity = identityOf(text);
    rows.push({
      url,
      file,
      bytes: bytes.length,
      md5: crypto.createHash('md5').update(bytes).digest('hex').slice(0, 8),
      identity,
      problems: [
        identity.id ? '' : '缺少身份头',
        VALID_CATEGORIES.has(identity.category) ? '' : `category 非法：${identity.category}`,
        /[^\w-]/.test(identity.id || '-') ? 'id 含非法字符' : '',
        text.includes('LumeSource') ? '' : '正文没有 LumeSource',
      ].filter(Boolean),
    });
  } catch (error) {
    rows.push({ url, file: '', bytes: 0, md5: '', identity: { id: '', name: '' }, problems: [error.message] });
  }
}

const pad = (text, width) => {
  const value = String(text ?? '');
  return value + ' '.repeat(Math.max(0, width - [...value].length));
};
console.log(pad('源 id', 14) + pad('名称', 20) + pad('字节', 8) + pad('md5', 10) + '完整性问题');
for (const row of rows) {
  console.log(
    pad(row.identity.id || '-', 14) +
      pad(row.identity.name || '-', 20) +
      pad(row.bytes, 8) +
      pad(row.md5, 10) +
      (row.problems.length ? row.problems.join('；') : 'ok'),
  );
}

const broken = rows.filter((row) => row.problems.length);
if (listOnly) {
  console.log(`\n清单/完整性：${rows.length - broken.length}/${rows.length} 正常${broken.length ? '，有问题的见上' : ''}`);
  process.exit(broken.length ? 1 : 0);
}

console.log('\n—— 用跑测器验证五个入口（真实访问源站）——');
const results = [];
for (const row of rows) {
  if (!row.file) {
    results.push({ id: row.identity.id || row.url, verdict: 'SKIP' });
    continue;
  }
  const env = { ...process.env, NODE_USE_ENV_PROXY: '1' };
  if (NEED_PROXY.has(row.identity.id)) {
    env.HTTPS_PROXY = PROXY;
    env.HTTP_PROXY = PROXY;
  } else {
    delete env.HTTPS_PROXY;
    delete env.HTTP_PROXY;
  }
  let report = { ok: false, calls: {} };
  const python = row.identity.runtime === 'python';
  const args = [python ? 'tools/lume-python-source-check.py' : 'tools/lume-source-check.mjs', row.file, '--json'];
  const keyword = KEYWORDS[row.identity.id];
  if (keyword) args.push('--keyword', keyword);
  try {
    const { stdout } = await run(python ? (process.env.LUME_PYTHON || 'python') : process.execPath, args, {
      env,
      maxBuffer: 32 * 1024 * 1024,
    });
    report = JSON.parse(stdout)[0];
  } catch (error) {
    try {
      report = JSON.parse(error.stdout ?? '')[0];
    } catch (_) {
      report = { ok: false, calls: { run: { ok: false, error: error.message } } };
    }
  }
  const calls = report.calls ?? {};
  const playable = calls.playable
    ? calls.playable.ok
      ? calls.playable.probe && !calls.playable.probe.ok
        ? 'FAIL(地址不可播)'
        : 'ok'
      : 'FAIL'
    : 'n/a';
  results.push({
    id: row.identity.id || row.url,
    proxy: NEED_PROXY.has(row.identity.id) ? 'yes' : 'no',
    verdict: report.ok ? 'PASS' : 'FAIL',
    categories: calls.categories?.count ?? '-',
    items: calls.list?.count ?? '-',
    search: calls.search ? calls.search.count : '-',
    detail: calls.detail?.ok === false ? 'FAIL' : calls.detail?.title ? 'ok' : '-',
    chapters: calls.chapters?.count ?? '-',
    content: `${calls.content?.kind ?? '-'} ${playable}`,
  });
}

console.log('\n' + pad('源 id', 14) + pad('代理', 6) + pad('结论', 7) + pad('分类', 8) + pad('条目', 7) + pad('搜索', 7) + pad('详情', 7) + pad('章节', 7) + '播放');
for (const row of results) {
  console.log(
    pad(row.id, 14) +
      pad(row.proxy, 6) +
      pad(row.verdict, 7) +
      pad(row.categories, 8) +
      pad(row.items, 7) +
      pad(row.search, 7) +
      pad(row.detail, 7) +
      pad(row.chapters, 7) +
      row.content,
  );
}
const failed = results.filter((row) => row.verdict !== 'PASS');
console.log(`\n订阅端到端：${results.length - failed.length}/${results.length} 通过${failed.length ? '，失败见上' : ''}`);
fs.rmSync(dir, { recursive: true, force: true });
process.exit(failed.length || broken.length ? 1 : 0);
