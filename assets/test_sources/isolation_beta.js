// LumeSource: {"id":"test-iso-beta","name":"隔离测试源 B","version":"1.0.0"}
//
// 冒烟测试样板（安全测试第 2 条 · 乙）：与 isolation_alpha.js 成对使用。
//
// 乙写入自己的全局标记与沙盒文件，并检查甲的痕迹是否可见。
// 预期：完全看不见——两个图源各占一个 JSRuntime + JSContext，互不共享状态。
// 脚本不含任何网络抓取逻辑。
var LumeSource = {
  id: 'test-iso-beta',
  name: '隔离测试源 B',
  version: '1.0.0',

  // 与甲同名的字段、不同的值：验证「同名全局也不串线」。
  __lumeIsolationMark: 'beta',

  async categories() {
    return [{ id: 'c1', title: '分类一' }];
  },

  async list(argument) {
    await this.__ensureMarker();
    return {
      items: [
        { id: 'beta', title: '乙源条目' },
        { id: 'beta-page', title: 'page=' + (argument && argument.page ? argument.page : 1) }
      ],
      hasMore: false
    };
  },

  async detail(argument) {
    return { id: 'beta', title: '乙源详情' };
  },

  async chapters(argument) {
    return [{ id: 'beta-ch', title: '乙源章节' }];
  },

  async content(argument) {
    return { kind: 'text', text: '乙源内容' };
  },

  // 写入本源的全局标记与沙盒文件（幂等）。
  async __ensureMarker() {
    globalThis.__LUME_ISO_BETA__ = 'beta-value';
    if (!globalThis.__LUME_ISO_BETA_WRITTEN__) {
      globalThis.__LUME_ISO_BETA_WRITTEN__ = true;
      await LumeSource.fs.writeText('probe/owner.txt', 'beta');
      await LumeSource.fs.writeText('probe/beta-only.txt', 'beta-only');
    }
  },

  // 探针（冒烟测试专用）：报告本上下文里自己与他人的可见性。
  async probe() {
    await this.__ensureMarker();
    var foreign = 'undefined';
    try {
      foreign = typeof globalThis.__LUME_ISO_ALPHA__;
    } catch (error) {
      foreign = 'error';
    }
    var owner = await LumeSource.fs.readText('probe/owner.txt');
    return {
      self: String(globalThis.__LUME_ISO_BETA__),
      selfOwnField: String(this.__lumeIsolationMark),
      foreignAlpha: foreign,
      storeOwner: owner == null ? null : String(owner),
      storeKeys: await LumeSource.fs.list()
    };
  }
};
