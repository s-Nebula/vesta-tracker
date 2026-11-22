import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';

import 'package:vesta_tracker/l10n/tr.dart';
/// Result of asking the backend for the device's authorisation.
enum DeviceLinkState { authorized, blocked, unlinked }

/// The backend confirmed this device is no longer linked.
class DeviceUnlinkedException implements Exception {
  final String reason;
  const DeviceUnlinkedException(this.reason);

  @override
  String toString() => tr('Dispositivo desvinculado ({0})', [reason]);
}

/// Device privacy authorisation.
///
/// Policy:
/// * An explicit server answer (authorised, blocked, unlinked or 403) is
///   applied straight away. So a revocation takes at most one polling
///   cycle (60 s) to take effect while there is a connection.
/// * A transient failure (no network, timeout, server down) does NOT revoke
///   anything: the last confirmed authorisation is kept for
///   [offlineGrace]. Previously any network drop turned off app blocking,
///   the DNS filter and location within 2 minutes, so turning on airplane
///   mode or the server going down was enough to bypass every control.
/// * Firestore writes made offline are validated again against the security
///   rules when they sync, so the grace period never allows publishing data
///   without a valid consent.
class PrivacyAuthorizationService {
  PrivacyAuthorizationService._();

  static const String _endpoint = '/api/devices/privacy-status';

  /// Maximum time the last confirmed authorisation is honoured when the
  /// server cannot be reached.
  static const Duration offlineGrace = Duration(hours: 24);

  static const List<String> purposes = [
    'location',
    'device_status',
    'usage_stats',
    'app_filtering',
    'domain_filtering',
    'alerts',
  ];

  /// Time of the last successful check with the server.
  /// The key is shared with the native (Kotlin) code.
  static const String _checkedAtKey = 'privacy_authorization_checked_at_ms';

  /// Validity the native code must apply to [_checkedAtKey].
  static const String _leaseKey = 'privacy_authorization_lease_ms';

  /// Last check attempt (successful or not), for diagnostics.
  static const String _lastAttemptKey = 'privacy_authorization_attempt_at_ms';

  static String _purposeKey(String purpose) => 'privacy_${purpose}_enabled';

  static Future<SharedPreferences> _prefs() async {
    final prefs = await SharedPreferences.getInstance();
    // The UI and the background service are separate isolates with
    // separate caches; without reloading, one does not see what the other writes.
    await prefs.reload();
    return prefs;
  }

  static Future<void> denyAll() async {
    final prefs = await SharedPreferences.getInstance();

    for (final purpose in purposes) {
      await prefs.setBool(_purposeKey(purpose), false);
    }

    await prefs.setInt(_checkedAtKey, 0);
    await prefs.setInt(_leaseKey, offlineGrace.inMilliseconds);
  }

  static Future<bool> isAuthorized(String purpose) async {
    if (!purposes.contains(purpose)) return false;

    final prefs = await _prefs();

    final enabled = prefs.getBool(_purposeKey(purpose)) ?? false;
    final checkedAt = prefs.getInt(_checkedAtKey) ?? 0;

    if (!enabled || checkedAt <= 0) return false;

    final age = DateTime.now().millisecondsSinceEpoch - checkedAt;

    if (age < 0 || age > offlineGrace.inMilliseconds) {
      await denyAll();
      return false;
    }

    return true;
  }

  /// Date of the last successful check, or null if there is none.
  static Future<DateTime?> lastVerifiedAt() async {
    final prefs = await _prefs();
    final checkedAt = prefs.getInt(_checkedAtKey) ?? 0;
    if (checkedAt <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(checkedAt);
  }

  /// Queries the backend and updates the local authorisation.
  ///
  /// * Throws [DeviceUnlinkedException] if the server says the device is no
  ///   longer linked (the caller must clear the state).
  /// * Throws [VestaApiException] with `isTransient == true` if there was no
  ///   useful answer; in that case the local authorisation is NOT changed.
  static Future<DeviceLinkState> refresh() async {
    final prefs = await _prefs();
    await prefs.setInt(
      _lastAttemptKey,
      DateTime.now().millisecondsSinceEpoch,
    );

    Map<String, dynamic> response;

    try {
      response = await VestaApiClient.get(_endpoint);
    } on VestaApiException catch (error) {
      // 401 is usually caused by an expired token or a skewed clock,
      // not by a decision of the guardians: treated as transient.
      if (error.isTransient || error.statusCode == 401) rethrow;

      // 403 or another explicit refusal: deny everything straight away.
      await denyAll();
      rethrow;
    }

    final linked = response['linked'] == true;
    final status = response['status'];
    final rawPurposes = response['purposes'];

    if (!linked || status == 'unlinked') {
      await denyAll();
      throw DeviceUnlinkedException(
        response['reason']?.toString() ?? 'unlinked',
      );
    }

    final serverChildId = response['childId'];
    final localChildId = prefs.getString('child_id');

    if (serverChildId is String &&
        localChildId != null &&
        serverChildId != localChildId) {
      await denyAll();
      throw const DeviceUnlinkedException('child_mismatch');
    }

    if ((status != 'authorized' && status != 'blocked') ||
        rawPurposes is! Map) {
      await denyAll();
      return DeviceLinkState.blocked;
    }

    final authorization = <String, bool>{};

    for (final purpose in purposes) {
      final value = rawPurposes[purpose];

      if (value is! bool) {
        await denyAll();
        return DeviceLinkState.blocked;
      }

      authorization[purpose] = value;
    }

    for (final purpose in purposes) {
      await prefs.setBool(_purposeKey(purpose), authorization[purpose]!);
    }

    await prefs.setInt(_leaseKey, offlineGrace.inMilliseconds);
    await prefs.setInt(
      _checkedAtKey,
      DateTime.now().millisecondsSinceEpoch,
    );

    return authorization.values.any((value) => value)
        ? DeviceLinkState.authorized
        : DeviceLinkState.blocked;
  }

  static Future<void> applyNativeFlags() async {
    final prefs = await SharedPreferences.getInstance();

    // The keys are shared with Android SharedPreferences.
    // Kotlin also checks validity with privacy_authorization_lease_ms.
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

  /// Removes every local trace of the link. Used when the guardian
  /// unlinks the device or when it is set up again manually.
  static Future<void> clearLocalLink() async {
    await denyAll();

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('child_id');
    await prefs.remove('parent_id');
    await prefs.setString('blocked_apps_json', '[]');
    await prefs.setString('blocked_domains_json', '[]');
    await prefs.setString('allowed_domains_json', '[]');
    await prefs.remove('study_mode_json');
    await prefs.remove('app_limits_json');
    await prefs.remove('temporary_allow_json');
    await prefs.remove('web_protection_json');
    await prefs.remove('offline_since_ms');
    for (final key in prefs.getKeys().toList()) {
      if (key.startsWith('zone_state_')) await prefs.remove(key);
    }
  }
}
