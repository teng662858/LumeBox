import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/session/icloud_sync.dart';
import '../../shared/widgets/glass_card.dart';

class ICloudSettingsPage extends StatefulWidget {
  const ICloudSettingsPage({super.key});
  @override
  State<ICloudSettingsPage> createState() => _ICloudSettingsPageState();
}

class _ICloudSettingsPageState extends State<ICloudSettingsPage> {
  final cloud = ICloudSync.instance;
  @override
  void initState() {
    super.initState();
    unawaited(cloud.check());
  }

  @override
  Widget build(BuildContext context) => GlassScaffold(
    effectModule: GlassModule.settings,
    title: 'iCloud 同步',
    child: ListenableBuilder(
      listenable: cloud,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            leading: const Icon(Icons.cloud_outlined),
            title: Text(cloud.status),
            subtitle: Text(
              cloud.lastSync == null
                  ? '还没有成功同步记录'
                  : '上次本机同步：${cloud.lastSync!.toLocal()}',
            ),
          ),
          SwitchListTile.adaptive(
            title: const Text('自动 iCloud 同步'),
            subtitle: const Text('回到前台及前台每 5 分钟合并同步；默认关闭'),
            value: cloud.automatic,
            onChanged: !cloud.supported || cloud.busy
                ? null
                : (value) => cloud.setAutomatic(value),
          ),
          const ListTile(
            title: Text('收藏、收藏夹与阅读 / 播放进度'),
            subtitle: Text('始终参与同步；逐条合并，保留删除记录避免重新出现'),
          ),
          SwitchListTile.adaptive(
            title: const Text('同步设置'),
            subtitle: const Text('阅读和播放设置、外观、布局、悬浮与图片处理设置；不包含密钥和应用锁'),
            value: cloud.includeSettings,
            onChanged: cloud.busy
                ? null
                : (v) {
                    cloud.includeSettings = v;
                    unawaited(cloud.save());
                  },
          ),
          SwitchListTile.adaptive(
            title: const Text('同步源订阅地址'),
            subtitle: const Text('小说 / 漫画 / 视频的 JS 源订阅地址；源脚本与猫源运行包留在本机'),
            value: cloud.includeSubscriptions,
            onChanged: cloud.busy
                ? null
                : (v) {
                    cloud.includeSubscriptions = v;
                    unawaited(cloud.save());
                  },
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: !cloud.supported || cloud.busy
                ? null
                : () => cloud.sync(),
            icon: cloud.busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
            label: const Text('立即同步'),
          ),
          TextButton(
            onPressed: cloud.busy ? null : cloud.check,
            child: const Text('检查 iCloud 状态'),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text(
              '首次同步优先合并已有云端记录，保留本机新增条目；之后按条目同步版本合并。同步后返回页面刷新，部分设置需重启生效。\n\n下载图片、音视频、离线模型、Cookie、密码和 API 密钥不上传。iCloud 账号变化会暂停自动同步，需要重新开启。\n\n需要在系统设置登录 iCloud、开启 iCloud Drive，并使用包含 iCloud.com.lumebox.app 容器权限的签名。仅打开手机 iCloud 或使用普通重签名不能补齐该权限。云端传输完成时间由系统决定。',
            ),
          ),
        ],
      ),
    ),
  );
}
