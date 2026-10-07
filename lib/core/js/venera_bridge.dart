import 'sandbox/sandbox_polyfill.dart';
import 'source_bridge.dart';

/// Venera 漫画源的 JS 环境垫片：把 `ComicSource` 这套写法接到本项目的契约上。
///
/// 背景：Venera（同生态的漫画阅读器）的图源脚本长这样——
///
/// ```js
/// class Komiic extends ComicSource {
///   name = "Komiic"
///   key = "Komiic"
///   version = "1.0.3"
///   search = { load: async (keyword, options, page) => ({ comics, maxPage }) }
///   loadInfo = async (id) => ({ title, cover, chapters })
///   loadEp = async (comicId, epId) => ({ images: [url, ...] })
/// }
/// ```
///
/// 这类脚本在本项目里原本会直接报「ComicSource is not defined」——它是 Venera
/// 宿主提供的全局基类，我们的沙箱里没有。本垫片把这条链路补齐：
///
/// 1. **注入全局**：`ComicSource`（基类 + 子类登记）、`Network`、`Convert`、
///    `UI`、`HtmlDocument` / `HtmlElement` / `HtmlNode`、`createUuid` /
///    `randomInt` / `randomDouble`；
/// 2. **认领脚本里的子类**：宿主读出脚本里的类名后调用 `__lumeVeneraAdopt(name)`
///    （见 [VeneraScriptSource.classNameOf]），这里实例化它、跑一次 `init()`，
///    并把实例的 `name` / `key` / `version` 写进桥接全局 `LumeSource`——
///    于是**元信息读取、板块自报、导入校验全部沿用既有链路**，本层不新增导入逻辑；
/// 3. **契约映射**：把项目的五个契约方法挂到 `LumeSource` 上，
///    内部翻译成 Venera 的调用（`search` / `explore` / `categoryComics` /
///    `loadInfo` / `loadEp`），返回值再翻译成项目契约的形状。
///    **上层（引擎、注册表、数据源适配器、页面）一行不用改**。
///
/// 能力边界（如实声明，不做「假装支持」）：
/// - **支持**：JSON / GraphQL 型源（`Network.*` + `JSON.parse`）、
///   `explore` / `categoryComics` / `search` / `loadInfo` / `loadEp`、
///   `loadData` / `saveData` / `deleteData`（落在按图源隔离的沙盒存储）、
///   `HtmlDocument` 的**常用选择器子集**（见下）、`Convert` 的编码与 md5；
/// - **不支持并明确报错**：账号登录（`login*` / `logout`）、收藏夹、评论、
///   排序 / 点赞、`Convert` 的 sha*/hmac/AES/RSA、HTML 的伪类与兄弟选择器。
///   报错文案会点名「哪一项没接、当前支持什么」，而不是静默返回空结果。
///
/// 注入时机与其它垫片一致（脚本执行前），因此 `class X extends ComicSource`
/// 在脚本里可直接使用；上下文污染重建后垫片会随新上下文重新注入。
class VeneraComicSourcePolyfill implements SandboxPolyfill {
  const VeneraComicSourcePolyfill();

  /// 依赖桥接全局 `LumeSource`：契约方法挂到它的派发器上（顺序由登记表保证）。
  @override
  List<String> get requires => const <String>[LumeSourceBridge.polyfillId];

  @override
  String get id => polyfillId;

  static const String polyfillId = 'lume.comic.venera';

  /// 认领子类的入口名：宿主在脚本载入后调用它（`__lumeVeneraAdopt('Komiic')`）。
  static const String adoptFunction = '__lumeVeneraAdopt';

