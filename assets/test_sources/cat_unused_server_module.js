// LumeSource: {"id":"cat-unused-server-module","name":"猫源夹具（require 了没用的服务端模块）","version":"1.0.0","category":"cat"}
//
// 真机回归夹具：**一份正经猫源脚本，顺手 require 了沙箱不支持的模块**。
//
// 真机实测：一份订阅源导入失败，报「猫源沙箱不支持「http2」」。
// 那个报错本身没错，但它**发生在载入期**：只要脚本顶部写着
// `require('http2')`（哪怕整份脚本从头到尾没碰过它），整份源就被挡在门外——
// 而脚本真正发请求用的是 fetch / LumeSource.http。
// 这类「沿用别处写法、顺手 require 一堆模块」的脚本在生态里很常见。
//
// 现在的口径（本夹具守住）：
//   require 不支持的模块 → 返回一个「用到才炸」的占位；
//   **没用到** → 脚本照常导入、照常出内容；
//   **真用了**（取属性 / 调用 / new）→ 抛与以前逐字一致的可读错误。
//
// 对照夹具：foreign_client_bundle.js（载入期就起 HTTP/2 服务端）——那种包
// 仍然在载入阶段被拦下，文案点名「自建服务端」。
//
// 用法：导入猫源板块即可；分类 / 列表都走本地假数据，不依赖网络。

// ⚠️ 关键形态：载入期 require 了三个沙箱不支持的模块，但一次都不用。
var http2 = require('http2');
var net = require('net');
var childProcess = require('node:child_process');

var LumeSource = {
  id: 'cat-unused-server-module',
  name: '猫源夹具（require 了没用的服务端模块）',
  version: '1.0.0',
  category: 'cat',

  async categories() {
    return [
      { id: 'demo', title: '示例分类' },
    ];
  },

  async list(argument) {
    var page = argument && argument.page ? Number(argument.page) : 1;
    return {
      items: [
        { id: 'item-1', title: '示例条目', subtitle: '第 ' + page + ' 页' },
      ],
      hasMore: false,
    };
  },

  async detail(argument) {
    var id = argument && argument.id ? String(argument.id) : '';
    return { id: id, title: '示例条目', subtitle: '示例', description: '夹具数据' };
  },

  async chapters(argument) {
    return [{ id: 'ch-1', title: '第 1 集' }];
  },

  async content(argument) {
    return { kind: 'text', text: '夹具正文' };
  },
};
