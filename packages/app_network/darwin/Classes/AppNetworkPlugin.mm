#import "AppNetworkPlugin.h"
#import <WebKit/WebKit.h>
#import <CFNetwork/CFNetwork.h>
#import <Network/Network.h>

namespace {
struct PacResult {
  CFArrayRef proxies = nullptr;
  CFRunLoopRef loop;
  bool done = false;
};
void PacCallback(void *opaque, CFArrayRef proxies, CFErrorRef error) {
  auto *result = static_cast<PacResult *>(opaque);
  if (!error && proxies) result->proxies = (CFArrayRef)CFRetain(proxies);
  result->done = true;
  CFRunLoopStop(result->loop);
}
NSArray *EvaluatePAC(NSDictionary *proxy, NSURL *target) {
  PacResult result; result.loop = CFRunLoopGetCurrent();
  CFStreamClientContext context = {0, &result, nullptr, nullptr, nullptr};
  CFRunLoopSourceRef source;
  if ([proxy[(__bridge NSString *)kCFProxyTypeKey] isEqual:(__bridge NSString *)kCFProxyTypeAutoConfigurationURL]) {
    NSURL *url = proxy[(__bridge NSString *)kCFProxyAutoConfigurationURLKey];
    if (!url) return nil;
    source = CFNetworkExecuteProxyAutoConfigurationURL((__bridge CFURLRef)url,
      (__bridge CFURLRef)target, PacCallback, &context);
  } else {
    NSString *script = proxy[(__bridge NSString *)kCFProxyAutoConfigurationJavaScriptKey];
    if (!script) return nil;
    source = CFNetworkExecuteProxyAutoConfigurationScript((__bridge CFStringRef)script,
      (__bridge CFURLRef)target, PacCallback, &context);
  }
  if (!source) return nil;
  CFRunLoopAddSource(result.loop, source, kCFRunLoopDefaultMode);
  CFRunLoopRunInMode(kCFRunLoopDefaultMode, 15, false);
  CFRunLoopSourceInvalidate(source);
  CFRelease(source);
  if (!result.done || !result.proxies) return nil;
  return CFBridgingRelease(result.proxies);
}
NSArray<NSString *> *Resolve(NSURL *target) {
  CFDictionaryRef settings = CFNetworkCopySystemProxySettings();
  if (!settings) return nil;
  NSArray *initial = CFBridgingRelease(CFNetworkCopyProxiesForURL((__bridge CFURLRef)target, settings));
  CFRelease(settings);
  NSMutableArray *expanded = [NSMutableArray array];
  for (NSDictionary *proxy in initial) {
    NSString *type = proxy[(__bridge NSString *)kCFProxyTypeKey];
    if ([type isEqual:(__bridge NSString *)kCFProxyTypeAutoConfigurationURL] ||
        [type isEqual:(__bridge NSString *)kCFProxyTypeAutoConfigurationJavaScript]) {
      NSArray *pac = EvaluatePAC(proxy, target);
      if (!pac) return nil;
      [expanded addObjectsFromArray:pac];
    } else [expanded addObject:proxy];
  }
  NSMutableArray<NSString *> *routes = [NSMutableArray array];
  for (NSDictionary *proxy in expanded) {
    NSString *type = proxy[(__bridge NSString *)kCFProxyTypeKey];
    if ([type isEqual:(__bridge NSString *)kCFProxyTypeNone]) { [routes addObject:@"DIRECT"]; continue; }
    NSString *scheme = [type isEqual:(__bridge NSString *)kCFProxyTypeSOCKS] ? @"socks5" :
      [type isEqual:(__bridge NSString *)kCFProxyTypeHTTPS] ? @"http" :
      [type isEqual:(__bridge NSString *)kCFProxyTypeHTTP] ? @"http" : nil;
    NSString *host = proxy[(__bridge NSString *)kCFProxyHostNameKey];
    NSNumber *port = proxy[(__bridge NSString *)kCFProxyPortNumberKey];
    if (!scheme || !host || !port) return nil;
    NSURLComponents *components = [NSURLComponents new];
    components.scheme = scheme; components.host = host; components.port = port;
    components.user = proxy[(__bridge NSString *)kCFProxyUsernameKey];
    components.password = proxy[(__bridge NSString *)kCFProxyPasswordKey];
    [routes addObject:components.string];
  }
  return routes.count ? routes : @[@"DIRECT"];
}
}

