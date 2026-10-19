# 离线模型下载与安装

2026-10-19 更新：1.0.163 实际已内置 VITS 分包资源，当前源码优先提供“启用内置离线音色包”，首次使用时解压并校验，不需要重复下载。waifu2x 仍按需导入；未安装时系统语音和原图显示仍可使用。

## VITS 音色包

在小说听书设置选择“启用内置离线音色包”，再选择“启用内置包”。成功后可选择本地离线朗读。也可使用“从文件安装”作为替代入口：[下载 vits-zh-aishell3.tar.bz2](https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-zh-aishell3.tar.bz2)（146,922,607 字节），保持 tar.bz2 原样，不要解压。安装前校验整个归档 SHA256，提取后逐个校验运行文件；安装失败会显示原因，可重试。

## waifu2x 超分模型

按需安装一种类型和降噪等级即可，无需全部下载。打开「设置 → AI 图片超分辨率 → 从本地安装超分模型」，选择下载的 .mlmodel 文件。文件按 SHA256 识别类型，无需重命名。安装后选择对应图片类型与降噪等级，再点击「加载当前已安装模型」。每个文件约 2.21 MB。

| 降噪级别 | 漫画 | 照片 |
| --- | --- | --- |
| 0 | [下载](https://raw.githubusercontent.com/imxieyi/waifu2x-ios/5676e6258e580e5940628811123f8402950013e3/waifu2x/models/up_anime_noise0_scale2x_model.mlmodel) | [下载](https://raw.githubusercontent.com/imxieyi/waifu2x-ios/5676e6258e580e5940628811123f8402950013e3/waifu2x/models/up_photo_noise0_scale2x_model.mlmodel) |
| 1 | [下载](https://raw.githubusercontent.com/imxieyi/waifu2x-ios/5676e6258e580e5940628811123f8402950013e3/waifu2x/models/up_anime_noise1_scale2x_model.mlmodel) | [下载](https://raw.githubusercontent.com/imxieyi/waifu2x-ios/5676e6258e580e5940628811123f8402950013e3/waifu2x/models/up_photo_noise1_scale2x_model.mlmodel) |
| 2 | [下载](https://raw.githubusercontent.com/imxieyi/waifu2x-ios/5676e6258e580e5940628811123f8402950013e3/waifu2x/models/up_anime_noise2_scale2x_model.mlmodel) | [下载](https://raw.githubusercontent.com/imxieyi/waifu2x-ios/5676e6258e580e5940628811123f8402950013e3/waifu2x/models/up_photo_noise2_scale2x_model.mlmodel) |
| 3 | [下载](https://raw.githubusercontent.com/imxieyi/waifu2x-ios/5676e6258e580e5940628811123f8402950013e3/waifu2x/models/up_anime_noise3_scale2x_model.mlmodel) | [下载](https://raw.githubusercontent.com/imxieyi/waifu2x-ios/5676e6258e580e5940628811123f8402950013e3/waifu2x/models/up_photo_noise3_scale2x_model.mlmodel) |

模型来源与许可证保留在 assets/models/waifu2x/ORIGIN.json 和 LICENSE。清理模型编译缓存保留导入的原始模型，之后可重新加载。
