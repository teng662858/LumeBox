// LumeSource: {"id":"ciyuanji_novel","name":"次元姬","version":"1.0.0","category":"comic","contentCategory":"adult","mediaType":"novel","settingsApiVersion":2,"requiresSettings":["settingsActions"],"mirrors":["https://www.ciyuanji.com"],"network":"direct","icon":"https://www.ciyuanji.com/favicon.ico","settings":[{"key":"note","type":"info","title":"站点说明","description":"次元姬（www.ciyuanji.com，Next.js SSR 的成人轻小说站）。所有页面都是服务端渲染，数据在 __NEXT_DATA__ 里，用桌面 UA 请求才会带全（手机 UA 只给空壳）。首页 /index 的 regionList 是七个推荐区块；分类用 /tags 的 67 个标签（/tags/{tagId} 给该标签下的书）；书籍详情 /book_detail/{bookId} 直接给书名、作者、字数、简介和完整目录（实测 329 章）；正文 /chapter/{bookId}_{chapterId}.html 里的 chapterContent.content 是 DES-ECB 密文（PKCS7 填充），密钥是站点 config 里 rk 的前 8 个字符 ZUreQN0E——本源内联了一份纯 JS 的 DES 实现来解，实测解密出正文 441 字。手打的书详情地址 /bookDetails?params=… 是加密串，本源不用它。"},{"key":"publishPage","type":"action","action":"openWebsite","title":"打开站点首页","url":"https://www.ciyuanji.com/","description":"站点入口"}]}
// LumeRuntime: javascript
//
// 站点：次元姬（www.ciyuanji.com），Next.js SSR 成人轻小说站。
//
// 实测结论（2026-11-04）：
//   · 必须用**桌面 UA** 请求，手机 UA 只返回空壳（pageProps 只有 recommendRegionList）。
//   · /index                    → regionList（7 个推荐区块，childList + recomContentList）
//   · /tags                     → tagList（67 个标签，带 bookNum）
//   · /tags/{tagId}             → tagDesc + bookData（该标签下的书，实测 202 KB）
//   · /book_detail/{bookId}     → book + bookChapter.chapterList（329 章，含卷名/字数/是否收费）
//   · /chapter/{bookId}_{cid}.html → chapterContent.content = DES-ECB/PKCS7 密文（base64）
//   · 解密：站点 config/index.ts 里 rk 的前 8 字节 "ZUreQN0E" 当 DES 密钥（ECB、Pkcs7），
//     用 CryptoJS 的 DES.decrypt 解。App 沙箱没有 crypto 模块，所以本源内联了一份纯 JS DES。
//   · /library/card/{params}、/rank/card/{params} 需要加密 params（params 是密文），本源没用。

var BASE_URL = 'https://www.ciyuanji.com';
var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36';
var DES_KEY = 'ZUreQN0E';

function base() {
  var domain = LumeSource.config && LumeSource.config.domain ? LumeSource.config.domain : '';
  return String(domain || BASE_URL).replace(/\/+$/, '');
}

function absolute(url) {
  var text = String(url == null ? '' : url).trim();
  if (!text) return '';
  if (/^https?:\/\//i.test(text)) return text;
  if (text.indexOf('//') === 0) return 'https:' + text;
  if (text.charAt(0) === '/') return base() + text;
  return base() + '/' + text;
}

function decodeEntities(text) {
  return String(text == null ? '' : text)
    .replace(/&nbsp;/g, ' ')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&amp;/g, '&');
}

function clean(text) {
  return decodeEntities(String(text == null ? '' : text).replace(/<[^>]+>/g, ' '))
    .replace(/\s+/g, ' ')
    .trim();
}

async function fetchProps(path, referer) {
  var url = /^https?:\/\//i.test(path) ? path : base() + path;
  var reply = await LumeSource.http.get(url, {
    headers: {
      'User-Agent': UA,
      Accept: 'text/html,application/xhtml+xml,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      Referer: referer || base() + '/'
    }
  });
  var status = reply ? reply.status : 0;
  if (status === 403 || status === 503 || status === 521) {
    throw new Error('NEED_WEBVIEW_VERIFY：次元姬返回 HTTP ' + status + '，请在网页视图里过一次校验');
  }
  if (status !== 200) throw new Error('页面打不开：HTTP ' + status + ' ' + path);
  var body = reply.body ? String(reply.body) : '';
  var matched = /<script id="__NEXT_DATA__" type="application\/json">([\s\S]*?)<\/script>/.exec(body);
  if (!matched) throw new Error('页面里没有 __NEXT_DATA__（' + path + '）');
  var data;
  try {
    data = JSON.parse(matched[1]);
  } catch (error) {
    throw new Error('页面数据解析失败（' + path + '）');
  }
  return (data.props && data.props.pageProps) || {};
}

