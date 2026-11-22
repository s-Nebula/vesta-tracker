import 'dart:convert';

/// Recurring study mode time slot.
///
/// [days] uses the ISO numbering of `DateTime.weekday` (1 = Monday … 7 =
/// Sunday) and refers to the day the slot STARTS. If [end] is before
/// [start], the slot crosses midnight (for example 21:00-07:00).
class StudySchedule {
  final Set<int> days;
  final int startMinutes;
  final int endMinutes;

  const StudySchedule({
    required this.days,
    required this.startMinutes,
    required this.endMinutes,
  });

  static int? parseTime(String value) {
    final match = RegExp(r'^([01]\d|2[0-3]):([0-5]\d)$').firstMatch(value);
    if (match == null) return null;
    return int.parse(match.group(1)!) * 60 + int.parse(match.group(2)!);
  }

  static StudySchedule? fromMap(Map<dynamic, dynamic> map) {
    final start = parseTime(map['start']?.toString() ?? '');
    final end = parseTime(map['end']?.toString() ?? '');
    final rawDays = map['days'];

    if (start == null || end == null || start == end || rawDays is! List) {
      return null;
    }

    final days = rawDays
        .whereType<num>()
        .map((day) => day.toInt())
        .where((day) => day >= 1 && day <= 7)
        .toSet();

    if (days.isEmpty) return null;

    return StudySchedule(days: days, startMinutes: start, endMinutes: end);
  }

  bool get crossesMidnight => endMinutes < startMinutes;

  /// End of the slot active at [now], or null if it is not active.
  DateTime? activeEnd(DateTime now) {
    final minutes = now.hour * 60 + now.minute;
    final today = DateTime(now.year, now.month, now.day);

    if (!crossesMidnight) {
      if (days.contains(now.weekday) &&
          minutes >= startMinutes &&
          minutes < endMinutes) {
        return today.add(Duration(minutes: endMinutes));
      }
      return null;
    }

    // The part of the night that starts today.
    if (days.contains(now.weekday) && minutes >= startMinutes) {
      return today.add(Duration(days: 1, minutes: endMinutes));
    }

    // The early-morning part of a slot that started yesterday.
    final yesterday = now.weekday == 1 ? 7 : now.weekday - 1;
    if (days.contains(yesterday) && minutes < endMinutes) {
      return today.add(Duration(minutes: endMinutes));
    }

    return null;
  }
}

/// Local copy of `children/{id}/controls/study_mode`. The same logic is
/// implemented in Kotlin (AppBlockerService), which does the blocking.
class StudyModeState {
  final bool manualActive;
  final DateTime? manualEndsAt;
  final List<String> allowedApps;
  final List<StudySchedule> schedules;

  const StudyModeState({
    required this.manualActive,
    required this.manualEndsAt,
    required this.allowedApps,
    required this.schedules,
  });

  static const inactive = StudyModeState(
    manualActive: false,
    manualEndsAt: null,
    allowedApps: [],
    schedules: [],
  );

  static StudyModeState fromJson(String? json) {
    if (json == null || json.isEmpty) return inactive;

    try {
      final data = jsonDecode(json);
      if (data is! Map) return inactive;

      final endsAtMs = data['endsAtMs'];

      return StudyModeState(
        manualActive: data['active'] == true,
        manualEndsAt: endsAtMs is num && endsAtMs > 0
            ? DateTime.fromMillisecondsSinceEpoch(endsAtMs.toInt())
            : null,
        allowedApps: (data['allowedApps'] is List)
            ? (data['allowedApps'] as List).map((e) => e.toString()).toList()
            : const [],
        schedules: (data['schedules'] is List)
            ? (data['schedules'] as List)
                .whereType<Map>()
                .map(StudySchedule.fromMap)
                .whereType<StudySchedule>()
                .toList()
            : const [],
      );
    } catch (_) {
      return inactive;
    }
  }

  bool _manualActiveAt(DateTime now) =>
      manualActive && (manualEndsAt == null || now.isBefore(manualEndsAt!));

  bool isActiveAt(DateTime now) =>
      _manualActiveAt(now) ||
      schedules.any((schedule) => schedule.activeEnd(now) != null);

  /// Latest end time among the active sources (null = indefinite).
  DateTime? currentEnd(DateTime now) {
    final ends = <DateTime>[];
    var indefinite = false;

    if (_manualActiveAt(now)) {
      if (manualEndsAt == null) {
        indefinite = true;
      } else {
        ends.add(manualEndsAt!);
      }
    }

    for (final schedule in schedules) {
      final end = schedule.activeEnd(now);
      if (end != null) ends.add(end);
    }

    if (indefinite || ends.isEmpty) return null;
    ends.sort();
    return ends.last;
  }
}
