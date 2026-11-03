import '../../services/network/network_models.dart';

/// Only the policy is persisted. Proxy addresses and credentials continue to
/// belong to the application's network configuration and secure storage.
enum WebMediaTaskNetwork { followSettings, direct, system, custom }

extension WebMediaTaskNetworkPresentation on WebMediaTaskNetwork {
  String get label => switch (this) {
    WebMediaTaskNetwork.followSettings => '跟随软件设置',
    WebMediaTaskNetwork.direct => '直连',
    WebMediaTaskNetwork.system => '使用设备代理',
    WebMediaTaskNetwork.custom => '使用自定义代理',
  };
  String get description => switch (this) {
    WebMediaTaskNetwork.followSettings => '使用网络设置中的“其他联网功能”策略',
    WebMediaTaskNetwork.direct => '此任务不使用系统代理或软件自定义代理',
    WebMediaTaskNetwork.system => '遵循设备的系统代理和 PAC；设备未配置代理时直连',
    WebMediaTaskNetwork.custom => '使用软件网络设置中已保存的自定义代理',
  };
  NetworkMode? get mode => switch (this) {
    WebMediaTaskNetwork.followSettings => null,
    WebMediaTaskNetwork.direct => NetworkMode.direct,
    WebMediaTaskNetwork.system => NetworkMode.system,
    WebMediaTaskNetwork.custom => NetworkMode.custom,
  };
}