function bookFromRecom(node, out, seen) {
  if (!node || typeof node !== 'object') return;
  if (Array.isArray(node)) {
    for (var i = 0; i < node.length; i++) bookFromRecom(node[i], out, seen);
    return;
  }
  var id = node.bookId || node.id;
  if (id && (node.bookName || node.name)) {
    var key = String(id);
    if (!seen[key]) {
      seen[key] = true;
      out.push({
        id: key,
        title: String(node.bookName || node.name),
        cover: absolute(node.imgUrl || node.blurryImgUrl || node.cover || ''),
        subtitle: [node.authorName || node.author || '', node.firstClassifyName || '', node.secondClassifyName || '']
          .filter(Boolean)
          .join(' · '),
        mediaType: 'novel'
      });
    }
  }
  for (var k in node) {
    if (!Object.prototype.hasOwnProperty.call(node, k)) continue;
    if (k === 'book' || k === 'books' || k === 'recomContentList' || k === 'list' || k === 'childList' || k === 'bookList') {
      bookFromRecom(node[k], out, seen);
    }
  }
}

function booksOf(props) {
  var out = [];
  bookFromRecom(props, out, {});
  return out;
}

var LumeSource = {
  id: 'ciyuanji_novel',
  name: '次元姬',
  version: '1.0.0',
  category: 'comic',
  contentCategory: 'adult',
  mediaType: 'novel',
  network: 'direct',
  icon: 'https://www.ciyuanji.com/favicon.ico',
  mirrors: ['https://www.ciyuanji.com'],

  async categories() {
    var props = await fetchProps('/tags');
    var list = (props.tagList || []).map(function (tag) {
      return { id: 'tag-' + tag.tagId, title: tag.tagName + (tag.bookNum ? '（' + tag.bookNum + '）' : '') };
    });
    return list.length ? list : [{ id: 'home', title: '首页推荐' }];
  },

  async filters() {
    return { groups: [] };
  },

  async home() {
    var props = await fetchProps('/index');
    var regions = props.regionList || [];
    var boards = [];
    for (var i = 0; i < regions.length; i++) {
      var items = booksOf(regions[i]).slice(0, 12);
      if (!items.length) continue;
      var raw = String(regions[i].name || '');
      // 区块名多是排版名（PC站第一行/主编电台…），换成对读者有意义的标题
      var title = /^(PC站|第|手机站|H5)/.test(raw) || !raw ? '推荐 ' + (boards.length + 1) : raw;
      if (boards.length === 0) title = '轮播推荐';
      boards.push({ title: title, items: items });
    }
    if (!boards.length) throw new Error('首页没解析出条目（站点结构可能变了）');
    return boards;
  },

  async list(argument) {
    var args = argument || {};
    var categoryId = String(args.categoryId == null ? '' : args.categoryId).trim();
    var tagMatch = /^tag-(\d+)/.exec(categoryId);
    if (tagMatch) {
      var props = await fetchProps('/tags/' + tagMatch[1]);
      var items = booksOf(props.bookData || props);
      if (!items.length) throw new Error('这个标签下没有取到书（tag ' + tagMatch[1] + '）');
      return { items: items, hasMore: false };
    }
    var home = await this.home();
    var merged = [];
    for (var i = 0; i < home.length; i++) merged = merged.concat(home[i].items);
    var seen = {};
    var unique = merged.filter(function (item) {
      if (seen[item.id]) return false;
      seen[item.id] = true;
      return true;
    });
    return { items: unique, hasMore: false };
  },

  async detail(argument) {
    var id = String((argument && argument.id) || '').replace(/\D/g, '');
    if (!id) return null;
    var props = await fetchProps('/book_detail/' + id);
    var book = props.book;
    if (!book) return null;
    var chapters = (props.bookChapter && props.bookChapter.chapterList) || [];
    var lines = [];
    if (book.firstClassifyName) lines.push('分类：' + book.firstClassifyName + (book.secondClassifyName ? ' / ' + book.secondClassifyName : ''));
    if (book.authorName) lines.push('作者：' + book.authorName);
    if (book.wordCount) lines.push('字数：' + Math.round(Number(book.wordCount) / 1000) + 'K');
    lines.push('章节：' + chapters.length + (book.endState === 1 || book.endState === '1' ? '（已完结）' : '（连载中）'));
    var notes = book.notes ? clean(book.notes) : '';
    if (notes) lines.push('', notes);
    return {
      id: id,
      title: book.bookName || ('书 ' + id),
      cover: absolute(book.imgUrl || book.blurryImgUrl || ''),
      subtitle: [book.authorName || '', book.firstClassifyName || ''].filter(Boolean).join(' · '),
      description: lines.join('\n'),
      mediaType: 'novel'
    };
  },

  async chapters(argument) {
    var id = String((argument && argument.id) || '').replace(/\D/g, '');
    if (!id) return [];
    var props = await fetchProps('/book_detail/' + id);
    var list = (props.bookChapter && props.bookChapter.chapterList) || [];
    return list.map(function (row, index) {
      var title = row.chapterName || ('第 ' + (index + 1) + ' 章');
      var volume = row.title ? row.title + ' · ' : '';
      return { id: id + ':' + row.chapterId, title: volume + title };
    });
  },

  async content(argument) {
    var args = argument || {};
    var raw = String(args.chapterId == null ? '' : args.chapterId).trim();
    var matched = /(\d+)\D+(\d+)/.exec(raw);
    var bookId = matched ? matched[1] : String(args.id || '').replace(/\D/g, '');
    var chapterId = matched ? matched[2] : '';
    if (!bookId || !chapterId) throw new Error('缺少章节 ID（应形如 书号:章节号）');

    var props = await fetchProps('/chapter/' + bookId + '_' + chapterId + '.html');
    var cc = props.chapterContent;
    if (!cc) throw new Error('这一章没有正文数据（' + bookId + '_' + chapterId + '）');
    if (cc.isBuy === '0' && cc.isFee === '1') {
      throw new Error('这一章是付费章节（' + (cc.price || '') + '），站点未开放正文');
    }
    var cipher = String(cc.content || '').replace(/[\r\n]/g, '');
    if (!cipher) throw new Error('这一章正文是空的');
    var text = '';
    // 少数章节站点直接给明文
    if (/[\u4e00-\u9fa5]/.test(cipher)) {
      text = cipher;
    } else {
      text = desDecryptBase64(cipher, DES_KEY);
    }
    text = String(text || '').replace(/\r/g, '').replace(/\n{3,}/g, '\n\n').trim();
    if (!text) throw new Error('正文解密后为空（章节 ' + chapterId + '）');
    return { kind: 'text', title: cc.chapterName || undefined, text: text };
  }
};

