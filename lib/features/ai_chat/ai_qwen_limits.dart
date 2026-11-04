/// Alibaba Model Studio documentation, checked 2026-10-14. Exact IDs only:
/// private gateways and unlisted snapshots must supply their own limits.
/// https://help.aliyun.com/zh/model-studio/qwen-plus
/// https://help.aliyun.com/zh/model-studio/qwen-flash
/// https://help.aliyun.com/zh/model-studio/qwen3-5-plus
/// https://help.aliyun.com/zh/model-studio/qwen3-6-plus
/// https://help.aliyun.com/zh/model-studio/qwen3-7-plus
/// https://help.aliyun.com/zh/model-studio/qwen3-7-max
/// https://help.aliyun.com/zh/model-studio/qwen3-8-max
/// https://help.aliyun.com/zh/model-studio/qwen3-8-flash
typedef AiQwenLimits = ({
  int context,
  int input,
  int thinkingInput,
  int output,
});

AiQwenLimits? aiQwenLimits(String id) {
  if (const {
    'qwen-plus',
    'qwen-plus-latest',
    'qwen-plus-2025-12-01',
  }.contains(id)) {
    return (
      context: 1000000,
      input: 997952,
      thinkingInput: 995904,
      output: 32768,
    );
  }
  if (const {'qwen-flash', 'qwen-flash-2025-07-28'}.contains(id)) {
    return (
      context: 1000000,
      input: 997952,
      thinkingInput: 997952,
      output: 32768,
    );
  }
  if (const {'qwen-plus-2025-07-14', 'qwen-plus-2025-04-28'}.contains(id)) {
    return (context: 131072, input: 98304, thinkingInput: 98304, output: 16384);
  }
  if (const {'qwen-plus-2025-01-25'}.contains(id)) {
    return (
      context: 131072,
      input: 129024,
      thinkingInput: 129024,
      output: 8192,
    );
  }
  if (const {
    'qwen3.5-plus',
    'qwen3.5-plus-2026-02-15',
    'qwen3.5-flash',
    'qwen3.5-flash-2026-02-23',
    'qwen3.6-plus',
    'qwen3.6-plus-2026-04-02',
    'qwen3.6-flash',
    'qwen3.6-flash-2026-04-16',
  }.contains(id)) {
    return (
      context: 1000000,
      input: 991808,
      thinkingInput: 983616,
      output: 65536,
    );
  }
  if (const {
    'qwen3.7-max',
    'qwen3.7-max-2026-06-08',
    'qwen3.7-plus',
    'qwen3.7-plus-2026-05-26',
    'qwen3.8-max',
    'qwen3.8-max-0902',
    'qwen3.8-max-2026-09-02',
    'qwen3.8-flash',
  }.contains(id)) {
    return (
      context: 1000000,
      input: 991808,
      thinkingInput: 983616,
      output: 131072,
    );
  }
  return null;
}
