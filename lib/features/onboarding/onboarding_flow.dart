import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../screens/import_location_settings_screen.dart';
import '../../screens/network_settings_screen.dart';
import '../../services/library_service.dart';
import '../../services/settings_service.dart';
import '../../theme/app_page_transitions.dart';
import '../model_center/model_center_screen.dart';
import 'onboarding_screen.dart';
import 'onboarding_store.dart';

class OnboardingFlow {
  static bool _showing = false;
  static bool get isShowing => _showing;

  static Future<void> open(
    BuildContext context,
    SettingsService settings, {
    bool preview = false,
  }) async {
    if (_showing) return;
    _showing = true;
    try {
      if (!preview) await OnboardingStore.markHandled();
      if (!context.mounted) return;
      await Navigator.of(context, rootNavigator: true).push<void>(
        AppMaterialPageRoute<void>(
          settings: const RouteSettings(name: '/onboarding'),
          builder: (_) => OnboardingScreen(
            preview: preview,
            settings: settings,
            openDestination: (pageContext, destination) =>
                _openDestination(pageContext, settings, destination),
          ),
        ),
      );
    } finally {
      _showing = false;
    }
  }

  static Future<void> _openDestination(
    BuildContext context,
    SettingsService settings,
    OnboardingDestination destination,
  ) async {
    switch (destination) {
      case OnboardingDestination.network:
        await openNetworkSettings(context);
      case OnboardingDestination.bilibili:
        return; // Retired saved destination; never reopen a website.
      case OnboardingDestination.importLocation:
        final library = context.read<LibraryService?>();
        await Navigator.of(context).push<bool>(
          AppMaterialPageRoute(
            builder: (_) => ImportLocationSettingsScreen(
              settings: settings,
              library: library,
            ),
          ),
        );
      case OnboardingDestination.subtitleServices:
        await openModelCenter(context);
    }
  }
}
