import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Lets each route paint its own background behind the mobile home indicator.
/// Content still reserves its safe area; only the background extends beneath it.
class MobileSystemNavigationBar extends StatelessWidget {
  const MobileSystemNavigationBar({
    super.key,
    required this.child,
    this.backgroundColor,
    this.bottomBackgroundColor,
  });

  final Widget child;
  final Color? backgroundColor;
  final Color? bottomBackgroundColor;

  static const overlayStyle = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemStatusBarContrastEnforced: false,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarContrastEnforced: false,
  );

  /// Backgrounds are painted by the page, not by the operating system. Only
  /// their brightness is needed here (iOS uses the background brightness).
  static SystemUiOverlayStyle styleFor({
    required Color backgroundColor,
    Color? bottomBackgroundColor,
  }) {
    final top = ThemeData.estimateBrightnessForColor(backgroundColor);
    final bottom = ThemeData.estimateBrightnessForColor(
      bottomBackgroundColor ?? backgroundColor,
    );
    return overlayStyle.copyWith(
      statusBarBrightness: top,
      statusBarIconBrightness: top == Brightness.dark
          ? Brightness.light
          : Brightness.dark,
      systemNavigationBarIconBrightness: bottom == Brightness.dark
          ? Brightness.light
          : Brightness.dark,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      return child;
    }
    // Keep this around the navigator so pushes, pops and sheets all restore
    // the navigation style from the current frame, including after playback.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: styleFor(
        backgroundColor:
            backgroundColor ?? Theme.of(context).scaffoldBackgroundColor,
        bottomBackgroundColor: bottomBackgroundColor,
      ),
      child: child,
    );
  }
}
