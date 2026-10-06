// 这是「别的客户端的扩展程序包」的最小复刻，**不是本 App 的图源脚本**。
//
// 结构取自真实导入失败的那种包（用户实测的 6MB 猫源扩展包），按同样的形状缩小：
//   1. 载入时 require 服务端模块（http2 / net 之类）——因为包里自带一个本地服务端；
//   2. 把自带的前端与弹幕服务打成字符串，通过 websiteBundle / danmuBundle 暴露；
//   3. 靠**它自己客户端的宿主桥**（messageToDart）与宿主通信；
//   4. 不提供任何图源入口（home / category / detail / play / getList / LumeSource.*）。
//
// 用途：`test/js_sandbox/import_guard_test.dart` 用它验证两条守卫——
//   (a) 服务端模块被拦下时，文案要点名「自建服务端需要端口/进程」；
//   (b) 即使没有服务端模块，这种「零图源入口」的脚本也会在导入阶段被识别并拒绝。
var http2 = require('http2');

var server = http2.createServer(function (request, response) {
  response.end('ok');
});

globalThis.websiteBundle = function () {
  return '<html><body>本包自带的前端页面</body></html>';
};

globalThis.danmuBundle = function () {
  return '本包自带的弹幕服务前端';
};

globalThis.messageToDart = function (payload) {
  return JSON.stringify({ ok: true, payload: payload });
};

globalThis.Pans = {
  getPanName: function () { return '本包自带的网盘适配'; },
  getPanEnabled: function () { return true; }
};