/* ---------------- 纯 JS DES-ECB + PKCS7（CryptoJS DES.decrypt 等价实现） ---------------- */

var DES_IP = [58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4,
  62, 54, 46, 38, 30, 22, 14, 6, 64, 56, 48, 40, 32, 24, 16, 8,
  57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3,
  61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7];
var DES_FP = [40, 8, 48, 16, 56, 24, 64, 32, 39, 7, 47, 15, 55, 23, 63, 31,
  38, 6, 46, 14, 54, 22, 62, 30, 37, 5, 45, 13, 53, 21, 61, 29,
  36, 4, 44, 12, 52, 20, 60, 28, 35, 3, 43, 11, 51, 19, 59, 27,
  34, 2, 42, 10, 50, 18, 58, 26, 33, 1, 41, 9, 49, 17, 57, 25];
var DES_E = [32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9, 8, 9, 10, 11,
  12, 13, 12, 13, 14, 15, 16, 17, 16, 17, 18, 19, 20, 21, 20, 21,
  22, 23, 24, 25, 24, 25, 26, 27, 28, 29, 28, 29, 30, 31, 32, 1];
var DES_P = [16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26, 5, 18, 31, 10,
  2, 8, 24, 14, 32, 27, 3, 9, 19, 13, 30, 6, 22, 11, 4, 25];
var DES_PC1 = [57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2,
  59, 51, 43, 35, 27, 19, 11, 3, 60, 52, 44, 36,
  63, 55, 47, 39, 31, 23, 15, 7, 62, 54, 46, 38, 30, 22, 14, 6,
  61, 53, 45, 37, 29, 21, 13, 5, 28, 20, 12, 4];
var DES_PC2 = [14, 17, 11, 24, 1, 5, 3, 28, 15, 6, 21, 10, 23, 19, 12, 4,
  26, 8, 16, 7, 27, 20, 13, 2, 41, 52, 31, 37, 47, 55, 30, 40,
  51, 45, 33, 48, 44, 49, 39, 56, 34, 53, 46, 42, 50, 36, 29, 32];
var DES_SHIFT = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1];
var DES_SBOX = [
  [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7,
    0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
    4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0,
    15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13],
  [15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10,
    3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5,
    0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15,
    13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9],
  [10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8,
    13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
    13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7,
    1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12],
  [7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15,
    13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
    10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4,
    3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14],
  [2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9,
    14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
    4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14,
    11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3],
  [12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11,
    10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
    9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6,
    4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13],
  [4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1,
    13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
    1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2,
    6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12],
  [13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7,
    1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2,
    7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8,
    2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11]
];

