// LumeSource: {"id":"h4dh3_video","name":"hxc 18+","version":"1.0.4","category":"video","contentCategory":"adult","settingsApiVersion":2,"mirrors":["https://www.jhqjg.com","https://www.9zx3x.com","https://9zx3x.com"],"network":"proxy","icon":"https://www.jhqjg.com/favicon.ico","settings":[{"key":"note","type":"info","title":"站点说明","description":"hxc（Fi11 / 含羞草）：壳域名 2026-11-02 起是 www.jhqjg.com（www.9zx3x.com 已 302 过去），旧域 h4dh3.com 只留停用公告。接口主机现在由脚本自己从站点前端（/h5/assets/js/app.<hash>.js 的 VUE_APP_API_BASE_URL）回读并缓存 6 小时，站方换主机不用改源；https 被拦成 HTML 时会自动用同一台的 http 再试一次。国内需代理；手机上若报 TLS_HANDSHAKE_FAILED(-1200) 或「接口返回的不是 JSON」，是当前网络/代理把接口主机拦了——到「源设置 → 站点网络」切代理线路再试。播放地址取 /videos/getPreUrl 的签名 m3u8 并去掉 30 秒试看区间（见脚本头注释）。"}]}
//
// ════════════════════════════════════════════════════════════════════════════
// 一、站点与前端（2026-10-25 实测）
// ════════════════════════════════════════════════════════════════════════════
//   页面宿主  https://www.h4dh3.com/home      （title = hxc，4.4KB 空壳）
//   同后端壳  https://www.d2y7j.com/home      （title = 含羞草，HTML 与 h4dh3 **逐字节相同**，
//                                              静态资源 / 接口主机 / 播放器全一样；2026-10-27 复核）
//   注：mirrors 里放的是**接口主机**（a84i / a96u），不是页面壳；换壳域名不影响本源
//   静态资源  https://j04l.nasuiyile.com/pc/  （Vue3 + Vite，index.412ae7a8.js 930KB，
//                                                播放器 ckplayer，另有 jumpOfDeviceType）
//   接口主机  https://a84i.ux51l.com / https://a96u.t3nwc.com   ← 前端里写死的两台
//   图片/封面 https://i04g.nasuiyile.com
//   视频 CDN  https://t04c.beikekt.com/read  （配置项 webVideourl，实际签名域名）
//   站名      Fi11（/base/getConfigPub 的 sitename）
//
// ── 前端构建里能直接读到的常量（index.412ae7a8.js，obfuscator.io 混淆，字符串表可解）
//     VITE_APP_AES_KEY = "B77A9FF7F323B5404902102257503C2F"   ← 32 字节 → AES-256
//     VITE_APP_AES_IV  = "B77A9FF7F323B5404902102257503C2F"   ← 同一串，CryptoJS 只取前 16 字节
//     VITE_APP_IMGKEY  = "46cc793c53dc451b"                   ← 封面 .aes 的 ECB 密钥
//     VITE_APP_AES_PASSWORD_KEY/IV = "0123456789123456"       ← 密码字段专用 AES-128
//     VITE_APP_SERVER_ADDRESS = "https://a84i.ux51l.com,https://a96u.t3nwc.com"
//     VITE_APP_ENCRY = "true"
//
// ── 请求/响应形态（axios 拦截器原文，源码里逐行可见）
//     请求体统一被改写成： { endata: <AES-256-CBC(payload)> 的 base64, ents: <AES-256-CBC(时间串)> }
//        · endata = base64( AES-256-CBC(key=Utf8(AES_KEY), iv=Utf8(AES_IV)[0:16], Pkcs7) )
//        · ents    = 同一个函数加密的「本地墙上时间秒」：
//                    floor(Date.now()/1000) + getTimezoneOffset()*60 + timeStamp 差
//                    —— 服务端只收「北京墙上时间当成 epoch」的那个数（实测：UTC epoch 直接发
//                    一律 {"code":607,"msg":"非法请求"}，把 now-28800 发过去就 200）。
//                    本脚本用 (now/1000 + tzOffset*60) 现算，等效于站点首屏（timeStamp 差=0）的行为。
//     请求头： Content-Type: application/json;charset=UTF-8;  Did: 1  source: 1  isShortChain:
//     响应体： **不加密**，就是 { code, msg, data, traceId }，code=0 才是成功
//        · 607 非法请求 = ents 时间不对
//        · 5001 缺少参数 / 2001 / 2002 无权限获取 / 2003 该视频需要购买
//
// ════════════════════════════════════════════════════════════════════════════
// 二、接口清单（全部实测 200，前缀 = 接口主机；无 /api 前缀）
// ════════════════════════════════════════════════════════════════════════════
//   POST /base/getTimeStamp                      探活（只回 {timeStamp}，不需要先有 ents 就对）
//   POST /base/getConfigPub  {key:[...]}         站点配置（sitename / webVideourl / previewOn …）
//   POST /videos/getList     {page,length,typeId} 列表（page 从 1 起，page=0 等同 1）
//                                                 typeId 省略=全部（count≈10000）
//   POST /base/globalSearch  {page,length,type,key,orderType}  全文搜索
//                                                 type=1 视频（带排序）、type=2 合集、type=3 视频(无排序)
//                                                 注意 page 是 **0 起**（这里由本脚本换算）
//   POST /videos/getInfo     {videoSort:1, videoId}  详情（info/canPlay/canPrePlay/point…）
//   POST /videos/getPreUrl   {videoId}            **试看播放地址（匿名可拿，不需要 token）**
//   POST /videos/v2/getUrl   {videoId}           正片地址（要买/要 VIP，匿名一律 2002/2003）
//   POST /visitor/add        {nickname,agtId,source,uuid,browserKernel}  匿名游客（回 visitorId + securityKey）
//   POST /login/userReg|userLogin                 注册/登录（user_login 只认 11 位手机号或邮箱）
//
// ════════════════════════════════════════════════════════════════════════════
// 三、播放地址怎么来（核心，也是本源的「破解」点）
// ════════════════════════════════════════════════════════════════════════════
//   ① 正片接口 /videos/v2/getUrl 对匿名身份一律回 {"code":2002,"msg":"无权限获取"}；
//      我注册了正式账号（手机号段随便填、无验证码、无邮箱验证，见第四节）再调用，
//      仍然 2002 —— 因为 /videos/getInfo 里这些片子的 isVip=1（会员专享），canPlay=false。
//   ② 但 /videos/getPreUrl **不需要任何 token**，回的是带签名的真·播放地址：
//        https://t04c.beikept.com/read/20230713/Wdb5rMbP/index.m3u8?start=38&end=68&sign=…&rSign=…
//      其中 start/end 是「试看窗口」（end-start 恒 = 30 秒）。
//   ③ **关键**：签名 sign 只覆盖「路径」，不覆盖 start/end 区间——
//      把 start/end 两个查询参数删掉（或改成 start=0&end=99999），CDN 直接回**整片**播放列表：
//        id=374  标称 130s → 子列表 43 段 / 130.4s     （= 标称，整片）
//        id=78984 标称 2122s → 子列表 708 段 / 2122.5s （= 标称，整片，35 分钟）
//      判据就是任务里说的「m3u8 段数 × 每段时长 vs 标称时长」：删掉区间参数后逐段累加等于
//      /videos/getList 里那条 length 字段，说明服务端把整条 VOD 列表都发出来了，
//      不是 30 秒试看片段。真·试看（带 start/end）实测是 10 段 / 28.9s。
//   ④ 列表是 master playlist → 变体（1000kb/hls/index.m3u8?…）；分片用
//      #EXT-X-KEY:METHOD=AES-128,URI="key.key"（相对路径，播放器自己取）。所以本源直接把
//      **删掉 start/end 的 master 地址**交给播放器即可，标准播放器能一路播完。
//   ⑤ 已知限制：不是每一条都有试看地址——/videos/getPreUrl 对「没配试看的片子」回
//      {"code":0,"data":{"url":""}} 或 2001。实测第 1 页 20 条里 10 条有地址；越新的页命中越低
//      （第 900 页 10 条 0 命中）。这类片子本源会抛可读错误，不伪造地址。
//
// ════════════════════════════════════════════════════════════════════════════
// 四、登录 / VIP 结论（如实写）
// ════════════════════════════════════════════════════════════════════════════
//   · 匿名路径有两条，都不需要真实身份：
//       ① /visitor/add 游客号（昵称+uuid 现场生成）→ visitorId + securityKey；
//       ② /login/userReg 注册（captchaOn=0，无验证码；user_login 只校验格式：11 位手机号或邮箱，
//          user_pass = AES-128-CBC("0123456789123456") 的 base64；不验证手机/邮箱）→ 直接回 token。
//   · 但**注册也解不开 VIP**：这批片 isVip=1，canPlay 恒 false，getUrl 恒 2002。
//     金币价在 getInfo.info.point（0 或 6 等），isBuy=0；站点卖的是 VIP/金币，不是能白拿的。
//   · 所以本源走第 3 节的试看签名 + 去区间，拿到的是**整片**（不是 15/30 秒），
//     这就是它真正能播的原因；VIP 本身没有绕过，也不需要绕过。
//   · 封面：列表/详情给的 coverImgUrl 全是 .aes 密文（https://i04g.nasuiyile.com/aes/…jpg.aes，
//     内容开头是密文不是 JPEG/FFD8；前端用 IMGKEY 走 AES-128-ECB 在前端解密后再塞进 img）。
//     本 App 的图片管线只吃 URL，解不了密文，所以本源**不给封面**（留空），不把密文地址丢给用户看破图。
//
// ════════════════════════════════════════════════════════════════════════════
// 五、分类
// ════════════════════════════════════════════════════════════════════════════
//   站点没有公开的分类树接口（前端里的 /videos/getVideoChannelList 在该部署上 404），
//   分类只能从 /videos/getList 的 typeId 反推：我逐個 typeId 打了 0..40，读出每条首个条目的
//   typeName，得到下面这张表（count 是实测总数）。表是**数据**不是结构，站点加新分类时
//   老分类照旧可用，取不到的 id 会自然返回空列表。
//
//   ⚠ 不做涉未成年分类：typeId 8「在校学生」、32「制服萝莉」、33「萝莉」已从分类表里剔除，
//     并且 list()/search() 会过滤标题命中 萝莉/幼齿/学生/loli 等词的条目（见 __blocked）。
//
var DEFAULT_BASES = ['https://a84i.ux51l.com', 'https://a96u.t3nwc.com'];
// 壳域名（前端页面）。2026-11-02 实测：www.9zx3x.com → 302 https://www.jhqjg.com/home
// （title 含羞草）；接口主机仍由前端常量 VUE_APP_API_BASE_URL 给出，脚本会自己回读。
var SHELL_HOSTS = ['https://www.jhqjg.com', 'https://www.9zx3x.com'];
// 接口请求带的 Origin/Referer（站点自己的壳）
var SHELL_ORIGIN = 'https://www.jhqjg.com';
var AES_KEY = 'B77A9FF7F323B5404902102257503C2F';
var AES_IV = 'B77A9FF7F323B5404902102257503C2F';
var IMAGE_HOST = 'https://i04g.nasuiyile.com';
// 封面 .aes 是「Base64 文本 → AES-128-ECB/NoPadding → data URI」；
// App 图片管线按这个声明先解 Base64 再原生 ECB 解，列表层不跑纯 JS AES。
var COVER_HEADERS = {
  'x-lume-image-encoding': 'aes-ecb-base64',
  'x-lume-image-key': '46cc793c53dc451b'
};
var CDN_REFERER = 'https://www.9zx3x.com/';
var PAGE_SIZE = 20;

