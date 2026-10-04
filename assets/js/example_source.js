// LumeSource: {"id":"lume-example","name":"Lume Box 示例源","version":"2.0.0"}
// Lume Box 图源脚本示例（JS 契约 v2）。
//
// 第一行是头部元信息声明（可选）：Dart 侧先剥掉 UTF-8 BOM，再正则匹配这行
// `// LumeSource: {...}`，因此带 BOM 的脚本也能被正确识别；没有这行时退回
// 读取脚本全局 LumeSource 的 id / name / version。
//
// 每个图源在独立 JSContext 中运行；网络请求一律经 fetch 桥接到 Dart 层发出。
// 本示例是纯模拟数据，不发任何请求。真实图源按同一套契约实现：
//   categories()                        → [{id, title}]
//   list({categoryId?, keyword?, page}) → {items: [{id, title, cover?, subtitle?}], hasMore?}
//                                         （也接受裸数组）
//   detail({id})                        → {id, title, cover?, subtitle?, description?} | null
//   chapters({id})                      → [{id, title}]
//   content({id, chapterId})            → {kind: 'text', text}
//                                       | {kind: 'images', images: [...]}
//                                       | {kind: 'video', url, headers?}
// 元信息由头部注释或 LumeSource 的 id / name / version 声明；id 仅允许字母数字与 . _ -。
var LumeSource = {
  id: 'lume-example',
  name: 'Lume Box 示例源',
  version: '2.0.0',

  async categories() {
    return [
      { id: 'cat-1', title: '分类一' },
      { id: 'cat-2', title: '分类二' }
    ];
  },

  async list(argument) {
    var page = argument && argument.page ? argument.page : 1;
    var categoryId = argument && argument.categoryId ? argument.categoryId : '';
    var keyword = argument && argument.keyword ? argument.keyword : '';
    var scope = keyword ? ('搜索：' + keyword)
      : (categoryId ? ('分类：' + categoryId) : '最新');
    return {
      items: [
        { id: 'demo-' + page, title: scope + ' · 示例条目 ' + page, subtitle: 'Lume Box' }
      ],
      hasMore: page < 3
    };
  },

  async detail(argument) {
    var id = argument && argument.id ? argument.id : '';
    return {
      id: id,
      title: '示例详情',
      subtitle: 'Lume Box',
      description: 'Phase1 的示例数据，用于验证数据源抽象接口的分类、列表、详情与章节链路。'
    };
  },

  async chapters(argument) {
    return [
      { id: 'chapter-1', title: '第一章' },
      { id: 'chapter-2', title: '第二章' },
      { id: 'chapter-3', title: '第三章' }
    ];
  },

  async content(argument) {
    var chapterId = argument && argument.chapterId ? argument.chapterId : '';
    return {
      kind: 'text',
      text: '示例正文（' + chapterId + '）。真实图源按所属板块返回文本、图片列表或视频地址。'
    };
  }
};