  @override
  String get source => r'''
(function () {
  if (globalThis.__lumeVenera) return;
  if (typeof globalThis.LumeBridge !== 'object') return;

  globalThis.__lumeVenera = { adopted: false, instance: null, className: '' };

  function unsupported(feature) {
    return new Error('Venera 源的这个能力尚未接入：' + feature
      + '（当前支持：搜索 / 分类 / 详情 / 章节 / 图片、Network、'
      + 'HtmlDocument 常用选择器、Convert 编码与 md5）');
  }

  function toBytes(text) {
    var value = String(text == null ? '' : text);
    var bytes = [];
    for (var i = 0; i < value.length; i++) {
      var code = value.charCodeAt(i);
      if (code < 0x80) {
        bytes.push(code);
      } else if (code < 0x800) {
        bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
      } else if (code >= 0xd800 && code <= 0xdbff && i + 1 < value.length) {
        var next = value.charCodeAt(i + 1);
        var point = 0x10000 + ((code - 0xd800) << 10) + (next - 0xdc00);
        bytes.push(0xf0 | (point >> 18), 0x80 | ((point >> 12) & 0x3f),
          0x80 | ((point >> 6) & 0x3f), 0x80 | (point & 0x3f));
        i++;
      } else {
        bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
      }
    }
    return bytes;
  }

  function fromBytes(bytes) {
    var text = '';
    for (var i = 0; i < bytes.length;) {
      var first = bytes[i++];
      if (first < 0x80) {
        text += String.fromCharCode(first);
      } else if (first < 0xe0) {
        text += String.fromCharCode(((first & 0x1f) << 6) | (bytes[i++] & 0x3f));
      } else if (first < 0xf0) {
        text += String.fromCharCode(((first & 0x0f) << 12)
          | ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f));
      } else {
        var point = ((first & 0x07) << 18) | ((bytes[i++] & 0x3f) << 12)
          | ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f);
        point -= 0x10000;
        text += String.fromCharCode(0xd800 + (point >> 10), 0xdc00 + (point & 0x3ff));
      }
    }
    return text;
  }

  var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

  function base64Encode(text) {
    var bytes = toBytes(text);
    var out = '';
    for (var i = 0; i < bytes.length; i += 3) {
      var b0 = bytes[i];
      var b1 = i + 1 < bytes.length ? bytes[i + 1] : 0;
      var b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
      out += B64.charAt(b0 >> 2) + B64.charAt(((b0 & 3) << 4) | (b1 >> 4));
      out += i + 1 < bytes.length ? B64.charAt(((b1 & 15) << 2) | (b2 >> 6)) : '=';
      out += i + 2 < bytes.length ? B64.charAt(b2 & 63) : '=';
    }
    return out;
  }

  function base64Decode(text) {
    var clean = String(text == null ? '' : text).replace(/[^A-Za-z0-9+/=]/g, '');
    var bytes = [];
    for (var i = 0; i < clean.length; i += 4) {
      var c0 = B64.indexOf(clean.charAt(i));
      var c1 = B64.indexOf(clean.charAt(i + 1));
      var c2 = clean.charAt(i + 2) === '=' ? -1 : B64.indexOf(clean.charAt(i + 2));
      var c3 = clean.charAt(i + 3) === '=' ? -1 : B64.indexOf(clean.charAt(i + 3));
      if (c0 < 0 || c1 < 0) continue;
      bytes.push(((c0 << 2) | (c1 >> 4)) & 0xff);
      if (c2 >= 0) bytes.push(((c1 << 4) | (c2 >> 2)) & 0xff);
      if (c3 >= 0) bytes.push(((c2 << 6) | c3) & 0xff);
    }
    return fromBytes(bytes);
  }

  function hexEncode(text) {
    var bytes = toBytes(text);
    var out = '';
    for (var i = 0; i < bytes.length; i++) {
      out += (bytes[i] < 16 ? '0' : '') + bytes[i].toString(16);
    }
    return out;
  }

  // ------------------------------------------------------------------ Convert
  var Convert = {
    encodeUtf8: function (text) { return toBytes(text); },
    decodeUtf8: function (bytes) { return fromBytes(bytes || []); },
    encodeBase64: function (text) { return base64Encode(text); },
    decodeBase64: function (text) { return base64Decode(text); },
    hexEncode: function (text) { return hexEncode(text); },
    hexDecode: function (text) {
      var clean = String(text == null ? '' : text);
      var bytes = [];
      for (var i = 0; i + 1 < clean.length; i += 2) {
        bytes.push(parseInt(clean.substring(i, i + 2), 16));
      }
      return fromBytes(bytes);
    },
    // md5 走宿主：Dart 侧已有一份经过标准向量验证的实现（core/util/md5.dart），
    // 不必在 JS 里再写一份。
    md5: function (data) {
      return globalThis.LumeBridge.invoke('util.digest', {
        algorithm: 'md5',
        data: typeof data === 'string' ? data : fromBytes(data || [])
      }).then(function (reply) {
        return (reply && reply.digest) || '';
      });
    },
    sha1: function () { throw unsupported('Convert.sha1'); },
    sha256: function () { throw unsupported('Convert.sha256'); },
    sha512: function () { throw unsupported('Convert.sha512'); },
    hmac: function () { throw unsupported('Convert.hmac'); },
    hmacString: function () { throw unsupported('Convert.hmacString'); },
    decryptAesEcb: function () { throw unsupported('Convert.decryptAesEcb'); },
    decryptAesCbc: function () { throw unsupported('Convert.decryptAesCbc'); },
    decryptAesCfb: function () { throw unsupported('Convert.decryptAesCfb'); },
    decryptAesOfb: function () { throw unsupported('Convert.decryptAesOfb'); },
    decryptRsa: function () { throw unsupported('Convert.decryptRsa'); }
  };

  // ------------------------------------------------------------------ Network
  function headersOf(headers) {
    var result = {};
    var names = Object.keys(headers || {});
    for (var i = 0; i < names.length; i++) if (headers[names[i]] != null) {
      result[names[i]] = String(headers[names[i]]);
    }
    return result;
  }

  function request(method, url, headers, body) {
    var options = { method: method, headers: headersOf(headers) };
    if (body != null) options.body = typeof body === 'string' ? body : JSON.stringify(body);
    return globalThis.fetch(String(url), options).then(function (response) {
      // Venera 的 Network 返回 { status, headers, body }，body 是字符串；
      // 我们的 fetch 已经是这个形状（多给了 text()/json()，Venera 源用不到）。
      return response;
    });
  }

  var Network = {
    get: function (url, headers) { return request('GET', url, headers); },
    post: function (url, headers, body) { return request('POST', url, headers, body); },
    put: function (url, headers, body) { return request('PUT', url, headers, body); },
    delete: function (url, headers, body) { return request('DELETE', url, headers, body); },
    patch: function (url, headers, body) { return request('PATCH', url, headers, body); },
    fetchBytes: function (url, headers) {
      return request('GET', url, headers).then(function (response) {
        return { status: response.status, headers: response.headers, body: toBytes(response.body) };
      });
    },
    // Cookie 是宿主网络层的事（全局 UA / 单源覆盖在那边配），脚本侧不单独持有。
    setCookies: function () { throw unsupported('Network.setCookies'); },
    getCookies: function () { throw unsupported('Network.getCookies'); },
    deleteCookies: function () { throw unsupported('Network.deleteCookies'); }
  };

  // ---------------------------------------------------------------------- UI
  // 沙箱里没有界面：提示类走日志（用户能在运行日志里看到），
  // 需要真实交互的能力如实报错，不假装成功。
  var UI = {
    showMessage: function (message) {
      if (typeof console !== 'undefined' && console.log) {
        console.log('[venera] ' + (message == null ? '' : String(message)));
      }
    },
    showLoading: function () {},
    cancelLoading: function () {},
    showDialog: function () { throw unsupported('UI.showDialog'); },
    showInputDialog: function () { throw unsupported('UI.showInputDialog'); },
    showSelectDialog: function () { throw unsupported('UI.showSelectDialog'); },
    launchUrl: function () { throw unsupported('UI.launchUrl'); }
  };

  function nextRandom32() {
    return Math.floor(Math.random() * 0x100000000) >>> 0;
  }

  function randomInt(min, max) {
    var low = max === undefined ? 0 : Number(min);
    var high = max === undefined ? Number(min) : Number(max);
    return low + (nextRandom32() % Math.max(1, high - low));
  }

  function createUuid() {
    var template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx';
    return template.replace(/[xy]/g, function (flag) {
      var value = (nextRandom32() % 16) | 0;
      return (flag === 'x' ? value : ((value & 3) | 8)).toString(16);
    });
  }

  // ------------------------------------------------------------ HtmlDocument
  // 沙箱里没有 DOM。这里给一个**够用的子集**：标签 / 类 / id / 属性、后代与
  // 子代组合、逗号分组；遇到没实现的语法（伪类、兄弟选择器）**直接报错**，
  // 而不是静默返回空集合——按错的规则抓网页比抓不到更糟。
  var VOID_TAGS = { area: 1, base: 1, br: 1, col: 1, embed: 1, hr: 1, img: 1, input: 1,
    link: 1, meta: 1, param: 1, source: 1, track: 1, wbr: 1 };
  var RAW_TAGS = { script: 1, style: 1, textarea: 1 };

  function HtmlNode(type) {
    this.type = type;
    this.parent = null;
  }

  HtmlNode.prototype.toElement = function () {
    return this.type === 'element' ? this : null;
  };

  function HtmlElement(tag, attributes) {
    HtmlNode.call(this, 'element');
    this.localName = tag;
    this.attributes = attributes || {};
    this.nodes = [];
  }
  HtmlElement.prototype = Object.create(HtmlNode.prototype);
  HtmlElement.prototype.constructor = HtmlElement;

  function TextNode(text) {
    HtmlNode.call(this, 'text');
    this.data = text;
  }
  TextNode.prototype = Object.create(HtmlNode.prototype);
  TextNode.prototype.constructor = TextNode;

  function appendChild(parent, node) {
    node.parent = parent;
    parent.nodes.push(node);
  }

  function elementChildren(node) {
    var result = [];
    for (var i = 0; i < node.nodes.length; i++) {
      if (node.nodes[i].type === 'element') result.push(node.nodes[i]);
    }
    return result;
  }

  function parseAttributes(raw) {
    var attributes = {};
    var pattern = /([^\s"'=<>\/]+)(?:\s*=\s*("([^"]*)"|'([^']*)'|([^\s"'>]+)))?/g;
    var matched;
    while ((matched = pattern.exec(raw)) !== null) {
      var name = matched[1].toLowerCase();
      var value = matched[3] !== undefined ? matched[3]
        : (matched[4] !== undefined ? matched[4]
        : (matched[5] !== undefined ? matched[5] : ''));
      attributes[name] = value;
    }
    return attributes;
  }

  function parseHtml(html) {
    var root = new HtmlElement('#root', {});
    var stack = [root];
    var input = String(html == null ? '' : html);
    var index = 0;
    while (index < input.length) {
      var open = input.indexOf('<', index);
      if (open < 0) {
        if (index < input.length) appendChild(stack[stack.length - 1], new TextNode(input.slice(index)));
        break;
      }
      if (open > index) appendChild(stack[stack.length - 1], new TextNode(input.slice(index, open)));
      if (input.substr(open, 4) === '<!--') {
        var commentEnd = input.indexOf('-->', open);
        index = commentEnd < 0 ? input.length : commentEnd + 3;
        continue;
      }
      if (input.charAt(open + 1) === '/') {
        var close = input.indexOf('>', open);
        if (close < 0) break;
        var closeName = input.slice(open + 2, close).trim().toLowerCase();
        for (var depth = stack.length - 1; depth > 0; depth--) {
          if (stack[depth].localName === closeName) {
            stack.length = depth;
            break;
          }
        }
        index = close + 1;
        continue;
      }
      var tagEnd = input.indexOf('>', open);
      if (tagEnd < 0) break;
      var raw = input.slice(open + 1, tagEnd);
      var selfClosing = raw.charAt(raw.length - 1) === '/';
      if (selfClosing) raw = raw.slice(0, -1);
      var space = raw.search(/[\s\/]/);
      var tagName = (space < 0 ? raw : raw.slice(0, space)).toLowerCase();
      if (!tagName) { index = tagEnd + 1; continue; }
      var element = new HtmlElement(tagName, parseAttributes(space < 0 ? '' : raw.slice(space)));
      appendChild(stack[stack.length - 1], element);
      index = tagEnd + 1;
      if (VOID_TAGS[tagName] || selfClosing) continue;
      if (RAW_TAGS[tagName]) {
        var rawEnd = input.toLowerCase().indexOf('</' + tagName, index);
        var rawText = rawEnd < 0 ? input.slice(index) : input.slice(index, rawEnd);
        if (rawText) appendChild(element, new TextNode(rawText));
        var rawClose = rawEnd < 0 ? input.length : input.indexOf('>', rawEnd);
        index = rawClose < 0 ? input.length : rawClose + 1;
        continue;
      }
      stack.push(element);
    }
    return root;
  }

  function textOf(node) {
    if (node.type === 'text') return node.data;
    var text = '';
    for (var i = 0; i < node.nodes.length; i++) text += textOf(node.nodes[i]);
    return text;
  }

  function htmlOf(node) {
    var out = '';
    for (var i = 0; i < node.nodes.length; i++) {
      var child = node.nodes[i];
      out += child.type === 'text' ? child.data : nodeHtml(child);
    }
    return out;
  }

  function nodeHtml(element) {
    var out = '<' + element.localName;
    var names = Object.keys(element.attributes);
    for (var i = 0; i < names.length; i++) {
      out += ' ' + names[i] + '="' + element.attributes[names[i]] + '"';
    }
    if (VOID_TAGS[element.localName]) return out + '/>';
    return out + '>' + htmlOf(element) + '</' + element.localName + '>';
  }

  function defineElementAccessors(proto) {
    Object.defineProperty(proto, 'text', { get: function () { return textOf(this); } });
    Object.defineProperty(proto, 'innerHtml', { get: function () { return htmlOf(this); } });
    Object.defineProperty(proto, 'classNames', {
      get: function () { return String(this.attributes['class'] || '').split(/\s+/).filter(Boolean); }
    });
    Object.defineProperty(proto, 'id', { get: function () { return this.attributes['id'] || ''; } });
    Object.defineProperty(proto, 'children', { get: function () { return elementChildren(this); } });
    Object.defineProperty(proto, 'previousSibling', {
      get: function () {
        if (!this.parent) return null;
        var index = this.parent.nodes.indexOf(this);
        return index > 0 ? this.parent.nodes[index - 1] : null;
      }
    });
    Object.defineProperty(proto, 'nextSibling', {
      get: function () {
        if (!this.parent) return null;
        var index = this.parent.nodes.indexOf(this);
        return index >= 0 && index + 1 < this.parent.nodes.length
          ? this.parent.nodes[index + 1] : null;
      }
    });
  }
  defineElementAccessors(HtmlElement.prototype);

  // 选择器：只实现「标签 / 类 / id / 属性 / 后代 / 子代 / 逗号分组」。
  function parseSelector(selector) {
    var text = String(selector == null ? '' : selector).trim();
    if (!text) throw new Error('HtmlDocument 选择器为空');
    if (/[+:~]/.test(text.replace(/\[[^\]]*\]/g, ''))) {
      throw new Error('HtmlDocument 暂不支持的选择器：' + text
        + '（暂不支持伪类与兄弟选择器；支持 标签 / .类 / #id / [属性] / 后代空格 / 子代 > / 逗号分组）');
    }
    var groups = [];
    var parts = text.split(',');
    for (var i = 0; i < parts.length; i++) {
      var group = [];
      var tokens = parts[i].trim().split(/\s*>\s*|\s+/);
      var combinators = [];
      var raw = parts[i].trim();
      var scan = raw.split(/(\s*>\s*|\s+)/);
      for (var s = 0; s < scan.length; s++) {
        if (scan[s].trim() === '') continue;
        if (scan[s].trim() === '>') { combinators.push('child'); continue; }
        if (/^\s+$/.test(scan[s])) { combinators.push('descendant'); continue; }
        group.push(scan[s]);
      }
      if (group.length === 0) throw new Error('HtmlDocument 暂不支持的选择器：' + text);
      // combinators[i] 表示 group[i+1] 与 group[i] 的关系。
      var relations = [];
      for (var r = 0; r < group.length - 1; r++) {
        relations.push(combinators[r] === 'child' ? 'child' : 'descendant');
      }
      groups.push({ steps: group, relations: relations });
      if (tokens.length !== group.length) {
        throw new Error('HtmlDocument 暂不支持的选择器：' + text);
      }
    }
    return groups;
  }

  function parseStep(step) {
    var simple = { tag: '', classes: [], id: '', attributes: [] };
    var pattern = /([a-zA-Z][\w-]*)|\.([\w-]+)|#([\w-]+)|\[([^\]]+)\]/g;
    var consumed = 0;
    var matched;
    while ((matched = pattern.exec(step)) !== null) {
      consumed += matched[0].length;
      if (matched[1]) simple.tag = matched[1].toLowerCase();
      else if (matched[2]) simple.classes.push(matched[2]);
      else if (matched[3]) simple.id = matched[3];
      else if (matched[4]) {
        var body = matched[4];
        var operator = '=';
        var name = body;
        var value = null;
        var operatorMatch = /^([\w-]+)\s*([*^$]?=)\s*(.*)$/.exec(body);
        if (operatorMatch) {
          name = operatorMatch[1];
          operator = operatorMatch[2];
          value = operatorMatch[3].replace(/^["']|["']$/g, '');
        } else if (/^[\w-]+$/.test(body)) {
          operator = '';
        } else {
          throw new Error('HtmlDocument 暂不支持的属性选择器：[' + body + ']');
        }
        simple.attributes.push({ name: name.toLowerCase(), operator: operator, value: value });
      }
      if (matched[0] === '*' && !simple.tag) simple.tag = '*';
    }
    if (consumed !== step.length) {
      throw new Error('HtmlDocument 暂不支持的选择器片段：' + step);
    }
    return simple;
  }

  function matchesStep(element, simple) {
    if (element.type !== 'element') return false;
    if (simple.tag && simple.tag !== '*' && element.localName !== simple.tag) return false;
    if (simple.id && element.id !== simple.id) return false;
    for (var i = 0; i < simple.classes.length; i++) {
      if (element.classNames.indexOf(simple.classes[i]) < 0) return false;
    }
    for (var a = 0; a < simple.attributes.length; a++) {
      var attribute = simple.attributes[a];
      var actual = element.attributes[attribute.name];
      if (actual === undefined) return false;
      if (attribute.operator === '') continue;
      if (attribute.operator === '=' && actual !== attribute.value) return false;
      if (attribute.operator === '*=' && actual.indexOf(attribute.value) < 0) return false;
      if (attribute.operator === '^=' && actual.indexOf(attribute.value) !== 0) return false;
      if (attribute.operator === '$=') {
        if (actual.length < attribute.value.length
          || actual.slice(actual.length - attribute.value.length) !== attribute.value) return false;
      }
    }
    return true;
  }

  function allElements(root) {
    var result = [];
    (function walk(node) {
      for (var i = 0; i < node.nodes.length; i++) {
        var child = node.nodes[i];
        if (child.type === 'element') { result.push(child); walk(child); }
      }
    })(root);
    return result;
  }

  function querySelectorAll(root, selector) {
    var groups = parseSelector(selector);
    var result = [];
    for (var g = 0; g < groups.length; g++) {
      var group = groups[g];
      var steps = [];
      for (var s = 0; s < group.steps.length; s++) steps.push(parseStep(group.steps[s]));
      var candidates = allElements(root);
      for (var c = 0; c < candidates.length; c++) {
        if (matchesChain(candidates[c], steps, group.relations) && result.indexOf(candidates[c]) < 0) {
          result.push(candidates[c]);
        }
      }
    }
    return result;
  }

  function matchesChain(element, steps, relations) {
    if (!matchesStep(element, steps[steps.length - 1])) return false;
    var current = element;
    for (var i = steps.length - 2; i >= 0; i--) {
      var relation = relations[i];
      var ancestor = current.parent;
      var found = false;
      while (ancestor && ancestor.type === 'element') {
        if (matchesStep(ancestor, steps[i])) { found = true; current = ancestor; break; }
        if (relation === 'child') break;
        ancestor = ancestor.parent;
      }
      if (!found) return false;
    }
    return true;
  }

  function HtmlDocument(html) {
    this.root = parseHtml(html);
  }

  HtmlDocument.prototype.querySelectorAll = function (selector) {
    return querySelectorAll(this.root, selector);
  };
  HtmlDocument.prototype.querySelector = function (selector) {
    var found = querySelectorAll(this.root, selector);
    return found.length > 0 ? found[0] : null;
  };
  HtmlDocument.prototype.getElementById = function (id) {
    return this.querySelector('#' + id);
  };
  HtmlDocument.prototype.dispose = function () {};

  HtmlElement.prototype.querySelectorAll = function (selector) {
    return querySelectorAll(this, selector);
  };
  HtmlElement.prototype.querySelector = function (selector) {
    var found = querySelectorAll(this, selector);
    return found.length > 0 ? found[0] : null;
  };
  HtmlElement.prototype.getElementById = function (id) {
    return this.querySelector('#' + id);
  };

  // ------------------------------------------------------------- ComicSource
  function store(method, key, value) {
    var payload = { key: String(key) };
    if (value !== undefined) payload.value = value === null ? '' : String(value);
    return globalThis.LumeBridge.invoke(method, payload);
  }

  function ComicSource() {}

  // 数据存取：落在按图源隔离的沙盒存储（与 LumeSource.fs 同一张表）。
  ComicSource.prototype.loadData = function (key) {
    return store('store.read', key).then(function (reply) {
      var value = reply ? reply.value : null;
      return value === null || value === undefined ? null : String(value);
    });
  };
  ComicSource.prototype.saveData = function (key, value) {
    return store('store.write', key, value);
  };
  ComicSource.prototype.deleteData = function (key) {
    return store('store.remove', key);
  };
  ComicSource.prototype.init = function () {};
  ComicSource.prototype.dispose = function () {};

  // 设置项（Venera 的 `settings = { domains: { type: 'input', default: 'x' } }`）。
  //
  // **必须是同步的**：Venera 脚本习惯在 getter 里直接用
  // （真实案例 18漫画/MH18：`get baseUrl() { return 'https://' + this.loadSetting('domains') }`），
  // 而宿主存储（`LumeBridge.invoke`）是异步的——同步接口没法等它。
  // 因此这里用一张实例级内存表：实例化时按脚本声明的 `default` 灌初值，
  // 随后异步补一次已保存的值（[hydrateSettings]），`saveSetting` 则
  // 同时写内存表与沙盒存储。内存表在上下文重建后会重新灌一遍（值仍在
  // 沙盒存储里，补读即回来）。
  function declaredSettings(instance) {
    var declared = instance && instance.settings;
    var table = {};
    if (declared && typeof declared === 'object') {
      var keys = Object.keys(declared);
      for (var i = 0; i < keys.length; i++) {
        var entry = declared[keys[i]];
        if (entry && typeof entry === 'object' && entry.default !== undefined) {
          table[keys[i]] = entry.default;
        }
      }
    }
    return table;
  }

  function settingsOf(instance) {
    if (!instance.__lumeSettings) instance.__lumeSettings = declaredSettings(instance);
    return instance.__lumeSettings;
  }

  /// 设置值在存储里的键名前缀：与 `loadData` 的键空间分开，避免撞名。
  function settingKey(key) { return 'setting:' + String(key); }

  function encodeSetting(value) {
    if (value === null || value === undefined) return '';
    if (typeof value === 'string') return JSON.stringify(value);
    try {
      return JSON.stringify(value);
    } catch (error) {
      return String(value);
    }
  }

  function decodeSetting(text) {
    var raw = String(text == null ? '' : text);
    try {
      return JSON.parse(raw);
    } catch (error) {
      // 存的不是 JSON（手改过、或旧版本写入的裸字符串）：原样当字符串用。
      return raw;
    }
  }

  /// 把已保存的设置值补进内存表；没有保存过就保留脚本声明的 default。
  function hydrateSettings(instance) {
    var keys = Object.keys(declaredSettings(instance));
    if (keys.length === 0) return Promise.resolve();
    var tasks = keys.map(function (key) {
      return store('store.read', settingKey(key)).then(function (reply) {
        var value = reply ? reply.value : null;
        if (value === null || value === undefined) return;
        settingsOf(instance)[key] = decodeSetting(value);
      }).catch(function () {
        // 存储不可用时按「没保存过」处理：脚本仍拿到 default，功能不受影响。
      });
    });
    return Promise.all(tasks);
  }

  ComicSource.prototype.loadSetting = function (key) {
    var table = settingsOf(this);
    var name = String(key);
    return Object.prototype.hasOwnProperty.call(table, name) ? table[name] : undefined;
  };
  ComicSource.prototype.saveSetting = function (key, value) {
    settingsOf(this)[String(key)] = value;
    return store('store.write', settingKey(key), encodeSetting(value));
  };
  ComicSource.prototype.deleteSetting = function (key) {
    delete settingsOf(this)[String(key)];
    return store('store.remove', settingKey(key));
  };

  Object.defineProperty(ComicSource.prototype, 'isLogged', { get: function () { return false; } });
  ComicSource.prototype.login = function () { throw unsupported('login（账号登录）'); };
  ComicSource.prototype.logout = function () { throw unsupported('logout（账号登录）'); };
  ComicSource.prototype.registerWebsite = function () { throw unsupported('registerWebsite'); };
  ComicSource.sources = {};

  globalThis.ComicSource = ComicSource;
  globalThis.Network = Network;
  globalThis.Convert = Convert;
  globalThis.UI = UI;
  globalThis.createUuid = createUuid;
  globalThis.randomInt = randomInt;
  globalThis.randomDouble = function (min, max) {
    var low = max === undefined ? 0 : Number(min);
    var high = max === undefined ? Number(min) : Number(max);
    return low + Math.random() * Math.max(0, high - low);
  };
  globalThis.HtmlDocument = HtmlDocument;
  globalThis.HtmlElement = HtmlElement;
  globalThis.HtmlNode = HtmlNode;

  // -------------------------------------------------------------- 契约适配
  function listEnvelope(value) {
    // Venera 的列表返回 { comics: [...], maxPage }（explore/category 可能是
    // { comics, next }）。这里只认 maxPage 分页：没有 maxPage 就当作没有下一页。
    var comics = [];
    var maxPage = null;
    if (value && typeof value === 'object') {
      if (Array.isArray(value.comics)) comics = value.comics;
      else if (Array.isArray(value)) comics = value;
      if (typeof value.maxPage === 'number') maxPage = value.maxPage;
    } else if (Array.isArray(value)) {
      comics = value;
    }
    return { comics: comics, maxPage: maxPage };
  }

  function toItem(raw) {
    if (!raw || typeof raw !== 'object') return null;
    var id = raw.id == null ? '' : String(raw.id);
    var title = raw.title == null ? '' : String(raw.title);
    if (!id || !title) return null;
    var item = { id: id, title: title };
    var cover = raw.cover || raw.image || raw.thumbnail;
    if (cover) item.cover = String(cover);
    var subtitle = raw.subtitle != null ? raw.subtitle : raw.subTitle;
    if (subtitle) item.subtitle = String(subtitle);
    return item;
  }

  function categories() {
    var instance = instanceOrThrow();
    var result = [];
    var explore = instance.explore;
    if (Array.isArray(explore)) {
      for (var i = 0; i < explore.length; i++) {
        if (explore[i] && explore[i].title) {
          result.push({ id: 'explore:' + i, title: String(explore[i].title) });
        }
      }
    }
    var category = instance.category;
    if (category && Array.isArray(category.parts)) {
      for (var p = 0; p < category.parts.length; p++) {
        var part = category.parts[p];
        var values = part && Array.isArray(part.categories) ? part.categories : [];
        for (var c = 0; c < values.length; c++) {
          var entry = values[c];
          var title = entry && typeof entry === 'object'
            ? (entry.title || entry.name || entry.id) : entry;
          if (title == null) continue;
          result.push({ id: 'category:' + p + ':' + c, title: String(title) });
        }
      }
    }
    return result;
  }

  function list(argument) {
    var instance = instanceOrThrow();
    var options = argument && typeof argument === 'object' ? argument : {};
    var page = options.page ? Number(options.page) : 1;
    var keyword = options.keyword ? String(options.keyword) : '';
    var categoryId = options.categoryId ? String(options.categoryId) : '';
    var pending;

    if (keyword) {
      if (!instance.search || typeof instance.search.load !== 'function') {
        return Promise.reject(new Error('该 Venera 源没有提供 search，无法搜索'));
      }
      pending = instance.search.load(keyword, searchOptions(instance), page);
    } else if (categoryId.indexOf('category:') === 0) {
      var parts = categoryId.split(':');
      var partIndex = Number(parts[1]);
      var category = instance.category && Array.isArray(instance.category.parts)
        ? instance.category.parts[partIndex] : null;
      var values = category && Array.isArray(category.categories) ? category.categories : [];
      var entry = values[Number(parts[2])];
      var categoryName = entry && typeof entry === 'object'
        ? (entry.id || entry.title || entry.name) : entry;
      var param = category && Array.isArray(category.categoryParams)
        ? category.categoryParams[Number(parts[2])] : null;
      if (!instance.categoryComics || typeof instance.categoryComics.load !== 'function') {
        return Promise.reject(new Error('该 Venera 源没有提供 categoryComics，无法按分类浏览'));
      }
      pending = instance.categoryComics.load(
        categoryName == null ? '' : String(categoryName),
        param == null ? null : String(param),
        [],
        page
      );
    } else if (categoryId.indexOf('explore:') === 0) {
      var index = Number(categoryId.split(':')[1]);
      var page_ = instance.explore && instance.explore[index];
      if (!page_ || typeof page_.load !== 'function') {
        return Promise.reject(new Error('该 Venera 源没有这个探索页：' + categoryId));
      }
      pending = page_.load(page);
    } else {
      // 没有指定范围：优先第一个探索页（等价于 Venera 首页），否则搜索空串。
      var first = instance.explore && instance.explore[0];
      if (first && typeof first.load === 'function') {
        pending = first.load(page);
      } else if (instance.search && typeof instance.search.load === 'function') {
        pending = instance.search.load('', searchOptions(instance), page);
      } else {
        return Promise.reject(new Error('该 Venera 源既没有 explore 也没有 search，无法出列表'));
      }
    }

    return Promise.resolve(pending).then(function (value) {
      var envelope = listEnvelope(value);
      var items = [];
      for (var i = 0; i < envelope.comics.length; i++) {
        var item = toItem(envelope.comics[i]);
        if (item) items.push(item);
      }
      return {
        items: items,
        hasMore: envelope.maxPage !== null && page < envelope.maxPage
      };
    });
  }

  function searchOptions(instance) {
    var options = instance.search && instance.search.optionList;
    if (!Array.isArray(options)) return [];
    var selected = [];
    for (var i = 0; i < options.length; i++) {
      var group = options[i];
      var values = group && Array.isArray(group.options) ? group.options : [];
      var defaultValue = group && group.default != null ? group.default : 0;
      selected.push(values[defaultValue] == null ? '' : String(values[defaultValue]));
    }
    return selected;
  }

  function detail(argument) {
    var instance = instanceOrThrow();
    var id = argument && argument.id ? String(argument.id) : '';
    if (!id) return Promise.resolve(null);
    if (typeof instance.loadInfo !== 'function') {
      return Promise.reject(new Error('该 Venera 源没有提供 loadInfo，无法取详情'));
    }
    return Promise.resolve(instance.loadInfo(id)).then(function (info) {
      if (!info || typeof info !== 'object') return null;
      var result = {
        id: id,
        title: info.title == null ? id : String(info.title)
      };
      if (info.cover) result.cover = String(info.cover);
      var subtitle = info.subTitle != null ? info.subTitle : info.subtitle;
      if (!subtitle && info.tags && typeof info.tags === 'object') {
        var names = Object.keys(info.tags);
        if (names.length > 0 && Array.isArray(info.tags[names[0]])) {
          subtitle = info.tags[names[0]].join(' · ');
        }
      }
      if (subtitle) result.subtitle = String(subtitle);
      if (info.description) result.description = String(info.description);
      return result;
    });
  }

  function chapters(argument) {
    var instance = instanceOrThrow();
    var id = argument && argument.id ? String(argument.id) : '';
    if (typeof instance.loadInfo !== 'function') {
      return Promise.reject(new Error('该 Venera 源没有提供 loadInfo，无法取章节'));
    }
    return Promise.resolve(instance.loadInfo(id)).then(function (info) {
      var raw = info && info.chapters;
      var result = [];
      if (!raw) return result;
      if (Array.isArray(raw)) {
        // 也接受 [{id, title}] 这种直给形状（少数源这么写）。
        for (var i = 0; i < raw.length; i++) {
          var entry = raw[i];
          if (+entry && entry.id != null) {
            result.push({ id: String(entry.id), title: String(entry.title || entry.id) });
          }
        }
        return result;
      }
      var names = Object.keys(raw);
      for (var n = 0; n < names.length; n++) {
        var value = raw[names[n]];
        if (value && typeof value === 'object') {
          // 分组章节：{ 分组名: { 章节id: 标题 } }
          var inner = Object.keys(value);
          for (var k = 0; k < inner.length; k++) {
            result.push({ id: String(inner[k]), title: String(value[inner[k]]) });
          }
        } else {
          result.push({ id: String(names[n]), title: String(value) });
        }
      }
      return result;
    });
  }

  function content(argument) {
    var instance = instanceOrThrow();
    var id = argument && argument.id ? String(argument.id) : '';
    var chapterId = argument && argument.chapterId ? String(argument.chapterId) : '';
    if (typeof instance.loadEp !== 'function') {
      return Promise.reject(new Error('该 Venera 源没有提供 loadEp，无法取图片'));
    }
    return Promise.resolve(instance.loadEp(id, chapterId)).then(function (ep) {
      var raw = ep && (ep.images || ep.pages || ep);
      if (!Array.isArray(raw)) {
        throw new Error('该章返回的内容里没有图片列表（loadEp 需要返回 { images: [...] }）');
      }
      var images = [];
      var needsHeaders = false;
      for (var i = 0; i < raw.length; i++) {
        var entry = raw[i];
        if (entry == null) continue;
        if (typeof entry === 'string') { images.push(entry); continue; }
        var url = entry.url || entry.src;
        if (!url) continue;
        if (entry.headers && Object.keys(entry.headers).length > 0) needsHeaders = true;
        images.push(String(url));
      }
      if (images.length === 0) {
        throw new Error('该章没有可用图片（loadEp 返回了空列表）');
      }
      if (needsHeaders) {
        // 本项目当前只给图片管线一个地址（没有逐图请求头的位置）。如实记一条日志，
        // 让「图片打不开」有据可查，而不是让用户以为是源坏了。
        console.log('[venera] 该章图片带了自定义请求头，本项目暂不透传（若图片 403 与此有关）');
      }
      return { kind: 'images', images: images };
    });
  }

  function instanceOrThrow() {
    var instance = globalThis.__lumeVenera.instance;
    if (!instance) {
      throw new Error('没有认领到 Venera 源实例：脚本里需要有 class X extends ComicSource');
    }
    return instance;
  }

  /// 宿主在脚本载入后调用：实例化脚本里的子类，写回元信息，挂上五个契约方法。
  globalThis.__lumeVeneraAdopt = function (className) {
    var name = String(className || '').trim();
    var Instance = name ? globalThis[name] : undefined;
    if (typeof Instance !== 'function') {
      // 类声明在全局词法作用域里，不挂在 globalThis 上——用 eval 再取一次。
      try {
        Instance = (0, eval)(name);
      } catch (error) {
        Instance = undefined;
      }
    }
    if (typeof Instance !== 'function') {
      throw new Error('认领 Venera 源失败：找不到 class ' + name);
    }
    var instance = new Instance();
    globalThis.__lumeVenera.instance = instance;
    globalThis.__lumeVenera.className = name;
    globalThis.__lumeVenera.adopted = true;
    ComicSource.sources[instance.key == null ? name : String(instance.key)] = instance;

    // 元信息写进桥接全局：id / name / version / 板块自报（Venera 是漫画生态）。
    var bridge = globalThis.LumeSource;
    if (bridge && typeof bridge === 'object') {
      bridge.id = String(instance.key == null ? name : instance.key);
      bridge.name = String(instance.name == null ? name : instance.name);
      bridge.version = String(instance.version == null ? '' : instance.version);
      // 板块自报为漫画：于是「Venera 源被导入小说 / 视频板块」会走**既有的**
      // 跨板块校验被拦下，报的是人话（跨板块），而不是一句
      // 「ComicSource is not defined」（那正是用户先前遇到的那类报错）。
      bridge.category = 'comic';
      bridge.categories = categories;
      bridge.list = list;
      bridge.detail = detail;
      bridge.chapters = chapters;
      bridge.content = content;

      // 脚本自己写的其它方法（`async probe() {}` 这类）也挂上去：
      // 契约之外的可选能力（例如将来的弹幕方法）与调试探针都靠这条路，
      // 不必为每个能力在垫片里再写一份转发。已有的名字（http / fs / 五个契约）
      // 一律不覆盖。
      //
      // **只认「数据属性里的函数」，绝不读 getter**：这里原先是
      // `typeof instance[name] === 'function'`——那一句会把属性**读出来**，
      // 于是 getter 被顺带执行。真机实测（18漫画 / MH18）：
      // `get baseUrl() { return 'https://' + this.loadSetting('domains') }`
      // 在读属性的那一刻执行并抛 `TypeError: not a function`，整个源认领失败。
      // getter 本来也不是「方法」，跳过它既修了崩溃、也更贴合本段意图。
      var reservedNames = { constructor: 1, init: 1, dispose: 1 };
      var seenNames = {};
      var holders = [instance, Object.getPrototypeOf(instance)];
      for (var h = 0; h < holders.length; h++) {
        var holder = holders[h];
        if (!holder) continue;
        var names = Object.getOwnPropertyNames(holder);
        for (var c = 0; c < names.length; c++) {
          var methodName = names[c];
          if (seenNames[methodName]) continue;
          seenNames[methodName] = 1;
          if (reservedNames[methodName] || methodName.indexOf('_') === 0) continue;
          var descriptor = Object.getOwnPropertyDescriptor(holder, methodName);
          if (!descriptor || typeof descriptor.value !== 'function') continue;
          if (bridge[methodName] !== undefined) continue;
          bridge[methodName] = descriptor.value.bind(instance);
        }
      }
    }

    // 设置项就位后再跑 init（脚本可能在 init 里读设置）。
    return hydrateSettings(instance).then(function () {
      var initialization = instance.init ? instance.init() : null;
      return Promise.resolve(initialization);
    }).then(function () { return true; });
  };
})();
''';
}

