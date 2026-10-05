/// 听书体系（Phase2 小说增强）。
///
/// 分层与画中画同构：
/// - [SpeechSegments]：纯逻辑切分——章节文本 → 朗读片段（含整章字符起点），
///   跟读翻页与断点续听都靠它把「引擎位置」换算成「整章偏移」；
/// - [SpeechSession]：状态机 + 队列 + 位置换算，页面只跟它打交道；
/// - [SpeechBackend]：平台能力端口，iOS 走 AVSpeechSynthesizer，
///   其余平台如实降级为不支持（页面显示占位，不假装能用）；
/// - [SpeechSettings]：语速 / 音调 / 音量 / 跟读开关，按板块存在阅读库里。
///
/// 为什么不用第三方 TTS 插件：原生 `AVSpeechSynthesizer` 已覆盖需求
/// （离线、系统语音、逐字位置回调），引入插件只为包装一层薄接口不划算；
/// 且与画中画一致——平台能力用端口 + 可注入替身，测试在没有原生库的机器上
/// 也能跑完整链路。
library;

export 'speech_channel.dart';
export 'speech_segments.dart';
export 'speech_session.dart';
export 'speech_settings.dart';
