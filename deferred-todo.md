# Lume Box 待办清单

## 已完成
- [✓] 移除卡片仪表盘首页，实现移动端底部悬浮Dock Tab导航，Windows侧边栏NavigationRail
- [✓] UI文字“自定义视频”改为“视频”，底层id、数据库、缓存不变
- [✓] 四大板块页面右上角统一增加+添加图源按钮；支持本地JS、远程订阅导入，归属当前板块
- [✓] JS导入预处理stripScriptBom，修复UTF‑8 BOM导致LumeSource元信息识别失败
- [✓] 四大板块右上角统一「图源管理」入口（打开本板块图源管理页）；播放器设置迁到设置Tab与播放控制栏齿轮
- [✓] QuickJS‑NG 宿主注入桥接全局 LumeSource（HTTP + 沙盒文件IO），函数式脚本（顶层 getList 等）可直接运行

## Phase1 待完成（最小可用版本）
- [ ] MPV播放器完整适配AbstractPlayer抽象层，实现HUD参数展示
- [ ] 图源管理完善UI：测试连通性、订阅源更新（启用/禁用、重命名、删除、导出已完成）
- [ ] 网络层：全局并发、单域名并发限制，全局/单图源UA、代理配置，指数退避重试
- [ ] 缓存体系UI：分板块缓存清理，缓存最大容量、过期策略配置

## Phase2待完成
- [ ] 漫画阅读器全套功能
- [ ] 小说自研CustomPainter分页阅读器
- [ ] 图片/文本预加载优化

## Phase3待完成
- [ ] QuickJS‑NG Node Polyfill垫片（iOS猫源脚本兼容，process/Buffer/require 只对猫源注入的边界是否放开待定）
- [ ] 弹幕系统、播放器高级手势、画中画完善
- [ ] 追剧日历、图源可视化编辑器
- [ ] Windows/Android Node‑Mobile猫源兼容层

## 预留扩展（暂不开发）
- WebDAV同步、Bangumi账号绑定、批量图源校验工具
- 沙盒文件IO持久化（当前为按图源隔离的进程内存储，重启即清空）
