import 'dart:io';

enum NetworkMode { system, direct, custom }

enum NetworkScope {
  bilibili,
  cloudDrive,
  ytDlpDomestic,
  ytDlpOther,
  speechRecognition,
  cloudTranscription,
  translation,
  updates,
  modelDownloads,
  podcastsDomestic,
  podcasts,
  other,
}

extension NetworkScopePresentation on NetworkScope {
  String get label => switch (this) {
    NetworkScope.bilibili => 'B 站',
    NetworkScope.cloudDrive => '网盘',
    NetworkScope.ytDlpDomestic => 'YTDLP 国内网站',
    NetworkScope.ytDlpOther => 'YTDLP 国外及其他网站',
    NetworkScope.speechRecognition => '语音识别接口',
    NetworkScope.cloudTranscription => '云端转录',
    NetworkScope.translation => '字幕翻译',
    NetworkScope.updates => '组件更新',
    NetworkScope.modelDownloads => '模型下载',
    NetworkScope.podcastsDomestic => '播客 · 国内来源',
    NetworkScope.podcasts => '播客 · 海外及其他来源',
    NetworkScope.other => '其他联网功能',
  };

  NetworkMode get defaultMode => switch (this) {
    NetworkScope.bilibili ||
    NetworkScope.cloudDrive ||
    NetworkScope.ytDlpDomestic ||
    NetworkScope.podcastsDomestic ||
    NetworkScope.speechRecognition => NetworkMode.direct,
    _ => NetworkMode.system,
  };
}

extension NetworkModePresentation on NetworkMode {
  String get label => switch (this) {
    NetworkMode.system => '跟随设备网络',
    NetworkMode.direct => '不使用系统代理',
    NetworkMode.custom => '自定义代理',
  };
}

enum ProxyProtocol { http, https, socks5 }

/// Credentials are referenced, never serialized into settings or task records.
class ProxyProfile {
  final ProxyProtocol protocol;
  final String host;
  final int port;
  final String? username;
  final String? credentialKey;
  final String? transientPassword;

  const ProxyProfile({
    required this.protocol,
    required this.host,
    required this.port,
    this.username,
    this.credentialKey,
    this.transientPassword,
  });

  factory ProxyProfile.fromUri(String address, {String? credentialKey}) {
    final uri = Uri.parse(address.trim());
    final protocol = switch (uri.scheme.toLowerCase()) {
      'http' => ProxyProtocol.http,
      'https' => ProxyProtocol.https,
      'socks5' || 'socks5h' => ProxyProtocol.socks5,
      _ => throw const FormatException('代理类型须为 HTTP、HTTPS 或 SOCKS5'),
    };
    final user = uri.userInfo.split(':').first;
    final profile = ProxyProfile(
      protocol: protocol,
      host: NetworkSites.socketHost(uri.host),
      port: uri.hasPort
          ? uri.port
          : (protocol == ProxyProtocol.https
                ? 443
                : protocol == ProxyProtocol.socks5
                ? 1080
                : 80),
      username: user.isEmpty ? null : Uri.decodeComponent(user),
      credentialKey: credentialKey,
      transientPassword: credentialKey == null && uri.userInfo.contains(':')
          ? Uri.decodeComponent(
              uri.userInfo.substring(uri.userInfo.indexOf(':') + 1),
            )
          : null,
    );
    profile.validate();
    if (uri.path.isNotEmpty && uri.path != '/' ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('代理地址不能包含路径、查询或片段');
    }
    return profile;
  }

  void validate() {
    if (host.trim().isEmpty ||
        host != host.trim() ||
        RegExp(r'[\s/@?#\\;]').hasMatch(host) ||
        port < 1 ||
        port > 65535 ||
        (host.contains(':') &&
            InternetAddress.tryParse(NetworkSites.socketHost(host)) == null)) {
      throw const FormatException('请输入有效的代理主机和端口');
    }
    if (username?.contains(RegExp(r'[\r\n]')) == true) {
      throw const FormatException('账号不能包含换行');
    }
  }

