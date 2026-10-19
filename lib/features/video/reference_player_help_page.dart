import 'package:flutter/material.dart';

import '../../core/intro/intro_models.dart';

/// Shared by the switch descriptions and the in-app guide.
const introMethodHelp = <String, String>{
  'theIntroDB': '先在视频的“片头片尾”中填写 TMDB 作品 ID、季号；集号随当前选集。查询不到或版本时长不符会继续其他方案。',
  'introDB': '需要填写 IMDb 作品 ID（tt 开头）。与 TheIntroDB 独立查询，可只开启其中一个。',
  'chapters': '读取视频自带的 OP、ED、前情回顾等章节时间；文件没有章节时会继续其他方案。',
  'mkvTags': '读取 MKV 章节关联标签及显式片头片尾时间。网络文件需要支持分段读取；没有明确时间的标签不会自动跳转。',
  'subtitles': '从内嵌字幕的关键词与时间寻找片头片尾。当前使用 iOS 原生解析，容器或字幕格式不支持时会继续降级。',
  'filename': '读取文件名中的 OP、ED 等词和明确时间范围，例如 OP[00:05-01:35]。只有名称、没有时间时不会推测整段长度。',
  'black': '在头尾区域采样黑屏、亮度和淡入淡出边界；与其他证据组合，单独一帧黑屏不会触发跳过。',
  'silence': '寻找头尾区域的音频静默边界。建议与黑屏或场景切换同时开启，静默本身不等于片头片尾。',
  'sceneCuts': '通过相邻画面的变化频率辅助定位片头；采用稀疏采样，需要与边界信号配合。',
  'ocr': '识别片尾演职员文字及连续画面中文字上移的趋势；静止字幕不会单独作为滚动片尾证据。',
  'phash': '用图像整体结构匹配同剧同季已经学到的片段，能容忍部分亮度变化；首次没有模板时不会命中。',
  'dhash': '用画面明暗梯度匹配同季片段；需要多个时间点连续吻合，平坦黑帧不会作为模板锚点。',
  'mfcc': '用声音频谱特征匹配同季已学习片段；需要有声样本，静音不会当作可复用的音频指纹。',
  'joint': '要求音频和图像在同一时间偏移下共同吻合。证据更充分，但音轨或片头画面被替换时可能无法匹配。',
  'videoAI':
      '在 iPhone 上使用 MobileCLIP 判断前情回顾、片头、正片和片尾，再检查连续片段。属于实验性零样本分类，准确率尚待样片验证。',
  'audioAI': '使用 YAMNet 区分人声与音乐，辅助视频 AI 判断。单独开启只分析音频，不能仅凭音乐生成可靠跳过范围。',
  'manual':
      '在视频的“片头片尾”中点“记住当前位置：片头结束”或“片尾开始”，同剧后续各集自动沿用。无需作品 ID；也可展开高级选项精确调整四个起止时间。',
};

class ReferencePlayerHelpPage extends StatelessWidget {
  const ReferencePlayerHelpPage({super.key});

