import 'package:lume_box/shared/widgets/lume_icon.dart';
import 'package:flutter/material.dart';

import '../../core/theme/lume_theme.dart';
import '../../shared/widgets/glass_card.dart';
import 'settings_ui.dart';

/// 应用内「使用说明」：把当前版本已经上线的功能入口、填写方式与平台限制
/// 集中写在一处，用户不需要去仓库翻文档。
///
/// 维护口径：
/// - 只写**已经存在**的入口与能力；暂缓 / 未实现的功能不要出现在这里。
/// - 平台限制如实写：设备端超分、设备端翻译目前仅 iOS；设备端翻译需要
///   iOS 18 及以上。
/// - 云端接口的字段、HTTPS / 不跟随重定向、密钥只进钥匙串这些约束，与
///   `speech_cloud.dart` / `comic_image_tools.dart` 的实现保持一致。
class UsageGuidePage extends StatelessWidget {
  const UsageGuidePage({super.key});

  @override
  Widget build(BuildContext context) => GlassScaffold(
    effectModule: GlassModule.settings,
    title: '使用说明',
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const _IntroCard(),
          for (final section in _sections) _GuideSectionCard(section: section),
          const SettingsFooterNote(
            '本页只说明当前版本已经上线的功能；入口名称、平台支持与可用参数以实际版本为准。',
            padding: EdgeInsets.fromLTRB(4, 4, 4, 8),
          ),
        ],
      ),
    ),
  );
}

class _IntroCard extends StatelessWidget {
  const _IntroCard();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: GlassCard(
      radius: 14,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '按功能分区说明怎么用',
            style: TextStyle(
              fontSize: LumeTypography.titleSize,
              fontWeight: FontWeight.w600,
              color: LumeTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '第一次使用先看「第一次使用」；听书、漫画处理、播放器与备份各有独立一节。'
            '点击标题展开或收起。',
            style: TextStyle(
              fontSize: LumeTypography.bodySize,
              height: 1.6,
              color: LumeTheme.textSecondary,
            ),
          ),
        ],
      ),
    ),
  );
}

class _GuideSection {
  const _GuideSection({
    required this.icon,
    required this.title,
    required this.summary,
    required this.body,
    this.initiallyExpanded = false,
  });

  final IconData icon;
  final String title;
  final String summary;
  final String body;
  final bool initiallyExpanded;
}

class _GuideSectionCard extends StatelessWidget {
  const _GuideSectionCard({required this.section});

  final _GuideSection section;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: GlassCard(
      radius: 14,
      padding: EdgeInsets.zero,
      child: ExpansionTile(
        key: PageStorageKey<String>(section.title),
        initiallyExpanded: section.initiallyExpanded,
        leading: LumeIcon(
          section.icon,
          slot: 'usage_guide_page.1',
          variant: true,
          size: 22,
          color: LumeTheme.textSecondary,
        ),
        title: Text(
          section.title,
          style: TextStyle(
            fontSize: LumeTypography.titleSize,
            fontWeight: FontWeight.w600,
            color: LumeTheme.textPrimary,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(
            section.summary,
            style: TextStyle(
              fontSize: LumeTypography.descriptionSize,
              height: 1.5,
              color: LumeTheme.descriptionColor,
            ),
          ),
        ),
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        shape: const Border(),
        collapsedShape: const Border(),
        iconColor: LumeTheme.textSecondary,
        collapsedIconColor: LumeTheme.textSecondary,
        children: <Widget>[
          Text(
            section.body,
            style: TextStyle(
              fontSize: LumeTypography.bodySize,
              height: 1.7,
              color: LumeTheme.textPrimary,
            ),
          ),
        ],
      ),
    ),
  );
}