/// Venera 脚本的纯 Dart 侧识别：从脚本文本里读出子类名。
///
/// 为什么要在 Dart 侧做：Venera 脚本只写 `class X extends ComicSource { … }`，
/// **没有任何注册语句**（没有 `new X()`、没有导出），类声明又只存在于全局词法
/// 作用域、不挂在 `globalThis` 上。宿主读一遍文本拿到类名，再让垫片按名字认领，
/// 是最稳的一条路——不必猜运行时状态，也没有「脚本必须多写一行」的额外要求。
class VeneraScriptSource {
  const VeneraScriptSource._();

  /// `class X extends ComicSource` / `class X extends ComicSource {`
  static final RegExp _classPattern = RegExp(
    r'class\s+([A-Za-z_$][\w$]*)\s+extends\s+ComicSource\b',
  );

  /// 是否是 Venera 风格脚本（含 `extends ComicSource`）。
  static bool looksVenera(String script) =>
      _classPattern.hasMatch(codeOnly(script));

  /// 取子类名；找不到返回 null。
  ///
  /// 匹配前先剥掉注释与字符串字面量：真实源脚本的**注释里经常写着**
  /// `class X extends ComicSource` 这种示例（本仓库的两份示例源就都这么写），
  /// 直接全文正则会把注释里的 `X` 当成类名，认领随之失败。
  ///
  /// 同一脚本里出现多个子类时取**第一个**：Venera 生态的约定是一个文件一个源，
  /// 多类通常是一个源 + 辅助类，主源写在前面。
  static String? classNameOf(String script) {
    final match = _classPattern.firstMatch(codeOnly(script));
    return match?.group(1);
  }