@implementation AppNetworkPlugin {
  FlutterEventSink _sink;
  nw_path_monitor_t _monitor;
  NSTimer *_proxyPoll;
  NSDictionary *_lastProxySettings;
}
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  AppNetworkPlugin *plugin = [AppNetworkPlugin new];
  FlutterMethodChannel *methods = [FlutterMethodChannel methodChannelWithName:@"com.example.video_player_app/network"
    binaryMessenger:registrar.messenger];
  [registrar addMethodCallDelegate:plugin channel:methods];
  FlutterEventChannel *events = [FlutterEventChannel eventChannelWithName:@"com.example.video_player_app/network_events"
    binaryMessenger:registrar.messenger];
  [events setStreamHandler:plugin];
}
- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  if ([call.method isEqual:@"configureWebViewProxy"]) {
#if __has_include(<Network/proxy_config.h>)
    if (@available(iOS 17.0, macOS 14.0, *)) {
      NSString *host = call.arguments[@"host"];
      NSNumber *port = call.arguments[@"port"];
      if (![host isEqual:@"127.0.0.1"] || port.intValue < 1 || port.intValue > 65535) {
        result([FlutterError errorWithCode:@"INVALID_PROXY" message:@"本机网络桥接地址无效" details:nil]); return;
      }
      nw_endpoint_t endpoint = nw_endpoint_create_host(host.UTF8String, port.stringValue.UTF8String);
      nw_proxy_config_t proxy = nw_proxy_config_create_http_connect(endpoint, nullptr);
      WKWebsiteDataStore.defaultDataStore.proxyConfigurations = @[proxy];
      result(@YES); return;
    }
#endif
    result(@NO); return;
  }
  if (![call.method isEqual:@"resolveProxy"]) { result(FlutterMethodNotImplemented); return; }
  NSURL *url = [NSURL URLWithString:call.arguments[@"url"] ?: @""];
  if (!url.host) { result([FlutterError errorWithCode:@"INVALID_URL" message:@"缺少网址" details:nil]); return; }
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    NSArray *routes = Resolve(url);
    dispatch_async(dispatch_get_main_queue(), ^{
      result(routes ?: [FlutterError errorWithCode:@"PROXY_RESOLUTION_FAILED" message:@"无法读取系统代理" details:nil]);
    });
  });
}
- (FlutterError *)onListenWithArguments:(id)arguments eventSink:(FlutterEventSink)sink {
  _sink = [sink copy];
  if (_monitor) nw_path_monitor_cancel(_monitor);
  [_proxyPoll invalidate];
  _lastProxySettings = CFBridgingRelease(CFNetworkCopySystemProxySettings());
  __weak AppNetworkPlugin *weakOwner = self;
  _proxyPoll = [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer) {
    (void)timer;
    AppNetworkPlugin *owner = weakOwner;
    if (!owner) return;
    NSDictionary *current = CFBridgingRelease(CFNetworkCopySystemProxySettings());
    if (current && ![current isEqual:owner->_lastProxySettings]) {
      owner->_lastProxySettings = current;
      if (owner->_sink) owner->_sink(@YES);
    }
  }];
  _monitor = nw_path_monitor_create();
  __weak AppNetworkPlugin *weakSelf = self;
  nw_path_monitor_set_update_handler(_monitor, ^(nw_path_t path) {
    dispatch_async(dispatch_get_main_queue(), ^{ AppNetworkPlugin *owner = weakSelf; if (owner && owner->_sink) owner->_sink(@YES); });
  });
  nw_path_monitor_set_queue(_monitor, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
  nw_path_monitor_start(_monitor);
  return nil;
}
- (FlutterError *)onCancelWithArguments:(id)arguments {
  [_proxyPoll invalidate]; _proxyPoll = nil; _lastProxySettings = nil;
  _sink = nil; if (_monitor) { nw_path_monitor_cancel(_monitor); _monitor = nil; } return nil;
}
- (void)dealloc { [_proxyPoll invalidate]; if (_monitor) nw_path_monitor_cancel(_monitor); }
@end
