// Venera 风格示例源（JSON 接口）：class extends ComicSource 的写法。
//
// 与 demo_*_source.js 的区别：那三份是本项目自己的 `LumeSource` 契约写法，
// 这份是 **Venera 生态**的写法（`class X extends ComicSource`），由漫画板块的
// Venera 兼容垫片（`lib/core/js/venera_bridge.dart`）翻译到同一套契约上——
// 也就是说：Venera 源的脚本不改一行，就能在本项目的漫画板块里导入、浏览、看图片。
//
// 本文件同时是「Venera 兼容层能做什么」的可执行说明：
//   支持：explore / categoryComics / search / loadInfo / loadEp、
//         Network.*、loadData / saveData / deleteData、Convert 编码与 md5；
//   不支持（会抛可读错误）：账号登录、收藏夹、评论、Convert 的 sha*/AES/RSA。
//
// BASE_URL 改成你自己的测试站点即可（本地起个静态/JSON 服务最方便）。
var BASE_URL = 'http://127.0.0.1:8080';

class VeneraDemoJson extends ComicSource {
  // 元信息：id 取 key，名字取 name，版本取 version（与 Venera 一致）。
  name = 'Venera 示例源（JSON）';
  key = 'venera-demo-json';
  version = '1.0.0';
  minAppVersion = '1.0.0';
  url = '';

  // 首页：Venera 用 explore 表达「可下拉的列表页」。
  explore = [
    {
      title: '最新',
      type: 'multiPageComicList',
      load: async (page) => {
        const json = await this.getJson('/api/list?page=' + page);
        return { comics: (json.items || []).map((item) => this.parseComic(item)), maxPage: 3 };
      },
    },
  ];

  // 搜索：Venera 的 search.load(keyword, options, page)。
  search = {
    load: async (keyword, options, page) => {
      const json = await this.getJson(
        '/api/list?page=' + page + '&keyword=' + encodeURIComponent(keyword)
      );
      return { comics: (json.items || []).map((item) => this.parseComic(item)), maxPage: 1 };
    },
  };

  // 详情：Venera 的 loadInfo(id)，章节用 { 章节id: 标题 } 的映射表达。
  loadInfo = async (id) => {
    const json = await this.getJson('/api/detail?id=' + encodeURIComponent(id));
    const item = (json && json.item) || {};
    const chapterJson = await this.getJson('/api/chapters?id=' + encodeURIComponent(id));
    const chapters = {};
    (chapterJson.chapters || []).forEach((chapter) => {
      chapters[chapter.id] = chapter.title;
    });
    // 顺带演示沙盒存储：把最近一次详情记下来（按图源隔离，重启即清空）。
    await this.saveData('last-detail', id);
    return {
      title: item.title || id,
      cover: item.cover || '',
      description: item.description || '',
      tags: { 状态: [item.subtitle || '未知'] },
      chapters: chapters,
    };
  };

  // 正文：Venera 的 loadEp(comicId, epId) 返回 { images: [...] }。
  loadEp = async (comicId, epId) => {
    const json = await this.getJson(
      '/api/content?id=' + encodeURIComponent(comicId)
      + '&chapterId=' + encodeURIComponent(epId)
    );
    const images = (json && json.images) || [];
    if (images.length === 0) {
      throw new Error('该章没有图片：' + comicId + ' / ' + epId);
    }
    return { images: images };
  };

  // 探针（测试用）：回报兼容层支持 / 不支持的能力。
  async probe() {
    const cached = await this.loadData('last-detail');
    const digest = await Convert.md5('abc');
    let unsupported = '';
    try {
      Convert.sha256('abc');
    } catch (error) {
      unsupported = String(error.message || error);
    }
    let loginError = '';
    try {
      this.login('user', 'pwd');
    } catch (error) {
      loginError = String(error.message || error);
    }
    return {
      cached: cached === null ? null : String(cached),
      md5: String(digest),
      unsupported: unsupported,
      loginError: loginError,
      hasHtmlDocument: typeof HtmlDocument === 'function',
    };
  }

  parseComic(item) {
    return {
      id: String(item.id),
      title: String(item.title),
      cover: item.cover ? String(item.cover) : '',
      subtitle: item.subtitle ? String(item.subtitle) : '',
    };
  }

  async getJson(path) {
    const res = await Network.get(BASE_URL + path, this.headers);
    if (res.status !== 200) {
      throw new Error('拉取失败：HTTP ' + res.status + ' ' + path);
    }
    return JSON.parse(res.body || 'null');
  }

  get headers() {
    return {
      'User-Agent': 'LumeBox-VeneraDemo/1.0',
      'Accept': 'application/json',
    };
  }
}