  /// 只保留「代码」：剥掉行注释、块注释与字符串字面量的内容。
  ///
  /// 不追求做完整词法分析，只要让正则不在注释 / 字符串里误命中即可——
  /// 因此这里跟踪引号与注释状态，遇到就跳过对应区间（跳过的部分留一个空格，
  /// 避免把相邻 token 粘成一个）。
  static String codeOnly(String script) {
    final buffer = StringBuffer();
    var index = 0;
    while (index < script.length) {
      final char = script[index];
      final next = index + 1 < script.length ? script[index + 1] : '';
      if (char == '/' && next == '/') {
        final end = script.indexOf('\n', index);
        index = end < 0 ? script.length : end;
        continue;
      }
      if (char == '/' && next == '*') {
        final end = script.indexOf('*/', index + 2);
        index = end < 0 ? script.length : end + 2;
        buffer.write(' ');
        continue;
      }
      if (char == '"' || char == "'" || char == '`') {
        buffer.write(' ');
        index++;
        while (index < script.length) {
          if (script[index] == r'\') {
            index += 2;
            continue;
          }
          if (script[index] == char) {
            index++;
            break;
          }
          index++;
        }
        buffer.write(' ');
        continue;
      }
      buffer.write(char);
      index++;
    }
    return buffer.toString();
  }
}
