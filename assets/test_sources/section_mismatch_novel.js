// LumeSource: {"id":"test-section-novel","name":"跨板块测试源（小说）","version":"1.0.0","category":"novel"}
//
// 冒烟测试样板（安全测试第 3 条）：元信息自报板块为「小说」。
//
// 用途：把这份脚本导入**漫画**板块，验证解析阶段是否直接拒绝加载，
// 并输出明确的错误日志——严格禁止跨板块混用图源。
// 反向对照：同一份脚本导入小说板块应当成功（它本来就属于小说）。
//
// 注意：头部注释与运行时 LumeSource 都声明 category，两条解析路径都要能被拦住。
// 脚本不含任何网络抓取逻辑。
var LumeSource = {
  id: 'test-section-novel',
  name: '跨板块测试源（小说）',
  version: '1.0.0',

  // 板块自报：小说。
  category: 'novel',

  async categories() {
    return [{ id: 'c1', title: '分类一' }];
  },

  async list(argument) {
    return {
      items: [{ id: 'novel-1', title: '小说条目' }],
      hasMore: false
    };
  },

  async detail(argument) {
    return { id: 'novel-1', title: '小说详情' };
  },

  async chapters(argument) {
    return [{ id: 'novel-ch-1', title: '第一章' }];
  },

  async content(argument) {
    return { kind: 'text', text: '小说正文' };
  }
};
