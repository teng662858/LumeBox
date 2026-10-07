// Venera 风格回归夹具：**getter 里读设置**（真机崩溃的复现形态）。
//
// 真机实测（venera-configs 的 mh18.js / 18漫画）：导入报
// 「Venera 源认领失败（MH18）：TypeError: not a function」。
// 根因不在脚本，而在兼容层的认领流程：
//   `typeof instance[name] === 'function'` 这一句会把属性**读出来**，
//   于是 `get baseUrl()` 被顺带执行，里面 `this.loadSetting('domains')`
//   在当时的垫片里根本不存在 → TypeError → 整份源认领失败。
//
// 这份夹具把那个形态原样保留下来（getter + settings 声明 + loadSetting），
// 用来守住两条：
//   1. 认领过程**不得执行 getter**（数据属性里的函数才挂桥）；
//   2. `loadSetting` 必须存在且**同步**可用（脚本在 getter 里直接用它）。
//
// 与 venera_demo_json.js 的分工：那份测「五个契约跑得通」，这份测
// 「带 getter / 设置的源能不能活到能跑契约那一步」。

var BASE_URL = 'http://127.0.0.1:8080';

class VeneraGetterSettings extends ComicSource {
  name = 'Venera 夹具（getter 设置）';
  key = 'venera-getter-settings';
  version = '1.0.0';
  minAppVersion = '1.0.0';
  url = '';

  // 声明式设置项：Venera 用 default 表达「用户没改过时用什么」。
  settings = {
    domains: {
      title: '域名',
      type: 'input',
      default: 'example.com',
    },
  };

  // ⚠️ 关键形态：getter 里读设置。认领流程若去读属性，就会在这里炸。
  get baseUrl() {
    return 'https://' + this.loadSetting('domains');
  }

  get headers() {
    return { 'Referer': this.baseUrl };
  }

  parseComics(doc) {
    const result = [];
    for (let item of doc.querySelectorAll('.pb-2')) {
      result.push(
        new Comic({
          id: item.querySelector('a').attributes['href'],
          title: item.querySelector('h3').text,
          cover: item.querySelector('img').attributes['src'],
        })
      );
    }
    return result;
  }

  // 调试探针（不是契约方法）：桥接层会把「脚本自己的函数」也挂到 LumeSource 上，
  // 测试据此直接问「getter 求值 / 设置读写」的结果。
  // 顺带守住一条：`loadSetting` 必须是**同步**可用的（这里没 await）。
  async probeRead() {
    return {
      baseUrl: this.baseUrl,
      domains: this.loadSetting('domains'),
      missing: this.loadSetting('not-declared'),
    };
  }

  async probeSave(argument) {
    // 契约调用传的是**一个参数对象**（与 content({id, chapterId}) 同口径）。
    const next = argument && argument.value !== undefined ? argument.value : argument;
    await this.saveSetting('domains', next);
    return { after: this.loadSetting('domains'), baseUrl: this.baseUrl };
  }

  explore = [
    {
      title: '最新',
      type: 'multiPageComicList',
      load: async (page) => {
        const res = await Network.get(this.baseUrl + '/latest/page/' + page, this.headers);
        const document = new HtmlDocument(res.body);
        return { comics: this.parseComics(document), maxPage: 1 };
      },
    },
  ];

  search = {
    load: async (keyword, options, page) => {
      const res = await Network.get(this.baseUrl + '/s/' + keyword + '?page=' + page);
      const document = new HtmlDocument(res.body);
      return { comics: this.parseComics(document), maxPage: 1 };
    },
  };

  comic = {
    loadInfo: async (id) => {
      const res = await Network.get(id, this.headers);
      const document = new HtmlDocument(res.body);
      return new ComicDetails({
        title: document.querySelector('.comic-title').text,
        cover: document.querySelector('.comic-cover').attributes['src'],
      });
    },
    loadEp: async (id, store) => [{ id: 'ch-1', title: '第 1 话' }],
  };
}