  Uri get address => Uri(scheme: protocol.name, host: host, port: port);
  Map<String, Object?> toJson() => {
    'protocol': protocol.name,
    'host': host,
    'port': port,
    'username': username,
    'credentialKey': credentialKey,
  };
  factory ProxyProfile.fromJson(Map<String, dynamic> json) {
    final value = ProxyProfile(
      protocol: ProxyProtocol.values.byName(json['protocol'] as String),
      host: json['host'] as String,
      port: json['port'] as int,
      username: json['username'] as String?,
      credentialKey: json['credentialKey'] as String?,
    );
    value.validate();
    return value;
  }
  @override
  String toString() => address.toString();
}

class NetworkConfiguration {
  static const schemaVersion = 1;
  final int revision;

  /// Retained when a unified policy is selected, so switching back is lossless.
  final Map<NetworkScope, NetworkMode> featureModes;
  final NetworkMode? unifiedMode;
  late final Map<NetworkScope, NetworkMode> modes = unifiedMode == null
      ? featureModes
      : Map.unmodifiable({
          for (final scope in NetworkScope.values) scope: unifiedMode!,
        });
  final ProxyProfile? proxy;

  NetworkConfiguration({
    this.revision = 0,
    Map<NetworkScope, NetworkMode>? modes,
    this.unifiedMode,
    this.proxy,
  }) : featureModes = Map.unmodifiable({
         for (final scope in NetworkScope.values)
           scope: modes?[scope] ?? scope.defaultMode,
       });

  NetworkConfiguration copyWith({
    Map<NetworkScope, NetworkMode>? modes,
    ProxyProfile? proxy,
    bool clearProxy = false,
    NetworkMode? unifiedMode,
    bool clearUnifiedMode = false,
  }) => NetworkConfiguration(
    revision: revision + 1,
    modes: modes ?? featureModes,
    unifiedMode: clearUnifiedMode ? null : unifiedMode ?? this.unifiedMode,
    proxy: clearProxy ? null : proxy ?? this.proxy,
  );

  Map<String, Object?> toJson() => {
    'version': schemaVersion,
    'revision': revision,
    'unifiedMode': unifiedMode?.name,
    'modes': {
      for (final entry in featureModes.entries)
        entry.key.name: entry.value.name,
    },
    'proxy': proxy?.toJson(),
  };

  factory NetworkConfiguration.fromJson(Map<String, dynamic> json) {
    if (json['version'] != schemaVersion) {
      throw const FormatException('网络配置版本不受支持');
    }
    final modes = Map<String, dynamic>.from(json['modes'] as Map);
    final config = NetworkConfiguration(
      revision: json['revision'] as int,
      unifiedMode: json['unifiedMode'] == null
          ? null
          : NetworkMode.values.byName(json['unifiedMode'] as String),
      modes: {
        for (final scope in NetworkScope.values)
          scope: modes[scope.name] == null
              ? scope == NetworkScope.cloudDrive &&
                        modes[NetworkScope.other.name] ==
                            NetworkMode.custom.name
                    ? NetworkMode.custom
                    : scope.defaultMode
              : NetworkMode.values.byName(modes[scope.name] as String),
      },
      proxy: json['proxy'] == null
          ? null
          : ProxyProfile.fromJson(
              Map<String, dynamic>.from(json['proxy'] as Map),
            ),
    );
    if (config.revision < 0 ||
        config.proxy == null &&
            (config.unifiedMode == NetworkMode.custom ||
                config.featureModes.values.contains(NetworkMode.custom))) {
      throw const FormatException('自定义代理配置不完整');
    }
    return config;
  }
}

class RequestNetworkContext {
  final NetworkScope scope;
  final Uri? source;
  final NetworkConfiguration configuration;
  final int deviceGeneration;
  final int scopeGeneration;
  final bool cancelOnChange;

  /// Per-task selection; null follows the feature's shared network setting.
  final NetworkMode? modeOverride;

