// LumeSource: {"id":"test-deadloop","name":"死循环测试源","version":"1.0.0"}
//
// 冒烟测试样板（安全测试第 1 条）：两种失控形态。
//
// 1) list()：纯 CPU 死循环 `while(true){}`。最凶险的一类——不分配内存、
//    不触碰宿主、不产生 Promise，只在字节码层无限空转，同时绕开三条保护：
//      - 内存上限（不分配）；
//      - 宿主调用 / 微任务预算（不与外界交互）；
//      - Dart 侧墙钟超时（同步 FFI 调用期间事件循环没有机会运行）。
//    唯一能夺回控制权的手段是原生中断处理器（JS_SetInterruptHandler）。
//
// 2) boundedOverrun()：有限但超预算的 CPU 空转（默认 5 秒后返回）。
//    它验证「预算到期必须判定超时」这条口径——脚本最终返回了，
//    但已经远超 3–5 秒预算，不能被当成成功结果。
//
// 脚本不含任何网络抓取逻辑，只做失控模拟。
var LumeSource = {
  id: 'test-deadloop',
  name: '死循环测试源',
  version: '1.0.0',

  async categories() {
    return [{ id: 'c1', title: '分类一' }];
  },

  // 无限空转：进入即不返回。
  async list(argument) {
    while (true) {}
  },

  // 有限空转：spinMs 毫秒后正常返回（用于验证超预算判定，不会挂死测试）。
  async boundedOverrun(argument) {
    var spin = argument && argument.spinMs ? Number(argument.spinMs) : 5000;
    var started = Date.now();
    while (Date.now() - started < spin) {}
    return { items: [{ id: 'spun', title: '空转 ' + spin + 'ms 后返回' }], hasMore: false };
  },

  async detail(argument) {
    return { id: argument && argument.id ? argument.id : '', title: '详情' };
  },

  async chapters(argument) {
    return [{ id: 'ch-1', title: '第一章' }];
  },

  async content(argument) {
    return { kind: 'text', text: '内容' };
  }
};