const List<_GuideSection> _sections = [
  _GuideSection(
    icon: Icons.rocket_launch_outlined,
    title: '第一次使用',
    summary: '导入源 → 选源 → 打开条目',
    initiallyExpanded: true,
    body: '''
1. 在漫画 / 美图 / 视频 / 影视板块右上角点「+」，可以：
   · 选择本地脚本文件（可多选）；
   · 直接粘贴脚本内容；
   · 填订阅地址（http / https）。
2. 也可以在「设置 → 数据与网络 → 总订阅导入导出」里粘贴总订阅地址，一次导入多个板块；导入前会先预览，确认后才写入。
3. 导入完成后，点板块页顶部的源名切换源；点条目进详情，视频点集号直接开始播放。
4. 导入弹窗里的「载入内置示例」可以先用内置的示例 / 薄壳脚本试通流程。''',
  ),
  _GuideSection(
    icon: Icons.dns_outlined,
    title: '源与订阅',
    summary: '更新、排序、失效标记与网页视图',
    body: '''
· 更新：订阅页顶部「一键更新全部订阅」；单条源在「更多 / 站点设置」里更新。更新只覆盖脚本、名称与版本，不动书架、进度与收藏。
· 私有 GitHub 订阅：设置 → 内容与订阅 → 源管理 → 私有 GitHub 订阅，填写仓库、分支和仅有 Contents 读取权限的 Token，测试连接并保存。再使用该仓库的 raw.githubusercontent.com 订阅地址；Token 保存在本机，不进入订阅链接和备份。私有仓库不提供公开 CDN 线路。
· 排序：在源管理里长按整个源条目拖动；普通源支持详细 / 紧凑排列与两列网格，猫源支持 1 / 2 / 3 列。
· 失效：连续失败 3 次的源会被标记失效并停止自动重试，可在源管理里手动恢复。
· 每个源都可以单独配置 UA / Cookie / 代理；留空则继承全局网络设置。
· 被 Cloudflare 等 WAF 拦下时，列表页会出现「网页视图」：在 App 内完成人机校验后点关闭，会话会自动保存并重试。部分站点需要先在电脑上运行桥接服务，再到「源管理 → 网络配置 → 桥接服务地址」填写地址。
· 猫源是独立板块：订阅、站点管理与普通板块分开。''',
  ),
  _GuideSection(
    icon: Icons.headphones_outlined,
    title: '小说与漫画朗读',
    summary: '五种朗读模式、多人音色与连续翻页',
    body: '''
在小说或漫画阅读器中打开朗读设置，可选择系统、本地或在线语音。漫画默认连续朗读至本章末，也可选择只读本页。

【小说多人音色】
在小说阅读器打开朗读设置，开启“自动识别对话并切换音色”，依次点击“旁白音色”“男声音色”“女声音色”选择不同声音，返回阅读页开始朗读。普通模式主要识别“角色名：台词”，可能判断错误；在线 AI 增强需配置大模型接口。当前最多三类音色，不支持四个具体人物各配一种声音。

【朗读模式】
1. 系统自带 TTS：不联网、零成本，声音偏机械。
2. 本地离线 VITS · sherpa-onnx：在听书设置选择sherpa-onnx离线朗读，下载约 147 MB 的音色包并校验安装；也可从文件安装官方压缩包。安装后可选 174 个音色，离线使用；音色包可在设置中删除。
3. Kokoro 离线朗读：首次下载约 147 MB 音色包；安装后可离线使用。
4. 在线云端 TTS · 简易（正则）：点「配置在线接口与密钥」，先在「TTS 服务商」里选：
   · OpenAI 兼容：填 TTS 地址、TTS 模型、TTS API-Key（兼容 /audio/speech）。
   · Azure Speech：填 Azure 区域（如 eastasia）与 Speech 密钥；音色填完整名称（如 zh-CN-XiaoxiaoNeural）。
   · 火山引擎：填 AppID、Access Token 与 Cluster（默认 volcano_tts）；音色填 voice_type（如 BV700_streaming）。
   三家都返回 24kHz 单声道 PCM；用正则区分旁白与对话，不消耗大模型 Token。
5. 在线云端 TTS · AI 增强：在同一弹窗再填大模型地址、名称与 API-Key（Chat Completions）。AI 会分析整章的旁白 / 男声 / 女声与停顿；网络错误、格式错误或 15 秒超时会自动退回模式 3，不会中断听书。

【接口填写要点】
· OpenAI 兼容与大模型地址必须是 HTTPS，不能带用户名、查询参数或 # 片段；App 不跟随重定向。
· TTS 地址可以只填到域名或 /v1，保存时自动补 /v1/audio/speech；大模型同理补 /v1/chat/completions。
· Azure 与火山引擎走各自固定主机，只需填区域 / AppID；切换服务商或改区域、AppID 后要重新填写对应密钥。
· 音色沿用 alloy / onyx / nova 时会映射到常见中文音色；要指定服务商自己的音色，请填完整名称。
· 密钥保存在设备钥匙串，不写进配置备份；同一密钥记录绑定填写的地址，换地址后要重新保存。
· 打开「自动识别对话并切换音色」才会区分旁白 / 男声 / 女声；关闭后全程使用旁白音色。
· 语速、音调、音量、音色按模式分别保存。

【其他】
· 阅读器目录右上角的顺序下拉是「自动排序 / 正序 / 倒序」：自动排序按章节号修正乱序，不改源数据与阅读进度。
· 后台播放打开后，离开 App 仍可朗读，锁屏 / 控制中心 / 耳机键可控制。''',
  ),
  _GuideSection(
    icon: Icons.auto_stories_outlined,
    title: '漫画与美图',
    summary: '阅读设置、翻译、超分与模型管理',
    body: '''
【阅读】
· 漫画 / 美图阅读器的顶栏「阅读设置」里有翻页方向、单页 / 双页 / 瀑布流、页间距、背景、点击翻页、双击缩放、保存本页等。
· 目录右上角的顺序下拉是「自动排序 / 正序 / 倒序」；章节行与漫画详情页使用同一套触摸高度与行距。
· 长按图片可以保存或复制图片地址；详情页可以批量下载（全部 / 未读 / 仅当前章）。
· 阅读设置里的「当前页 AI 超分 / 上色 / 翻译」只处理当前这一页，保留原图对照，结果可保存或分享；原图与下载文件不会被覆盖。

【漫画朗读（OCR + 同一套 TTS）】
· 阅读时点画面中间呼出底部面板，点耳机图标打开「漫画朗读」。
· 先选听书模式与旁白音色（共用系统 / 本地 / 在线 TTS；Azure、火山引擎在「配置在线接口与密钥」里选）。
· 「朗读本页」只读当前页；「读到本章末」从当前页开始逐页识别、逐页朗读，读完自动翻到下一页。
· 漫画按 OCR 识别文字，单说话人：不区分旁白与男女声；设备端文字识别目前仅 iOS。
· 识别结果按从上到下、同一行从左到右排序；没有识别到文字的页会跳过。

【漫画翻译（设置 → 阅读与播放 → 漫画翻译）】
· 选择「翻译为」与「原文语言」（可自动识别）。
· 设备端（免费）：iOS 18 及以上，使用系统识别与翻译；首次使用可能按提示下载语言包。
· 提前下载：进入「设置 → 阅读与播放 → 全局翻译 → 语言包」，一键下载全部未安装语言包；各个源与漫画设备端翻译共用。iOS 可能逐项要求确认，仅支持系统提供的语种。
· 自填 AI 接口：填完整的 Chat Completions HTTPS 地址、模型名称与 API-Key；只发送识别出的文字，费用由服务商决定。密钥保存在钥匙串，不进入备份。
· 译文按 OCR 识别到的位置覆盖显示，不做整页重绘。

【AI 超分与上色（设置 → 阅读与播放 → AI 图片超分与上色）】
· 手动处理：点「选择本地图片进行 AI 超分」选图。
· 模型：点「安装内置模型（8 个）」安装随 App 提供的 waifu2x 模型；也可以「从本地安装超分模型」选择 .mlmodel（按 SHA256 识别类型，无需改名）；安装后点「加载当前已安装模型」；「清理模型编译缓存」只清编译缓存，保留原始模型。
· 设备端超分与设备端翻译目前仅 iOS；失败会保留原图。图片超过 400 万像素不超分，识别上限 800 万像素。
· 「AI 上色」是实验性的云端功能：使用你自填的 OpenAI 兼容图片编辑接口（需返回 b64_json），图片会上传，费用由服务商决定；密钥与 AI 翻译共用。''',
  ),
  _GuideSection(
    icon: Icons.play_circle_outline,
    title: '视频与播放器',
    summary: '内核、手势、字幕、弹幕、画中画与后台播放',
    body: '''
· 浏览页点条目进入独立播放页；详情页选集与「继续播放」会从上次位置接着播。
· 控制栏：播放 / 暂停、±10 秒、进度、清晰度 / 线路、弹幕、画中画、自动连播、全屏；齿轮打开播放器设置。
· 播放内核：AVPlayer / MPV / MDK 三选一；倍速、画面、字幕等设置按内核分别保存。MPV 初始化失败会自动回退 AVPlayer，也可在「各模块独立设置 → 播放器设置」里重试。
· 手势：左侧上下滑调亮度、右侧上下滑调音量、横滑调进度、长按临时倍速；灵敏度、一屏跨度秒数与长按倍率可调。锁屏时手势停用。
· 画面：缩放、旋转、镜像；全屏方向可自动（按视频比例）、强制横屏或强制竖屏。
· 字幕：内置字幕轨切换、外挂字幕、字号 / 颜色 / 描边 / 底色 / 延迟；音频可切音轨并调延迟。
· 弹幕：开关、透明度、字号、显示区域、速度、描边、同屏上限、屏蔽词、避让字幕。
· 公共弹幕：在弹幕设置里的「弹幕服务地址」选择 Cynn、Wenjian、官方服务或自定义 HTTPS 地址；官方服务需按服务方要求申请应用凭证。匹配不唯一时手动选择作品与集数。
· 清晰度由源返回的线路决定；只有一条线路时不会凭空生成清晰度。
· 画中画：使用系统画中画；非 MPV 内核会先切到 MPV（有提示）。
· 后台播放：在「设置 → 阅读与播放 → 播放器设置」里的「后台播放」开关打开后，视频退到后台继续播放音频。''',
  ),
  _GuideSection(
    icon: Icons.route_outlined,
    title: '续播、下载与故障恢复',
    summary: '换源接着看、全局下载、追更、外观与性能采集',
    body: '''
· 换源续播：详情页「保持集数换源」携带当前集数与时间点；匹配唯一时自动选中，季数不明确或多个线路同集时先确认。解析失败和播放器失败页也有恢复入口。
· 下载中心：漫画详情页添加批量下载后，退出详情页继续执行。在「设置 → 存储与安全 → 下载中心」暂停、继续或重试失败章节；重开 App 后恢复任务清单，点继续会跳过已下载图片。iOS 挂起 App 时网络传输可能暂停。
· 收藏追更：检查章节 ID、集名及发布时间；章节总数没变的补集也会识别。首次检查用于建立基准；空响应不清除已有基准。
· 源故障：源体检保留最近检测时间，并提供网页验证、登录、更新源重测及图片／网络设置入口。体检能解析地址不等于真机一定可以解码起播。
· 聚合搜索：结果布局菜单可切到「同名作品合并」，按匹配度、更新集数或最近七天的体检可用情况排序。片名与年份相同才合并，进入时仍需核对季数和版本。
· TMDB：从详情页评分小标进入设置可预览当前海报，选择柔和／明亮／原图预设；开启「仅此作品使用」不会改变其他作品。关闭该选项恢复全局外观。
· 设置定位：在设置首页搜索「背景亮度」「渐变强度」「Logo」等，可直接打开相应滑杆。
· 流畅度：「设置 → 诊断与关于 → 流畅度采集」开始后可返回其他页面操作，回来结束并复制报告。报告区分 Debug／Profile／Release；真机验收建议使用 Profile 构建。性能报告也会随诊断包导出。
''',
  ),
  _GuideSection(
    icon: Icons.live_tv_outlined,
    title: 'Bangumi 追番同步',
    summary: '账号绑定、搜索结果确认与按集同步',
    body: '''
【绑定账号】
· 设置 → 数据与网络 → Bangumi 追番同步。
· 在 Bangumi 个人设置 → 开放接口创建 Access Token，粘贴后点「保存并连接」；连接成功会显示昵称。
· 令牌只用于 api.bgm.tv 认证：iOS 存系统钥匙串，其它平台存本机文件，不写入配置备份。

【绑定作品】
· 打开视频详情页，点右上角的电视图标「Bangumi 追番」。
· 搜索番剧名，在结果里手动点选正确的条目；App 不会只凭标题自动绑定，避免把进度写到别的作品。
· 绑定成功后会拉取章节列表，并立即同步一次当前进度。

【同步规则】
· 播放中每次进度落盘都会检查：把看到第几集写成 Bangumi 的「看过」集数，收藏状态写为「在看」。
· 最后一集看完后改为「看过」。
· 自动同步开关在设置页；关闭只影响播放中的自动写入，手动「立即同步」仍可用。
· 同步失败只写日志，不影响播放和本地进度；可在面板里「解除绑定」或换一个条目。''',
  ),
  _GuideSection(
    icon: Icons.bookmarks_outlined,
    title: '收藏、历史与搜索',
    summary: '历史抽屉、收藏文件夹与聚合搜索',
    body: '''
· 历史：板块页右上角的时钟图标打开底部抽屉；可续看、删单条、清空。漫画的抽屉还有「收藏」页签。
· 无痕模式：会跳过阅读 / 播放进度与搜索历史的写入。
· 收藏：详情页与列表可以收藏；收藏页可以新建文件夹、移动收藏、按文件夹筛选。各板块收藏互相独立。
· 搜索：工具栏放大镜；可选「聚合搜索」（并发问所有已启用源）或「当前源」。联想优先使用源提供的 suggest，没有则用本地历史；输入有 300ms 防抖，没有输入时显示最近 20 条本地历史，可一键清空。
· 设置 → 数据与网络 → 搜索：可开「搜索自动繁转简」与「精确搜索」。''',
  ),
  _GuideSection(
    icon: Icons.shield_outlined,
    title: '数据、备份与隐私',
    summary: '配置备份、缓存、应用锁与成人内容',
    body: '''
· 配置备份：设置 → 存储与安全 → 配置备份。可导出 / 恢复 JSON；自动备份每天使用 App 时执行一次，保留最近 7 份，也可立即备份或恢复自动备份。备份包含全局设置、各板块偏好与源配置；TTS / AI 密钥保存在系统钥匙串，不进入备份。
· 缓存管理：设置 → 存储与安全 → 缓存管理，按板块清理磁盘与内存缓存。漫画板块的图片缓存已关闭，阅读页不落盘。
· 应用锁：设置 → 存储与安全 → 隐私。使用系统面容或本机锁屏密码，不设置额外密码；启用、关闭、更换方式前都要验证。离开前台与冷启动会遮挡页面，后台期间的旧认证结果不能解锁。
· 显示成人内容：默认关闭，按已识别的源与名称过滤入口、列表与收藏；关闭只影响显示，不删除数据。未知来源不保证自动识别。
· 内容分类显示：设置 → 导航与首页 → 内容分类显示，可隐藏漫画 / 美图 / 视频 / 影视入口；数据不受影响。
· App 图标、主题与配色在「设置 → 个性与界面」；导航、首页布局与液态玻璃在「设置 → 导航与首页」。原生系统导航可调导航栏高度、图标、颜色、左右留白及安全区距离；负距离向下移动，实时保存。''',
  ),
  _GuideSection(
    icon: Icons.help_outline,
    title: '常见问题',
    summary: '源失败、没声音、接口报错、超分不可用、版本确认',
    body: '''
· 源列表加载失败：先点「重试」；被 Cloudflare / WAF 拦下时点「网页视图」完成校验；需要外部桥接的源按提示填「桥接服务地址」。仍失败可在「设置 → 诊断与关于 → 运行日志 / 错误报告」里看具体原因。
· 听书没声音或报错：确认当前模式；本地模式先安装音色包；在线模式检查 HTTPS 地址、模型名与 API-Key；换过地址后要重新保存密钥；AI 模式失败会自动退回简易模式。再检查系统静音、音频会话是否被其他 App 占用。
· 在线接口返回 401 / 403 / 404：检查 API-Key、模型名和接口路径。TTS 需要兼容 /v1/audio/speech（返回 24kHz 单声道 PCM），AI 增强需要 /v1/chat/completions；接口不能重定向。
· 超分 / 翻译不可用：设备端能力仅 iOS；设备端翻译需要 iOS 18+ 并可能下载语言包；先确认内置模型已安装并「加载当前已安装模型」；图片过大时会跳过超分并保留原图。
· 确认版本：设置 → 诊断与关于 → 关于 LumeBox，会显示「版本 x.y.z（构建 n）」；点一下可复制，方便和安装包文件名对照。''',
  ),
];
