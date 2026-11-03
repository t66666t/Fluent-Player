# 悬浮字幕多语言换行

播放、普通/幽灵字幕、样式预设、精确烧录与 ASS 导出共用 `layoutSubtitleText`。保留原有字体、字号、位置、安全边距和图片字幕行为；软换行只存在于显示或合成结果中，不改字幕文件、时间轴或生成任务。

## 断点规则

- 能放下一行的源文本不增加换行；已有换行和空行保留，每行独立排版，主副字幕互不牵制。
- 超宽后从 Unicode 字词边界中选择断点，优先标点和分句边界，再考虑避免孤字和行长均衡。停止通过压窄整块字幕来追求等长。
- 中文优先句号、逗号等停顿，避免左括号留在行末、右括号或常见结束标点落在行首。
- 英文及其他空格分词语言保留普通单词；常见英文冠词、部分其他拉丁语言冠词和连接词有轻量偏好。韩文优先保留空格分隔的词组。
- 日文同时处理小假名、促音、长音符、迭字符等行首禁则，包含常见半角形式。过长片假名词需要拆行时仍优先选符合禁则的位置。
- 常见数字单位、不换行空格、word joiner 优先保持完整。组合音标、emoji 肤色、ZWJ 家庭表情、国旗及分解韩文字母均按完整字素处理。
- 单个词超出整个可用宽度时允许应急换行；不截断剩余文字，也不为单句缩小字号。超过八行时省略均衡优化；单个源行超过 1024 个 UTF-16 单元时保留引擎原生折行，限制排版开销。

字词边界复用 Flutter 引擎，字素边界使用项目已有的 `characters`。部分运行时对中日汉字只给出单字边界，因此这些规则属于标点和字形约束辅助排版，不能保证没有标点的任意句子都按完整词义分割。复杂脚本重新成行后会再由实际文本引擎校验，测量不一致时回退到原生折行。

ASS 把相同软断点写成 `\N` 并使用 `WrapStyle: 2`，避免 libass 再次自行均衡；精确烧录复用播放组件。

## 验证

```powershell
flutter test --no-pub test/subtitle_text_balance_test.dart test/subtitle_multilingual_layout_test.dart test/subtitle_playback_export_layout_test.dart
```

断点测试覆盖中、英、日、韩，以及法、德、西、俄、阿拉伯和印地语的 Unicode 单词边界，另覆盖括号、半角假名、数字单位、组合字符、源换行、不同字号的双语和长文本。多语言组件测试使用实际内置字体，核对中英日韩在横竖屏中的描边/填充、ASS 各层断点，以及播放和精确导出的像素一致性。渲染文件位于 `build/subtitle-multilingual-wrap/`。

规则参考：[Unicode 行断算法](https://www.unicode.org/reports/tr14/)、[日文排版要求](https://www.w3.org/TR/jlreq/)、[韩文排版要求](https://www.w3.org/TR/klreq/)、[Netflix 字幕断行指南](https://partnerhelp.netflixstudios.com/hc/en-us/articles/215758617-Timed-Text-Style-Guide-General-Requirements)。这里采用适合播放器的规则组合，不声称符合任一发行平台的全部交付规范。