function bytesToBits(bytes) {
  var bits = [];
  for (var i = 0; i < bytes.length; i++) {
    for (var b = 7; b >= 0; b--) bits.push((bytes[i] >> b) & 1);
  }
  return bits;
}

function bitsToBytes(bits) {
  var out = [];
  for (var i = 0; i < bits.length; i += 8) {
    var value = 0;
    for (var j = 0; j < 8; j++) value = (value << 1) | (bits[i + j] || 0);
    out.push(value);
  }
  return out;
}

function permute(bits, table) {
  var out = [];
  for (var i = 0; i < table.length; i++) out.push(bits[table[i] - 1]);
  return out;
}

function rotateLeft(bits, count) {
  var n = count % bits.length;
  return bits.slice(n).concat(bits.slice(0, n));
}

function desSubKeys(keyBytes) {
  var bits = permute(bytesToBits(keyBytes), DES_PC1);
  var c = bits.slice(0, 28);
  var d = bits.slice(28);
  var keys = [];
  for (var round = 0; round < 16; round++) {
    c = rotateLeft(c, DES_SHIFT[round]);
    d = rotateLeft(d, DES_SHIFT[round]);
    keys.push(permute(c.concat(d), DES_PC2));
  }
  return keys;
}

function desFeistel(right, subKey) {
  var expanded = permute(right, DES_E);
  var mixed = [];
  for (var i = 0; i < 48; i++) mixed.push(expanded[i] ^ subKey[i]);
  var sOut = [];
  for (var box = 0; box < 8; box++) {
    var chunk = mixed.slice(box * 6, box * 6 + 6);
    var row = (chunk[0] << 1) | chunk[5];
    var col = (chunk[1] << 3) | (chunk[2] << 2) | (chunk[3] << 1) | chunk[4];
    var value = DES_SBOX[box][row * 16 + col];
    sOut.push((value >> 3) & 1, (value >> 2) & 1, (value >> 1) & 1, value & 1);
  }
  return permute(sOut, DES_P);
}

function desDecryptBlock(blockBytes, subKeys) {
  var bits = permute(bytesToBits(blockBytes), DES_IP);
  var left = bits.slice(0, 32);
  var right = bits.slice(32);
  for (var round = 15; round >= 0; round--) {
    var f = desFeistel(right, subKeys[round]);
    var next = [];
    for (var i = 0; i < 32; i++) next.push(left[i] ^ f[i]);
    left = right;
    right = next;
  }
  return bitsToBytes(permute(right.concat(left), DES_FP));
}

function base64ToBytes(text) {
  var alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var clean2 = String(text || '').replace(/[^A-Za-z0-9+/=]/g, '');
  var bytes = [];
  var buffer = 0;
  var bitsHeld = 0;
  for (var i = 0; i < clean2.length; i++) {
    var ch = clean2.charAt(i);
    if (ch === '=') break;
    var value = alphabet.indexOf(ch);
    if (value < 0) continue;
    buffer = (buffer << 6) | value;
    bitsHeld += 6;
    if (bitsHeld >= 8) {
      bitsHeld -= 8;
      bytes.push((buffer >> bitsHeld) & 0xff);
    }
  }
  return bytes;
}

function bytesToUtf8(bytes) {
  var out = '';
  var i = 0;
  while (i < bytes.length) {
    var byte = bytes[i++];
    if (byte < 0x80) {
      out += String.fromCharCode(byte);
    } else if (byte >= 0xc0 && byte < 0xe0) {
      out += String.fromCharCode(((byte & 0x1f) << 6) | (bytes[i++] & 0x3f));
    } else if (byte >= 0xe0 && byte < 0xf0) {
      out += String.fromCharCode(((byte & 0x0f) << 12) | ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f));
    } else if (byte >= 0xf0) {
      var code = ((byte & 0x07) << 18) | ((bytes[i++] & 0x3f) << 12) | ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f);
      code -= 0x10000;
      out += String.fromCharCode(0xd800 + (code >> 10), 0xdc00 + (code & 0x3ff));
    } else {
      i++;
    }
  }
  return out;
}

function desDecryptBase64(cipherText, keyText) {
  var keyBytes = [];
  for (var i = 0; i < 8; i++) keyBytes.push(keyText.charCodeAt(i) & 0xff);
  var subKeys = desSubKeys(keyBytes);
  var data = base64ToBytes(cipherText);
  var out = [];
  for (var offset = 0; offset + 8 <= data.length; offset += 8) {
    var block = data.slice(offset, offset + 8);
    var plain = desDecryptBlock(block, subKeys);
    for (var k = 0; k < 8; k++) out.push(plain[k]);
  }
  if (out.length) {
    var pad = out[out.length - 1];
    if (pad > 0 && pad <= 8) out = out.slice(0, out.length - pad);
  }
  return bytesToUtf8(out);
}
