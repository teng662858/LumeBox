// LumeSource: {"id":"dage_video","name":"大哥视频","version":"2.3.0","category":"video"}

// Verified live API (base https://dage.one/api):
//   GET /core.json                        -> {menu:[{id,name,type,children:[{id,name,url}]}]}
//   GET /lists/{id}/{page}/{limit}.json   -> {navs,items:[{vod_id,title,img,url,duration}]}
//   GET /play/{id}.json                   -> {title,img,time,tags,actors,content,player:[{name,play}],items}
//   GET /article/{id}.json                -> {news_name,news_content}   (图片专区 / 小说专区)
//
// Every JSON body is wrapped as {"status":1,"data":"<obfuscated>"} where `data`
// is decoded as:
//   replace("/","0") -> replace("@","/") -> replace(".","+") -> reverse -> base64.
// The reverse and base64 steps must be done in pure JS (QuickJS has no atob).
var BASE_URL = 'https://dage.one';
var API_URL = BASE_URL + '/api';
var PAGE_SIZE = 24;

var B64_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

var LumeSource = {
  id: 'dage_video',
  name: '大哥视频',
  version: '2.3.0',
  category: 'video',

  async categories() {
    var core = await this.__get('/core.json');
    var menu = core && Array.isArray(core.menu) ? core.menu : [];
    var result = [];
    for (var i = 0; i < menu.length; i++) {
      var group = menu[i] || {};
      if (group.type !== 'vod') continue;
      var children = Array.isArray(group.children) ? group.children : [];
      for (var j = 0; j < children.length; j++) {
        var child = children[j] || {};
        if (child.type !== 'vod' && child.type) continue;
        result.push({
          id: String(child.id != null ? child.id : ''),
          title: String(child.name || child.id || '')
        });
      }
    }
    if (!result.length) result.push({ id: '56', title: '亚洲有码' });
    return result;
  },

  async list(argument) {
    var page = argument && argument.page ? Number(argument.page) : 1;
    var keyword = argument && argument.keyword ? String(argument.keyword).trim() : '';
    var category = argument && argument.categoryId ? String(argument.categoryId) : '';
    if (!category || category === 'all') category = '56';

    if (keyword) return await this.__search(keyword, page);

    var data = await this.__get('/lists/' + category + '/' + page + '/' + PAGE_SIZE + '.json');
    var raw = data && Array.isArray(data.items) ? data.items : [];
    var items = [];
    for (var i = 0; i < raw.length; i++) {
      items.push(this.__toItem(raw[i]));
    }
    var total = data && data.page && Number(data.page.count) ? Number(data.page.count) : 0;
    var hasMore = raw.length >= PAGE_SIZE && (total === 0 || page * PAGE_SIZE < total);
    return { items: items, hasMore: hasMore };
  },

  async detail(argument) {
    var id = this.__id(argument);
    var article = await this.__article(id);
    if (article) {
      return {
        id: id,
        title: String(article.news_name || id),
        description: String(article.news_content || '').replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim(),
        tags: [String(article.news_cname || '')]
      };
    }

    var data = await this.__get('/play/' + id + '.json');
    var player = Array.isArray(data.player) ? data.player : [];
    var related = [];
    if (Array.isArray(data.items)) {
      related = data.items.map(this.__toItem, this);
    }
    return {
      id: id,
      title: String(data.title || id),
      cover: data.img || '',
      description: [data.cname, data.time].filter(function (v) { return !!v; }).join(' · '),
      subtitle: player.length ? player[0].name : '',
      tags: Array.isArray(data.tags) ? data.tags : [],
      related: related,
      extra: {
        actors: Array.isArray(data.actors) ? data.actors : [],
        time: data.time || ''
      }
    };
  },

  async chapters(argument) {
    var id = this.__id(argument);
    if (await this.__article(id)) return [];

    var data = await this.__get('/play/' + id + '.json');
    var player = Array.isArray(data.player) ? data.player : [];
    var chapters = [];
    for (var i = 0; i < player.length; i++) {
      var entry = player[i] || {};
      var name = String(entry.name || '').trim();
      var url = entry.play ? String(entry.play) : '';
      if (!url) continue;
      chapters.push({
        id: String(entry.id != null ? entry.id : i + 1),
        title: name || ('线路 ' + (i + 1))
      });
    }
    return chapters;
  },

  async content(argument) {
    var id = this.__id(argument);
    var chapterId = argument && argument.chapterId ? String(argument.chapterId) : '';

    var article = await this.__article(id);
    if (article) {
      var images = this.__images(String(article.news_content || ''));
      if (!images.length) throw new Error('大哥视频：该图片集没有可显示的图片');
      return { kind: 'images', images: images };
    }

    var data = await this.__get('/play/' + id + '.json');
    var player = Array.isArray(data.player) ? data.player : [];
    if (!player.length) throw new Error('大哥视频：该视频没有可播放的线路');

    var chosen = null;
    if (chapterId) {
      for (var i = 0; i < player.length; i++) {
        if (String(player[i].id) === chapterId) { chosen = player[i]; break; }
      }
    }
    if (!chosen) chosen = player[0];
    var url = chosen && chosen.play ? String(chosen.play) : '';
    if (!url) throw new Error('大哥视频：该线路没有播放地址');
    return {
      kind: 'video',
      url: url,
      headers: { 'Referer': BASE_URL + '/', 'User-Agent': 'Mozilla/5.0' }
    };
  },

  // 图片专区 / 小说专区条目走 /article/{id}.json；视频条目没有该资源。
  async __article(id) {
    var digits = this.__digits(id);
    if (!digits) return null;
    try {
      var data = await this.__get('/article/' + digits + '.json');
      if (data && (data.news_content != null || data.news_name != null)) return data;
    } catch (error) {
      return null;
    }
    return null;
  },

  __id(argument) {
    var id = '';
    if (argument && argument.id != null) id = String(argument.id);
    else if (argument && argument.vod_id != null) id = String(argument.vod_id);
    if (!id) throw new Error('大哥视频：缺少视频 ID');
    return id;
  },

  __digits(id) {
    var match = String(id).match(/(\d+)/);
    return match ? match[1] : String(id).replace(/\D/g, '');
  },

  __toItem(item) {
    item = item || {};
    var id = item.vod_id != null ? item.vod_id : (item.news_id != null ? item.news_id : item.id);
    var url = item.url ? String(item.url) : '';
    var isNews = url.indexOf('/artice/') >= 0 || url.indexOf('/article/') >= 0;
    return {
      id: String(id != null ? id : ''),
      title: String(item.title || item.news_name || id || ''),
      cover: item.img || '',
      subtitle: item.duration ? String(item.duration) : (item.time ? String(item.time) : (isNews ? '图片' : '视频'))
    };
  },

  __images(html) {
    var result = [];
    var pattern = /<img[^>]+src=["']([^"']+)["']/gi;
    var match;
    while ((match = pattern.exec(html)) !== null) {
      var src = match[1].trim();
      if (src) result.push(src);
    }
    return result;
  },

  async __search(keyword, page) {
    var data = await this.__get('/vodsearch?wd=' + encodeURIComponent(keyword) + '&page=' + page);
    var raw = data && Array.isArray(data.items) ? data.items : [];
    return { items: raw.map(this.__toItem, this), hasMore: raw.length >= PAGE_SIZE };
  },

  async __get(path) {
    var response = await LumeSource.http.get(API_URL + path, {
      headers: {
        'Accept': 'application/json',
        'Referer': BASE_URL + '/'
      }
    });
    if (!response || response.status !== 200) {
      var status = response ? response.status : 0;
      var body = response && response.body ? String(response.body) : '';
      // Cloudflare 人机校验（用户口径 2.1.1）：抛固定标记，App 据此显示
      // 【重试】+【网页视图】两个出口（普通 HTTP 错误不抛这个标记）。
      if ((status === 403 || status === 503 || status === 429) &&
          /just a moment|__cf_chl|cf-chl|challenge-platform|cf-mitigated|checking your browser/i.test(body)) {
        throw new Error('NEED_WEBVIEW_VERIFY：站点触发了 Cloudflare 人机校验（HTTP ' + status + '）');
      }
      throw new Error('拉取失败：HTTP ' + status + ' ' + path);
    }
    var envelope;
    try {
      envelope = JSON.parse(response.body || '{}');
    } catch (error) {
      throw new Error('大哥视频返回的不是合法 JSON：' + path);
    }
    if (envelope.status && Number(envelope.status) !== 1) {
      throw new Error('大哥视频接口错误：' + (envelope.msg || envelope.status) + ' ' + path);
    }
    if (envelope.data === '' || envelope.data == null) return null;
    return this.__decode(String(envelope.data));
  },

  __decode(data) {
    var text = data.replace(/\//g, '0').replace(/@/g, '/').replace(/\./g, '+');
    var reversed = '';
    for (var i = text.length - 1; i >= 0; i--) reversed += text.charAt(i);
    var padded = reversed;
    var remainder = padded.length % 4;
    if (remainder !== 0) {
      var pad = 4 - remainder;
      for (var p = 0; p < pad; p++) padded += '=';
    }
    var json = this.__atob(padded);
    try {
      return JSON.parse(json);
    } catch (error) {
      throw new Error('大哥视频解码结果不是合法 JSON');
    }
  },

  // Minimal atob: decodes standard Base64 (with '=' padding) to a UTF-8 string.
  __atob(input) {
    var output = '';
    var buffer = 0;
    var bits = 0;
    for (var i = 0; i < input.length; i++) {
      var ch = input.charAt(i);
      if (ch === '=') break;
      var value = B64_CHARS.indexOf(ch);
      if (value < 0) continue;
      buffer = (buffer << 6) | value;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        output += String.fromCharCode((buffer >> bits) & 0xff);
      }
    }
    return this.__utf8(output);
  },

  __utf8(binary) {
    var result = '';
    for (var i = 0; i < binary.length; i++) {
      var code = binary.charCodeAt(i);
      if (code < 0x80) {
        result += String.fromCharCode(code);
      } else if (code >= 0xc0 && code < 0xe0) {
        result += String.fromCharCode(((code & 0x1f) << 6) | (binary.charCodeAt(++i) & 0x3f));
      } else if (code >= 0xe0 && code < 0xf0) {
        result += String.fromCharCode(
          ((code & 0x0f) << 12) |
          ((binary.charCodeAt(++i) & 0x3f) << 6) |
          (binary.charCodeAt(++i) & 0x3f)
        );
      } else if (code >= 0xf0) {
        var cp = ((code & 0x07) << 18) |
          ((binary.charCodeAt(++i) & 0x3f) << 12) |
          ((binary.charCodeAt(++i) & 0x3f) << 6) |
          (binary.charCodeAt(++i) & 0x3f);
        cp -= 0x10000;
        result += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
      }
    }
    return result;
  }
};
