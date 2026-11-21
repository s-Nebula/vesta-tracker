import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';

class PrivacyAuthorizationService {
  PrivacyAuthorizationService._();

  static const String _endpoint = '/api/devices/privacy-status';

  static const Duration authorizationLease = Duration(seconds: 120);

  static const List<String> purposes = [
    'location',
    'device_status',
    'usage_stats',
    'app_filtering',
    'domain_filtering',
    'alerts',
  ];

  static const String _checkedAtKey = 'privacy_authorization_checked_at_ms';

  static String _purposeKey(String purpose) => 'privacy_${purpose}_enabled';

  static Future<void> denyAll() async {
    final prefs = await SharedPreferences.getInstance();

    for (final purpose in purposes) {
      await prefs.setBool(_purposeKey(purpose), false);
    }

    await prefs.setInt(_checkedAtKey, 0);
  }

  static Future<bool> isAuthorized(String purpose) async {
    if (!purposes.contains(purpose)) return false;

    final prefs = await SharedPreferences.getInstance();

    final enabled = prefs.getBool(_purposeKey(purpose)) ?? false;
    final checkedAt = prefs.getInt(_checkedAtKey) ?? 0;

    if (!enabled || checkedAt <= 0) return false;

    final age = DateTime.now().millisecondsSinceEpoch - checkedAt;

    if (age < 0 || age > authorizationLease.inMilliseconds) {
      await denyAll();
      return false;
    }

    return true;
  }

  static Future<Map<String, bool>> refresh() async {
    final prefs = await SharedPreferences.getInstance();

    try {
      final response = await VestaApiClient.get(_endpoint);

      final linked = response['linked'] == true;
      final status = response['status'];
      final rawPurposes = response['purposes'];

      if (!linked ||
          (status != 'authorized' && status != 'blocked') ||
          rawPurposes is! Map) {
        await denyAll();
        return {for (final purpose in purposes) purpose: false};
      }

      final authorization = <String, bool>{};

      for (final purpose in purposes) {
        final value = rawPurposes[purpose];

        if (value is! bool) {
          await denyAll();
          return {for (final item in purposes) item: false};
        }

        authorization[purpose] = value;
      }

      for (final purpose in purposes) {
        await prefs.setBool(
          _purposeKey(purpose),
          authorization[purpose]!,
        );
      }

      await prefs.setInt(
        _checkedAtKey,
        DateTime.now().millisecondsSinceEpoch,
      );

      return authorization;
    } catch (error) {
      await denyAll();
      rethrow;
    }
  }

  static Future<void> applyNativeFlags() async {
    final prefs = await SharedPreferences.getInstance();

    // Las claves se comparten con SharedPreferences de Android.
    // Kotlin debe comprobar también la vigencia de la autorización.
    await prefs.setBool(
      'privacy_app_filtering_enabled',
      await isAuthorized('app_filtering'),
    );

    await prefs.setBool(
      'privacy_domain_filtering_enabled',
      await isAuthorized('domain_filtering'),
    );

    await prefs.setBool(
      'privacy_alerts_enabled',
      await isAuthorized('alerts'),
    );
  }
}
