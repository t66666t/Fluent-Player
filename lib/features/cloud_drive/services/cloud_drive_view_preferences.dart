import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/cloud_drive_view_options.dart';

class CloudDriveViewPreferences {
  CloudDriveViewPreferences(this.preferences);
  final SharedPreferences preferences;
  String get providerId =>
      preferences.getString('cloudDrive.lastProvider') ?? 'baidu';
  String? accountId(String provider) =>
      preferences.getString('cloudDrive.$provider.account');
  CloudDriveViewOptions options(String provider) {
    try {
      return CloudDriveViewOptions.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(preferences.getString('cloudDrive.$provider.view') ?? '{}')
              as Map,
        ),
      );
    } catch (_) {
      return const CloudDriveViewOptions();
    }
  }

  Future<void> selectProvider(String provider) async {
    await preferences.setString('cloudDrive.lastProvider', provider);
  }

  Future<void> selectAccount(String provider, String? account) async {
    final key = 'cloudDrive.$provider.account';
    if (account == null) {
      await preferences.remove(key);
    } else {
      await preferences.setString(key, account);
    }
  }

  Future<void> save(String provider, CloudDriveViewOptions options) async {
    await preferences.setString(
      'cloudDrive.$provider.view',
      jsonEncode(options.toJson()),
    );
  }
}
