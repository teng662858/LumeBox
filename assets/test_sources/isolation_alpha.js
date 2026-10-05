// LumeSource: {"id":"test-iso-alpha","name":"隔离测试源 A","version":"1.0.0"}
//
// 冒烟测试样板（安全测试第 2 条 · 甲）：在自己的上下文里设置全局变量与沙盒文件。
//
// 与 isolation_beta.js 成对使用：两份脚本互不知情，各自写入自己的全局标记与
// 沙盒存储，再用 probe() 回读「自己看得见什么、别人看得见什么」。
// 预期：甲的上下文里看不见乙的任何状态，反之亦然。
// 脚本不含任何网络抓取逻辑。
var LumeSource = {
  id: 'test-iso-alpha',
  name: '隔离测试源 A',
  version: '1.0.0',

  // 与乙同名的字段、不同的值：验证「同名全局也不串线」。
  __lumeIsolationMark: 'alpha',

  async categories() {
    return [{ id: 'c1', title: '分类一' }];
  },

  async list(argument) {
    await this.__ensureMarker();
    return {
      items: [
        { id: 'alpha', title: '甲源条目' },
        { id: 'alpha-page', title: 'page=' + (argument && argument.page ? argument.page : 1) }
      ],
      hasMore: false
    };
  },

  async detail(argument) {
    return { id: 'alpha', title: '甲源详情' };
  },

  async chapters(argument) {
    return [{ id: 'alpha-ch', title: '甲源章节' }];
  },

  async content(argument) {
    return { kind: 'text', text: '甲源内容' };
  },

  // 写入本源的全局标记与沙盒文件（幂等）。
  async __ensureMarker() {
    globalThis.__LUME_ISO_ALPHA__ = 'alpha-value';
    if (!globalThis.__LUME_ISO_ALPHA_WRITTEN__) {
      globalThis.__LUME_ISO_ALPHA_WRITTEN__ = true;
      await LumeSource.fs.writeText('probe/owner.txt', 'alpha');
      await LumeSource.fs.writeText('probe/alpha-only.txt', 'alpha-only');
    }
  },

  // 探针（冒烟测试专用）：报告本上下文里自己与他人的可见性。
  async probe() {
    await this.__ensureMarker();
    var foreign = 'undefined';
    try {
      foreign = typeof globalThis.__LUME_ISO_BETA__;
    } catch (error) {
      foreign = 'error';
    }
    var owner = await LumeSource.fs.readText('probe/owner.txt');
    return {
      self: String(globalThis.__LUME_ISO_ALPHA__),
      selfOwnField: String(this.__lumeIsolationMark),
      foreignBeta: foreign,
      storeOwner: owner == null ? null : String(owner),
      storeKeys: await LumeSource.fs.list()
    };
  },

  // 失控探针（安全测试专用）：分配型失控，用于验证「污染 → 销毁 → 重建」。
  // 只申请内存、不做任何 IO，触发沙箱的内存上限。
  async runaway() {
    var junk = [];
    for (;;) {
      junk.push(new Array(10000).fill('x'));
    }
  }
};
