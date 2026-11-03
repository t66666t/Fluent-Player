String transcriptionFailureSummary(String detail) {
  final text = detail.toLowerCase();
  if (text.contains('无音轨') || text.contains('no audio track')) {
    return '这个文件没有音轨，无法进行语音转录。画面中的字幕可使用“识别画面字幕”。';
  }
  if (RegExp(r'permission|access denied|权限|拒绝访问').hasMatch(text)) {
    return '无法读取媒体或写入字幕，请检查文件权限。';
  }
  if (RegExp(r'no space|disk full|空间不足|磁盘已满').hasMatch(text)) {
    return '存储空间不足，请释放空间后重试。';
  }
  if (RegExp(
    r'timeout|timed out|network|socket|connection|网络|超时|连接失败',
  ).hasMatch(text)) {
    return '网络连接中断或超时，请检查连接后重试。';
  }
  if (RegExp(
    r'unauthorized|authentication|401|403|api.?key|鉴权|密钥|认证',
  ).hasMatch(text)) {
    return '转录服务验证失败，请检查服务设置。';
  }
  if (RegExp(r'quota|429|额度|限流').hasMatch(text)) {
    return '转录服务额度不足或请求过多，请稍后重试。';
  }
  if (RegExp(r'no speech|没有.*人声|未识别.*语音|没有.*语音').hasMatch(text)) {
    return '没有识别到人声，请检查音轨和识别语言。';
  }
  if (RegExp(r'model|模型').hasMatch(text)) {
    return '识别模型未能运行，请检查模型是否可用。';
  }
  if (RegExp(r'not found|不存在|找不到').hasMatch(text)) {
    return '找不到媒体文件，请检查原文件是否仍在原位置。';
  }
  return '任务未能完成。可以重试，或查看详情检查任务设置。';
}
