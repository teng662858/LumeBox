# 本地补丁说明（third_party/quickjs_engine）

本目录是 **`quickjs_engine` 0.1.6 的本地 vendored 副本**（来自 pub 镜像
`pub.flutter-io.cn`，上游仓库见插件 `pubspec.yaml` 的 `repository` 字段），
`pubspec.yaml` 以**路径依赖**引用它。保留 vendored 副本的唯一原因是携带下面这一处补丁。

## 补丁 1 · 导出 `JS_SetInterruptHandler`（安全关键）

**文件**：`native/cxx/libfastdev_quickjs_runtime.cpp`

**改动**：新增一个导出包装函数（约 20 行，含注释）：

```c
DLLEXPORT void jsSetInterruptHandler(JSRuntime *rt, JSInterruptHandler *cb, void *opaque)
{
    JS_SetInterruptHandler(rt, cb, opaque);
}
```

**为什么必须打**：插件用 `C_VISIBILITY_PRESET hidden` 编译 quickjs，且
`JS_EXTERN` 在 Windows 上只有定义了 `BUILDING_QJS_SHARED` 才展开（插件从未定义），
因此 `JS_SetInterruptHandler` **不在动态符号表里**。后果是 quickjs 唯一回宿主
的通路断掉：

- 纯 CPU 空转脚本（`while(true){}`）无法被中断，墙钟预算 / 内存上限 / 微任务预算
  **全部失效**，JSContext 无法销毁（已实测：预算 3s，等待 12s 仍未收尾）；
- 灾难性正则回溯（`/(a+)+$/`）同样不可中断——它会占住调用线程并让整个测试进程挂死
  （实测：跑一次该用例，测试进程 15 分钟不返回，后续用例全部 `did not complete`）。

quickjs 本体是支持的：解释器热路径每 10000 条指令轮询一次
（`js_poll_interrupts` → `__js_poll_interrupts` → `rt->interrupt_handler`），
正则引擎走同一条通路（`lre_check_timeout` 直接调 `rt->interrupt_handler`）。
补上这一个导出即可全部生效。

**Dart 侧无需配合改动**：`lib/core/js/sandbox/sandbox_guard.dart` 的接线是按
「符号将来会出现」写的（`arm` / `shouldInterrupt` / `_onInterrupt`，
`instructionsPerTick = 10000` 与 quickjs 的 `JS_INTERRUPT_COUNTER_INIT` 一致），
`Qjs.interruptHookAvailable` 会自动变为 true。

**验证**：`test/js_sandbox/deadloop_timeout_test.dart` 的用例 `1a` 由「期望失败」
自动转为正向断言（该用例的正向分支早已写好：断言 `timeout`、`generation` 递增、
重建后同一实例可用）；`test/js_sandbox/malicious_script_test.dart` 的 `4a` 正则
回溯用例同理。

## 与上游的差异清单

除上述一处外，本副本与上游 0.1.6 **完全一致**。另外为减小仓库体积，删除了两类
非源码内容（不影响构建，因为构建入口 `native/CMakeLists.txt` 与各平台 podspec /
Package.swift 都指向 `native/cxx`）：

| 删除 | 原因 |
|---|---|
| `android/.cxx/`（15MB） | 上游发布者本机的 CMake/ninja 构建缓存（`.o` / `.ninja` / `.json`），非源码 |
| `macos/Frameworks/libquickjs_c_bridge_plugin.dylib`（2.1MB） | macOS 预编译产物；macOS 不是本项目目标平台，且该平台会从 `native/cxx` 重新编译 |

**升级上游时的做法**：把新版本重新 vendored 进来，然后照上面重新打一次补丁
（或反向 apply 本文件描述的 diff）；同时确认
`test/js_sandbox/malicious_script_test.dart` 与 `deadloop_timeout_test.dart` 仍然通过。
