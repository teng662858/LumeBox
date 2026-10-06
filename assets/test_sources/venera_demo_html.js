// Venera 风格示例源（HTML 抓取）：演示兼容层里的 HtmlDocument 子集。
//
// 沙箱里没有 DOM，兼容层提供的是**够用的子集**：
//   支持：标签 / .类 / #id / [属性] / [属性=值] / [属性*=值] / [属性^=值] / [属性$=值]、
//         后代（空格）、子代（>）、逗号分组；
//   不支持并**明确报错**：伪类（:nth-child / :first-child）、兄弟选择器（+ / ~）——
//         报错比按错的规则抓到一堆脏数据好。
//
// BASE_URL 改成你自己的测试站点即可。
var BASE_URL = 'http://127.0.0.1:8080';

class VeneraDemoHtml extends ComicSource {
  name = 'Venera 示例源（HTML）';
  key = 'venera-demo-html';
  version = '1.0.0';
  minAppVersion = '1.0.0';
  url = '';

  explore = [
    {
      title: '列表页',
      type: 'multiPageComicList',
      load: async (page) => {
        const html = await this.getText('/page/list.html?page=' + page);
        const document = new HtmlDocument(html);
        const nodes = document.querySelectorAll('div.list > a.item');
        const comics = [];
        for (let i = 0; i < nodes.length; i++) {
          const node = nodes[i];
          const image = node.querySelector('img');
          comics.push({
            id: String(node.attributes['data-id']),
            title: image ? String(image.attributes['alt']) : String(node.text).trim(),
            cover: this.absolute(image ? image.attributes['src'] : ''),
          });
        }
        document.dispose();
        if (comics.length === 0) {
          throw new Error('列表页没解析出条目（页面结构改了吗？）');
        }
        return { comics: comics, maxPage: 2 };
      },
    },
  ];

  loadInfo = async (id) => {
    const json = await this.getJson('/api/detail?id=' + encodeURIComponent(id));
    const item = (json && json.item) || {};
    return {
      title: item.title || id,
      cover: item.cover || '',
      description: item.description || '',
      chapters: { 'ch-1': '第 1 话', 'ch-2': '第 2 话' },
    };
  };

  loadEp = async (comicId, epId) => {
    const json = await this.getJson(
      '/api/content?id=' + encodeURIComponent(comicId)
      + '&chapterId=' + encodeURIComponent(epId)
    );
    return { images: (json && json.images) || [] };
  };

  // 探针（测试用）：回报 HTML 选择器子集的行为。
  async probeSelectors() {
    const html = '<div class="box"><p class="a" data-x="1">甲</p>'
      + '<p class="a b" data-x="2">乙</p><span id="tail">丙</span></div>';
    const document = new HtmlDocument(html);
    const classes = document.querySelectorAll('.a');
    const byAttribute = document.querySelector('p[data-x="2"]');
    const byId = document.getElementById('tail');
    const texts = [];
    for (let i = 0; i < classes.length; i++) texts.push(String(classes[i].text));
    let unsupported = '';
    try {
      document.querySelectorAll('p:nth-child(2)');
    } catch (error) {
      unsupported = String(error.message || error);
    }
    document.dispose();
    return {
      matched: texts.join(','),
      attributeText: byAttribute ? String(byAttribute.text) : null,
      idText: byId ? String(byId.text) : null,
      unsupported: unsupported,
    };
  }

  absolute(url) {
    const value = String(url || '');
    if (!value) return '';
    if (value.indexOf('http://') === 0 || value.indexOf('https://') === 0) return value;
    return BASE_URL + (value.charAt(0) === '/' ? value : '/' + value);
  }

  async getText(path) {
    const res = await Network.get(BASE_URL + path);
    if (res.status !== 200) {
      throw new Error('拉取失败：HTTP ' + res.status + ' ' + path);
    }
    return res.body || '';
  }

  async getJson(path) {
    return JSON.parse(await this.getText(path) || 'null');
  }
}