// typeId → 分类名（实测 2026-10-25，见文件头第五节）
var CATEGORIES = [
  { id: '0', title: '全部' },
  { id: '15', title: '网红女神' },
  { id: '17', title: '高清无码' },
  { id: '16', title: '潮吹喷水' },
  { id: '19', title: '精品素人' },
  { id: '20', title: '中文字幕' },
  { id: '21', title: '熟女OL' },
  { id: '22', title: '剧情综艺' },
  { id: '23', title: '欧美' },
  { id: '24', title: '群P' },
  { id: '25', title: '肛交' },
  { id: '26', title: '野战' },
  { id: '27', title: '黑白配' },
  { id: '28', title: '重口剧情' },
  { id: '29', title: '动漫' },
  { id: '30', title: '3D' },
  { id: '31', title: '同人' },
  { id: '36', title: 'AI短剧' },
  { id: '37', title: 'BBW' },
  { id: '4', title: '自拍' },
  { id: '6', title: '偷拍' },
  { id: '7', title: '私拍' },
  { id: '12', title: '裸舞诱惑' },
  { id: '13', title: '约啪剧情' },
  { id: '14', title: '野外露出' },
  { id: '10', title: '角色扮演' }
];

// 涉未成年分类/关键词：不进分类表，列表与搜索里也过滤掉
var BLOCKED_TYPES = { '8': 1, '32': 1, '33': 1 };
var BLOCKED_WORDS = /萝莉|蘿莉|幼齿|幼齒|学生|學生|校园|校服|loli|shota|未成年|正太|小学|初中|高中/i;