  /// An explicitly authorized, temporary recovery route for ASR only.
  /// It never changes the saved unified or per-feature policy.
  final bool speechRecognitionDirectRecovery;
  const RequestNetworkContext({
    required this.scope,
    required this.configuration,
    this.source,
    this.deviceGeneration = 0,
    this.cancelOnChange = true,
    this.scopeGeneration = 0,
    this.modeOverride,
    this.speechRecognitionDirectRecovery = false,
  });
  NetworkMode get mode =>
      scope == NetworkScope.speechRecognition && speechRecognitionDirectRecovery
      ? NetworkMode.direct
      : configuration.unifiedMode ??
            modeOverride ??
            configuration.modes[scope]!;

  RequestNetworkContext recoverSpeechRecognitionDirectly() =>
      RequestNetworkContext(
        scope: scope,
        source: source,
        configuration: configuration,
        deviceGeneration: deviceGeneration,
        scopeGeneration: scopeGeneration,
        cancelOnChange: cancelOnChange,
        modeOverride: modeOverride,
        speechRecognitionDirectRecovery:
            scope == NetworkScope.speechRecognition,
      );
  int get revision => configuration.revision;
  String get key =>
      '${scope.name}:$scopeGeneration:${mode == NetworkMode.system ? deviceGeneration : 0}:$cancelOnChange:${mode.name}';
}

/// YTDLP tasks keep their source classification. Podcast requests select their
/// own destination policy, since feeds, covers and media can use different CDNs.
abstract final class NetworkSites {
  static const podcastDomestic = [
    'xiaoyuzhoufm.com',
    'xyzfm.space',
    'xyzcdn.net',
    'xiaoyuzhoufm.cn',
    'ximalaya.com',
    'xmcdn.com',
    'ximalayaos.com',
    'xcdn.com',
    'qingting.fm',
    'qtfm.cn',
    'lrts.me',
    'lizhi.fm',
    'lizhi360.com',
    'kaolafm.com',
    'kaolafm.net',
    'qingtingcdn.com',
    'qiniucdn.com',
    'qiniu.com',
    'qbox.me',
  ];
  static NetworkScope forPodcast(Uri source) {
    final host = source.host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    final mainlandCloud =
        host.endsWith('.aliyuncs.com') && host.contains('.oss-cn-') ||
        RegExp(
          r'\.cos\.(ap-(beijing|shanghai|guangzhou|chengdu|nanjing|chongqing))\.myqcloud\.com$',
        ).hasMatch(host);
    return isLoopback(host) ||
            host.endsWith('.cn') ||
            matches(host, podcastDomestic) ||
            mainlandCloud
        ? NetworkScope.podcastsDomestic
        : NetworkScope.podcasts;
  }

  static const bilibili = ['bilibili.com', 'b23.tv', 'bili2233.cn'];
  static const domestic = [
    ...bilibili,
    'douyin.com',
    'iesdouyin.com',
    'amemv.com',
    'kuaishou.com',
    'gifshow.com',
    'xiaohongshu.com',
    'xhslink.com',
    'xhslink.cn',
    'weibo.com',
    'weibo.cn',
    't.cn',
    'acfun.cn',
    'acfun.com',
    'iqiyi.com',
    'qiyi.com',
    'youku.com',
    'tudou.com',
    'ixigua.com',
    'toutiao.com',
    'toutiaocdn.com',
    'v.qq.com',
    'video.qq.com',
    'url.cn',
  ];

  static bool matches(String host, Iterable<String> domains) {
    final normalized = host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    return domains.any(
      (domain) => normalized == domain || normalized.endsWith('.$domain'),
    );
  }

  static NetworkScope forYtDlp(Uri source) => matches(source.host, bilibili)
      ? NetworkScope.bilibili
      : matches(source.host, domestic)
      ? NetworkScope.ytDlpDomestic
      : NetworkScope.ytDlpOther;

  static bool isLoopback(String host) {
    final normalized = socketHost(host).toLowerCase();
    if (normalized == 'localhost' || normalized.endsWith('.localhost')) {
      return true;
    }
    final address = InternetAddress.tryParse(normalized);
    return address?.isLoopback ?? false;
  }

  static String socketHost(String host) =>
      host.startsWith('[') && host.endsWith(']')
      ? host.substring(1, host.length - 1)
      : host;
}

class NetworkSettingsException implements Exception {
  final String message;
  const NetworkSettingsException(this.message);
  @override
  String toString() => message;
}