  @override
  Widget build(BuildContext context) {
    final heading = Theme.of(context).textTheme.titleMedium;
    Widget section(String title, String body) => Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: heading),
          const SizedBox(height: 8),
          SelectableText(body),
        ],
      ),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('参考播放器使用说明')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          20,
          16,
          20,
          MediaQuery.paddingOf(context).bottom + 24,
        ),
        children: [
          section(
            '选择播放器',
            '设置 → 阅读与播放 → 播放器方案，选择“参考播放器（新）”，下次打开视频时生效。默认仍是现有播放器，两套播放器的设置独立保存。',
          ),
          section(
            '基本操作与内核',
            '点击画面显示或隐藏控件；进度条用于跳转，锁定按钮用于防误触。播放设置中可以选择 MPV、AVPlayer 或 MDK；可用性取决于设备。MPV 支持更多画面与字幕调整，AVPlayer 使用 iOS 系统播放链，MDK 提供另一套解码路径。解码失败可按开关自动尝试其他内核；临时回退不修改你选择的默认内核。',
          ),
          section(
            '手势与设置',
            '默认左侧上下滑动调节亮度、右侧调节音量，可在播放设置中互换。长按临时倍速，松开恢复原速；中央上下滑动和双指换集可分别设置。按钮布局、缓冲、弹幕、字幕和播放日志在播放设置中调整；部分能力随内核不同而变化。',
          ),
          section(
            '开始自动识别',
            '原播放器和参考播放器共用跳过记忆。打开“片头片尾”，首次播到片头结束或片尾开始时点“记住当前位置”，后续各集自动沿用，不用填写作品 ID。只有测试社区库才需要在高级选项绑定真实 ID。默认暂停播放并保持 App 前台后才做重计算预扫描。',
          ),
          section(
            '优先级与独立开关',
            '长按拖动识别优先级。某一层获得达到最低置信度的结果后停止后续识别；关闭某个方法后，其旧缓存不会继续生效。要逐项对比，可只保留待测方法，再在视频的“片头片尾”中点“重试空闲预扫描”，通过日志确认实际运行的来源。',
          ),
          section(
            '跳过提示与手动按钮',
            '进入识别到的片段时显示倒计时，可以取消或立即跳过。取消后本集不反复提示同一段；关闭“倒计时自动跳过”后仍可手动跳过。缓冲、暂停或退出画中画后的后台状态不继续倒计时。竖屏、横屏、控件锁定及正在播放的画中画共用跳过逻辑；画中画窗口由系统控制，不显示 App 内的取消按钮，可在识别设置关闭自动跳过。前情回顾和下集预告有各自的跳过开关。',
          ),
          section(
            '记一次与高级精确标记',
            '简易按钮分别记片头结束点和片尾开始点，保存后本集不会立刻跳走。片头沿用固定起止点；片尾按距结尾的剩余时长适配后续集，下一集无需总时长相同。高级四点支持 分:秒.毫秒 或 时:分:秒.毫秒。不同作品、季、电影不混用；同一集换剪辑版本需重新确认。点“清除这部剧的跳过记忆”可重新设置。',
          ),
          Text('各识别方法', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          for (final entry in introMethodHelp.entries)
            section(IntroOptions.switches[entry.key]!, entry.value),
          section(
            '指纹如何学习',
            '社区库、章节或手动标记提供可靠时间后，空闲预扫描会学习这些片段的音视频指纹。同剧同季后续剧集可尝试匹配；没有可靠模板时应先标记一集。AI 和启发式猜测不会反过来自动训练指纹模板。',
          ),
          section(
            '资源与置信度',
            '每轮时间、采样间隔、数量和最低置信度都可调整。时间越长、间隔越短通常意味着更多耗电；较高置信度会减少命中。低电量、严重温控或内存不足会暂缓，条件恢复后可重试。默认使用后台工作线程处理，但不保证 App 被 iOS 挂起后仍能扫描。',
          ),
          section(
            '模型准备与替换',
            '内置实际模型，可点“准备／恢复内置模型”。视频模型首次解压、编译会额外占用时间和本地空间；仅音频不解压视频模型。视频替换为 Core ML 模型 ZIP，需为兼容的 MobileCLIP 模型对，或输出 recap／opening／main／ending 的标准图像分类器。音频替换需兼容 YAMNet：16 kHz 单声道、15600 个 float32 输入、521 个 AudioSet 类别输出。更换后在下一轮空闲扫描生效。',
          ),
          section(
            '日志与对比',
            '在识别设置中打开“记录来源、结果与置信度”，进入“查看识别日志”查看每层命中、未命中、错误、耗时、候选范围及 AI 分数，并可导出 JSON。只出现音频分数不代表视频 AI 已成功运行；无匹配不等于功能未开启。可清空日志重新测试。',
          ),
          section(
            '当前验收范围',
            '安卓已验证实际取帧、OCR、YAMNet 和章节跳过。MobileCLIP、各内核跳转及耗电仍以 iPhone 真机测试为准；零样本分数不是已校准的准确率。参考播放器的评论服务、DLNA 和 AirPlay 路由仍未接入，对应入口会提示当前状态。',
          ),
        ],
      ),
    );
  }
}