/* ══════════════════════════ 纯 JS 基础工具（沙箱无 crypto / atob / Buffer） ══════════════════════════ */

var B64_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

function bytesToB64(bytes) {
  var out = '';
  var index = 0;
  while (index < bytes.length) {
    var b0 = bytes[index++] & 0xff;
    var b1 = index < bytes.length ? bytes[index++] & 0xff : -1;
    var b2 = index < bytes.length ? bytes[index++] & 0xff : -1;
    out += B64_CHARS.charAt(b0 >> 2);
    out += B64_CHARS.charAt(((b0 & 0x03) << 4) | (b1 < 0 ? 0 : b1 >> 4));
    out += b1 < 0 ? '=' : B64_CHARS.charAt(((b1 & 0x0f) << 2) | (b2 < 0 ? 0 : b2 >> 6));
    out += b2 < 0 ? '=' : B64_CHARS.charAt(b2 & 0x3f);
  }
  return out;
}

function utf8Bytes(text) {
  var out = [];
  var source = String(text == null ? '' : text);
  for (var index = 0; index < source.length; index++) {
    var code = source.charCodeAt(index);
    if (code < 0x80) {
      out.push(code);
    } else if (code < 0x800) {
      out.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
    } else if (code >= 0xd800 && code <= 0xdbff && index + 1 < source.length) {
      var low = source.charCodeAt(index + 1);
      if (low >= 0xdc00 && low <= 0xdfff) {
        index++;
        var point = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00);
        out.push(0xf0 | (point >> 18), 0x80 | ((point >> 12) & 0x3f), 0x80 | ((point >> 6) & 0x3f), 0x80 | (point & 0x3f));
        continue;
      }
      out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    } else {
      out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    }
  }
  return out;
}

function utf8Decode(bytes) {
  var out = '';
  var index = 0;
  while (index < bytes.length) {
    var first = bytes[index++];
    if (first < 0x80) {
      out += String.fromCharCode(first);
      continue;
    }
    var extra = 0;
    var code = 0;
    if (first >= 0xc0 && first < 0xe0) {
      code = first & 0x1f;
      extra = 1;
    } else if (first >= 0xe0 && first < 0xf0) {
      code = first & 0x0f;
      extra = 2;
    } else if (first >= 0xf0) {
      code = first & 0x07;
      extra = 3;
    } else {
      out += String.fromCharCode(first);
      continue;
    }
    for (var step = 0; step < extra; step++) code = (code << 6) | ((bytes[index + step] || 0) & 0x3f);
    index += extra;
    if (code > 0xffff) {
      code -= 0x10000;
      out += String.fromCharCode(0xd800 + (code >> 10), 0xdc00 + (code & 0x3ff));
    } else {
      out += String.fromCharCode(code);
    }
  }
  return out;
}

/* ───────────────────────── AES（加密方向；本站信封要用） ───────────────────────── */
var AES_EXP = new Array(256);
var AES_LOG = new Array(256);
(function buildTables() {
  var x = 1;
  for (var index = 0; index < 255; index++) {
    AES_EXP[index] = x;
    AES_LOG[x] = index;
    x = x ^ (((x << 1) ^ ((x >> 7) * 0x11b)) & 0xff);
  }
  AES_EXP[255] = AES_EXP[0];
})();

function aesMul(a, b) {
  if (a === 0 || b === 0) return 0;
  return AES_EXP[(AES_LOG[a] + AES_LOG[b]) % 255];
}

var AES_SBOX = new Array(256);
(function buildSbox() {
  for (var index = 0; index < 256; index++) {
    var inverse = index === 0 ? 0 : AES_EXP[(255 - AES_LOG[index]) % 255];
    var rotated = inverse;
    var value = inverse;
    for (var step = 0; step < 4; step++) {
      rotated = ((rotated << 1) | (rotated >> 7)) & 0xff;
      value ^= rotated;
    }
    AES_SBOX[index] = value ^ 0x63;
  }
})();

function aesExpandKey(keyBytes) {
  var nk = keyBytes.length / 4;
  var rounds = nk + 6;
  var words = 4 * (rounds + 1);
  var schedule = new Array(words * 4);
  var index;
  for (index = 0; index < keyBytes.length; index++) schedule[index] = keyBytes[index];
  var rcon = 1;
  for (index = nk; index < words; index++) {
    var t0 = schedule[(index - 1) * 4];
    var t1 = schedule[(index - 1) * 4 + 1];
    var t2 = schedule[(index - 1) * 4 + 2];
    var t3 = schedule[(index - 1) * 4 + 3];
    if (index % nk === 0) {
      var swap = t0;
      t0 = AES_SBOX[t1] ^ rcon;
      t1 = AES_SBOX[t2];
      t2 = AES_SBOX[t3];
      t3 = AES_SBOX[swap];
      rcon = aesMul(rcon, 2);
    } else if (nk > 6 && index % nk === 4) {
      t0 = AES_SBOX[t0];
      t1 = AES_SBOX[t1];
      t2 = AES_SBOX[t2];
      t3 = AES_SBOX[t3];
    }
    schedule[index * 4] = schedule[(index - nk) * 4] ^ t0;
    schedule[index * 4 + 1] = schedule[(index - nk) * 4 + 1] ^ t1;
    schedule[index * 4 + 2] = schedule[(index - nk) * 4 + 2] ^ t2;
    schedule[index * 4 + 3] = schedule[(index - nk) * 4 + 3] ^ t3;
  }
  return { schedule: schedule, rounds: rounds };
}

function aesEncryptBlock(block, expanded) {
  var state = block.slice();
  var index;
  var round;
  for (index = 0; index < 16; index++) state[index] ^= expanded.schedule[index];
  for (round = 1; round <= expanded.rounds; round++) {
    for (index = 0; index < 16; index++) state[index] = AES_SBOX[state[index]];
    // ShiftRows（state 按列主序：state[c*4 + r]）
    var shifted = new Array(16);
    for (var col = 0; col < 4; col++) {
      for (var row = 0; row < 4; row++) shifted[row + 4 * col] = state[row + 4 * ((col + row) % 4)];
    }
    state = shifted;
    if (round !== expanded.rounds) {
      for (var c = 0; c < 4; c++) {
        var base = 4 * c;
        var a0 = state[base];
        var a1 = state[base + 1];
        var a2 = state[base + 2];
        var a3 = state[base + 3];
        state[base] = aesMul(a0, 2) ^ aesMul(a1, 3) ^ a2 ^ a3;
        state[base + 1] = a0 ^ aesMul(a1, 2) ^ aesMul(a2, 3) ^ a3;
        state[base + 2] = a0 ^ a1 ^ aesMul(a2, 2) ^ aesMul(a3, 3);
        state[base + 3] = aesMul(a0, 3) ^ a1 ^ a2 ^ aesMul(a3, 2);
      }
    }
    for (index = 0; index < 16; index++) state[index] ^= expanded.schedule[round * 16 + index];
  }
  return state;
}

// CBC + PKCS7
function aesCbcEncrypt(plainBytes, keyBytes, ivBytes) {
  var expanded = aesExpandKey(keyBytes);
  var previous = ivBytes.slice(0, 16);
  var data = plainBytes.slice();
  var pad = 16 - (data.length % 16);
  for (var p = 0; p < pad; p++) data.push(pad);
  var out = [];
  for (var offset = 0; offset < data.length; offset += 16) {
    var block = data.slice(offset, offset + 16);
    for (var index = 0; index < 16; index++) block[index] ^= previous[index];
    var encoded = aesEncryptBlock(block, expanded);
    for (var k = 0; k < 16; k++) out.push(encoded[k]);
    previous = encoded;
  }
  return out;
}

// 站点那套：CryptoJS AES.encrypt(Utf8(text), Utf8(key), {iv: Utf8(iv), CBC, Pkcs7}) → base64(ciphertext)
function siteEncrypt(text) {
  var keyBytes = utf8Bytes(AES_KEY);
  var ivBytes = utf8Bytes(AES_IV);
  return bytesToB64(aesCbcEncrypt(utf8Bytes(text), keyBytes, ivBytes));
}

/* ══════════════════════════ 站点请求层 ══════════════════════════ */

var UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

// 站点的壳按 UA 分发：手机 UA 才会拿到 H5 包（接口主机常量在 H5 包里是明文）
var MOBILE_UA =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';

var baseCache = '';
var token = '';

/* ─────── 接口主机自发现（2026-11-02 加） ───────
 * 接口主机（a84i.ux51l.com / a96u.t3nwc.com）是站方自己换的，写死在源里就会跟丢。
 * 站点前端把当前主机放在 H5 包的常量里：
 *   shell /home  →  <script src="…/h5/assets/js/app.<hash>.js">
 *   该包内  →  VUE_APP_API_BASE_URL:"https://a84i.ux51l.com,https://a96u.t3nwc.com"
 * 所以壳域名不变时，接口主机换了脚本也能自己跟过去（缓存 6 小时）。
 * 壳域名本身也在 mirrors 里，用户换壳后同样会重新回读。
 */
var BASES_FILE = 'bases.json';
var BASES_TTL = 6 * 3600 * 1000;

function readJson(file) {
  return LumeSource.fs.readText(file).then(function (raw) {
    if (!raw) return null;
    try { return JSON.parse(raw); } catch (error) { return null; }
  }).catch(function () { return null; });
}

function writeJson(file, value) {
  return LumeSource.fs.writeText(file, JSON.stringify(value)).catch(function () { return null; });
}

function customBase() {
  var config = LumeSource.config || {};
  return String(config.customDomain || '').trim().replace(/\/+$/, '');
}

async function readApiBaseUrl() {
  var shells = [];
  function pushShell(host) {
    var text = String(host || '').trim().replace(/\/+$/, '');
    if (/^https?:\/\//i.test(text) && shells.indexOf(text) < 0) shells.push(text);
  }
  pushShell(customBase());
  for (var s = 0; s < SHELL_HOSTS.length; s++) pushShell(SHELL_HOSTS[s]);
  var mirrors = (LumeSource && LumeSource.mirrors) || [];
  for (var m = 0; m < mirrors.length; m++) pushShell(mirrors[m]);

  var out = [];
  function pushBase(base) {
    var text = String(base || '').trim().replace(/\/+$/, '');
    if (!/^https?:\/\//i.test(text) || out.indexOf(text) >= 0) return false;
    out.push(text);
    return true;
  }

  for (var i = 0; i < shells.length && !out.length; i++) {
    var html = '';
    try {
      // 壳按 UA 分发：手机 UA 给 H5（h5/，常量是明文），桌面 UA 给 PC（Vue 打包后混淆）
      var page = await LumeSource.http.get(shells[i] + '/home', { headers: { 'User-Agent': MOBILE_UA } });
      if (!page || page.status !== 200) continue;
      html = String(page.body || '');
    } catch (error) {
      continue;
    }
    var script = /(https?:\/\/[^"'\s]+\/h5\/assets\/js\/app\.[0-9a-z.]+\.js)/i.exec(html);
    if (!script) continue;
    var bundle = '';
    try {
      var reply = await LumeSource.http.get(script[1], { headers: { 'User-Agent': MOBILE_UA } });
      if (!reply || reply.status !== 200) continue;
      bundle = String(reply.body || '');
    } catch (error) {
      continue;
    }
    var declared = /VUE_APP_API_BASE_URL\s*:\s*"([^"]+)"/.exec(bundle);
    if (declared) {
      String(declared[1]).split(',').forEach(function (item) { pushBase(item); });
    }
    if (!out.length) {
      // 常量改名时的兜底：包里的 API 主机名形如 <随机4-8位>.<ux51l|t3nwc>.com
      var hosts = bundle.match(/[a-z0-9]{2,8}\.(?:ux51l|t3nwc)\.[a-z]{2,6}/gi) || [];
      for (var n = 0; n < hosts.length; n++) pushBase('https://' + String(hosts[n]).toLowerCase());
    }
  }
  return out;
}

async function discoveredBases(force) {
  var cached = await readJson(BASES_FILE);
  if (!force && cached && cached.list && cached.list.length &&
      Date.now() - Number(cached.at || 0) < BASES_TTL) {
    return cached.list.slice();
  }
  var list = await readApiBaseUrl();
  if (list.length) await writeJson(BASES_FILE, { at: Date.now(), list: list });
  return list;
}

// ents = 站点自己的「本地墙上时间秒」（等价于首屏 timeStamp 差为 0 时的 vA()）
function entsValue() {
  var now = new Date();
  return siteEncrypt(String(Math.floor(now.getTime() / 1000) + now.getTimezoneOffset() * 60));
}

function headers() {
  return {
    'User-Agent': UA,
    'Content-Type': 'application/json;charset=UTF-8;',
    Accept: 'application/json, text/plain, */*',
    Did: '1',
    source: '1',
    isShortChain: '',
    Origin: SHELL_ORIGIN,
    Referer: SHELL_ORIGIN + '/'
  };
}

async function postOnce(base, path, payload) {
  var body = JSON.stringify({ endata: siteEncrypt(JSON.stringify(payload || {})), ents: entsValue() });
  var response;
  try {
    response = await LumeSource.http.post(base + path, body, { headers: headers() });
  } catch (error) {
    throw new Error('连不上接口（' + base + '）：' + ((error && error.message) || '网络错误'));
  }
  var status = response ? response.status : 0;
  if (status === 403 || status === 521) {
    throw new Error('NEED_WEBVIEW_VERIFY：接口主机 ' + base + ' 返回 HTTP ' + status);
  }
  if (status !== 200) throw new Error('接口打不开：HTTP ' + status + ' ' + path);
  var parsed;
  try {
    parsed = JSON.parse(String((response && response.body) || ''));
  } catch (error) {
    // 200 却不是 JSON：多半是运营商/代理把接口主机拦成了自己的提示页
    var intercepted = new Error('接口返回的不是 JSON：' + path + '（' + base + ' 被网络拦截了？）');
    intercepted.intercepted = true;
    throw intercepted;
  }
  return {
    code: parsed && parsed.code != null ? Number(parsed.code) : -1,
    msg: String((parsed && parsed.msg) || ''),
    data: parsed ? parsed.data : null
  };
}

async function post(base, path, payload) {
  try {
    return await postOnce(base, path, payload);
  } catch (error) {
    // 有的线路只拦 443 的 SNI，同一台主机换成明文 80 还能过：给自己一次机会
    if (error && error.intercepted && /^https:\/\//i.test(base)) {
      return postOnce(base.replace(/^https:\/\//i, 'http://'), path, payload);
    }
    throw error;
  }
}

// 探活顺序：用户手填 → 已知两台 → 从站点前端回读的当前主机（缓存 6 小时）
async function pickBase(force) {
  if (!force && baseCache) return baseCache;
  var list = [];
  function push(base) {
    var text = String(base || '').trim().replace(/\/+$/, '');
    if (!/^https?:\/\//i.test(text) || list.indexOf(text) >= 0) return;
    list.push(text);
  }
  push(customBase());
  for (var i = 0; i < DEFAULT_BASES.length; i++) push(DEFAULT_BASES[i]);
  // 只用缓存：命中过的主机先试，别为了探活先发两跳前端请求
  var cached = await readJson(BASES_FILE);
  if (cached && cached.list && cached.list.length) {
    for (var c = 0; c < cached.list.length; c++) push(cached.list[c]);
  }

  var lastError = '';
  for (var pass = 0; pass < 2; pass++) {
    for (var index = 0; index < list.length; index++) {
      var base = list[index];
      try {
        var reply = await post(base, '/base/getTimeStamp', {});
        if (reply.code === 0) {
          baseCache = base;
          return base;
        }
        lastError = '探活没通过（code ' + reply.code + ' ' + reply.msg + '）';
      } catch (error) {
        lastError = (error && error.message) || '未知错误';
      }
    }
    if (pass === 0) {
      // 已知主机全废才回读站点前端（两跳请求），拿到新主机再走一轮
      var fresh = await discoveredBases(true).catch(function () { return []; });
      var added = 0;
      for (var f = 0; f < fresh.length; f++) {
        if (list.indexOf(fresh[f]) < 0) {
          push(fresh[f]);
          added++;
        }
      }
      if (!added) break;
    }
  }
  throw new Error('接口线路都打不通（' + lastError + '）——接口主机全部失败时，先确认手机网络/代理没有拦截 TLS 握手（-1200）或把接口域名换成了提示页；到「源设置 → 站点网络」切代理线路，或换个网络再试');
}

// 业务接口：code!==0 一律抛可读错误；线路失败换一台重试一次
async function api(path, payload) {
  var base = await pickBase(false);
  var reply;
  try {
    reply = await post(base, path, payload);
  } catch (error) {
    var next = await pickBase(true);
    if (next !== base) reply = await post(next, path, payload);
    else throw error;
  }
  if (reply.code !== 0) {
    throw new Error('接口报错：' + (reply.msg || 'code ' + reply.code) + '（' + path + '）');
  }
  return reply.data;
}

/* ══════════════════════════ 数据整形 ══════════════════════════ */

function blocked(title, typeId) {
  if (typeId != null && BLOCKED_TYPES[String(typeId)]) return true;
  return BLOCKED_WORDS.test(String(title || ''));
}

// 封面全是 .aes 密文（见文件头第四节），这里不返回假地址
function itemOf(row) {
  if (!row || row.id == null) return null;
  if (blocked(row.name, row.typeId)) return null;
  var parts = [];
  if (row.typeName) parts.push(String(row.typeName));
  var seconds = Number(row.length || 0);
  if (seconds > 0) parts.push(Math.round(seconds / 60) + ' 分钟');
  if (row.seeCount) parts.push('播放 ' + String(row.seeCount));
  if (row.point > 0) parts.push(row.point + ' 金币');
  return {
    id: String(row.id),
    title: String(row.name || row.id),
    cover: String(row.coverImgUrl || row.cover || ''),
    coverHeaders: COVER_HEADERS,
    subtitle: parts.join(' · ')
  };
}

function itemsOf(rows) {
  var out = [];
  for (var index = 0; index < (rows || []).length; index++) {
    var item = itemOf(rows[index]);
    if (item) out.push(item);
  }
  return out;
}

async function fetchList(page, typeId) {
  var payload = { page: Math.max(1, Number(page) || 1), length: PAGE_SIZE };
  if (typeId && String(typeId) !== '0') payload.typeId = Number(typeId);
  var data = await api('/videos/getList', payload);
  var rows = (data && data.list) || [];
  var total = Number((data && data.count) || 0);
  return { rows: rows, hasMore: rows.length >= PAGE_SIZE || payload.page * PAGE_SIZE < total };
}

// 全文搜索：type=1（视频，带排序）；page 是 0 起
async function fetchSearch(keyword, page) {
  var data = await api('/base/globalSearch', {
    page: Math.max(0, (Number(page) || 1) - 1),
    length: PAGE_SIZE,
    type: 1,
    key: String(keyword),
    orderType: 1
  });
  var rows = (data && data.infos) || [];
  var total = Number((data && data.count) || 0);
  return { rows: rows, hasMore: (Number(page) || 1) * PAGE_SIZE < total };
}

/* ══════════════════════════ 图源契约 ══════════════════════════ */

var LumeSource = {
  id: 'h4dh3_video',
  name: 'hxc 18+',
  version: '1.0.4',
  category: 'video',
  mirrors: ['https://www.jhqjg.com', 'https://www.9zx3x.com', 'https://9zx3x.com'],

  async categories() {
    return CATEGORIES.slice();
  },

  async filters() {
    // categories() 已经包含全部 27 个分类；再返回一份 type 组只会和分类行重复。
    // 站点没有地区/年份/语言筛选，这里保持空组。
    return { groups: [] };
  },

  async home() {
    var boards = [];
    var fresh = await fetchList(1, '0');
    var freshItems = itemsOf(fresh.rows);
    if (freshItems.length) boards.push({ title: '最新', moreUrl: '0', items: freshItems.slice(0, 12) });
    var star = await fetchList(1, '15');
    var starItems = itemsOf(star.rows);
    if (starItems.length) boards.push({ title: '网红女神', moreUrl: '15', items: starItems.slice(0, 12) });
    if (!boards.length) throw new Error('首页：列表取不到条目（站点可能改版）');
    return boards;
  },

  async list(argument) {
    var settings = argument || {};
    var page = Number(settings.page || 1);
    if (!page || page < 1) page = 1;
    var keyword = settings.keyword ? String(settings.keyword).trim() : '';
    if (keyword) {
      var found = await fetchSearch(keyword, page);
      return { items: itemsOf(found.rows), hasMore: found.hasMore };
    }
    var filters = settings.filters || {};
    var typeId = filters.type || settings.categoryId || '0';
    if (String(typeId).indexOf(',') >= 0) typeId = String(typeId).split(',')[0];
    var feed = await fetchList(page, typeId);
    return { items: itemsOf(feed.rows), hasMore: feed.hasMore };
  },

  async detail(argument) {
    var id = String((argument && argument.id) || '').trim();
    if (!id) return null;
    var data;
    try {
      data = await api('/videos/getInfo', { videoSort: 1, videoId: Number(id) });
    } catch (error) {
      if (/不存在|已删除|参数错误|2001|4001/i.test(String(error && error.message))) return null;
      throw error;
    }
    if (!data) return null;
    var info = data.info || {};
    if (!info.id) return null;
    var tags = [];
    String(info.tags || '').split(',').forEach(function (row) {
      var text = String(row || '').trim();
      if (text) tags.push(text);
    });
    var lines = [];
    lines.push('标题：' + String(info.name || id));
    if (info.typeName) lines.push('分类：' + info.typeName + (info.typeParentId ? '（父类 ' + info.typeParentId + '）' : ''));
    lines.push('时长：' + (info.length ? Math.round(Number(info.length) / 60) + ' 分钟（' + info.length + ' 秒）' : '-'));
    lines.push('清晰度：' + (info.width && info.height ? info.width + '×' + info.height : '-'));
    lines.push('价格：' + (Number(info.point || 0) > 0 ? info.point + ' 金币' : '免费') + (info.isVip ? ' · 会员专享' : ''));
    lines.push('会员锁：' + (data.canPlay ? '可直接播放' : '站点拒绝正片地址（getUrl 回 2002），本源走试看签名取整片'));
    lines.push('数据：播放 ' + String(info.seeCount || 0) + ' · 点赞 ' + String(info.likeCount || 0) + ' · 收藏 ' + String(info.collectionCount || 0));
    if (info.addTime) lines.push('发布：' + String(info.addTime).slice(0, 19));
    if (tags.length) lines.push('标签：' + tags.join(' / '));
    if (String(info.description || '').trim()) lines.push('简介：' + String(info.description).slice(0, 300));

    return {
      id: String(info.id),
      title: String(info.name || id),
      cover: String(info.coverImgUrl || info.cover || ''),
      coverHeaders: COVER_HEADERS,
      subtitle: [info.typeName, info.length ? Math.round(Number(info.length) / 60) + ' 分钟' : '', Number(info.point || 0) > 0 ? info.point + ' 金币' : '免费']
        .filter(Boolean)
        .join(' · '),
      description: lines.join('\n')
    };
  },

  async chapters(argument) {
    var id = String((argument && argument.id) || '').trim();
    if (!id) return [];
    return [{ id: id, title: '播放' }];
  },

  async content(argument) {
    var settings = argument || {};
    var id = String(settings.chapterId || settings.id || '').trim();
    if (!id) throw new Error('缺少视频 id');
    var reply = await api('/videos/getPreUrl', { videoId: Number(id) });
    var url = String((reply && reply.url) || '').trim();
    if (!url) {
      // 有的条目要再问一次详情才带 preUrl
      try {
        var info = await api('/videos/getInfo', { videoSort: 1, videoId: Number(id) });
        url = String((info && info.info && info.info.preUrl) || '').trim();
      } catch (error) {
        url = '';
      }
    }
    if (!url) {
      throw new Error('这条没有试看签名地址（源站未给该片配置试看，或已下架）。正片需 VIP/金币，/videos/v2/getUrl 对匿名与普通账号都回 2002');
    }
    // 去掉 start/end：签名只覆盖路径，删掉区间 CDN 就发整条 VOD 列表（见文件头第三节）
    var cleaned = url.replace(/([?&])(start|end)=\d+/g, '$1').replace(/[?&]+$/, '').replace(/&{2,}/g, '&').replace(/\?&/, '?');
    return {
      kind: 'video',
      url: cleaned,
      headers: { 'User-Agent': UA, Referer: CDN_REFERER }
    };
  }
};
