import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vesta_tracker/services/study_mode_state.dart';
import 'package:vesta_tracker/l10n/tr.dart';

void main() {
  // The tests check the Spanish texts.
  setUpAll(() => debugSetAppLanguage('es'));

  String config({
    bool active = false,
    int endsAtMs = 0,
    List<Map<String, dynamic>> schedules = const [],
  }) =>
      jsonEncode({
        'active': active,
        'endsAtMs': endsAtMs,
        'allowedApps': ['com.example.calc'],
        'schedules': schedules,
      });

  // 2026-11-23 is a Monday (weekday == 1).
  final monday1700 = DateTime(2026, 11, 23, 17, 0);

  test('inactivo por defecto o con JSON inválido', () {
    expect(StudyModeState.fromJson(null).isActiveAt(monday1700), isFalse);
    expect(StudyModeState.fromJson('{roto').isActiveAt(monday1700), isFalse);
  });

  test('activación manual sin fin y con fin', () {
    expect(
      StudyModeState.fromJson(config(active: true)).isActiveAt(monday1700),
      isTrue,
    );

    final ends = monday1700.add(const Duration(minutes: 30));
    final state = StudyModeState.fromJson(
      config(active: true, endsAtMs: ends.millisecondsSinceEpoch),
    );
    expect(state.isActiveAt(monday1700), isTrue);
    expect(state.currentEnd(monday1700), ends);
    expect(state.isActiveAt(ends), isFalse);
  });

  test('horario diurno en días laborables', () {
    final state = StudyModeState.fromJson(config(schedules: [
      {'days': [1, 2, 3, 4, 5], 'start': '16:00', 'end': '18:00'},
    ]));

    expect(state.isActiveAt(monday1700), isTrue);
    expect(state.currentEnd(monday1700), DateTime(2026, 11, 23, 18, 0));
    expect(state.isActiveAt(DateTime(2026, 11, 23, 18, 0)), isFalse);
    expect(state.isActiveAt(DateTime(2026, 11, 23, 15, 59)), isFalse);
    // Saturday.
    expect(state.isActiveAt(DateTime(2026, 11, 28, 17, 0)), isFalse);
  });

  test('horario nocturno que cruza la medianoche', () {
    final state = StudyModeState.fromJson(config(schedules: [
      {'days': [7], 'start': '21:00', 'end': '07:00'},
    ]));

    // Sunday 22-11 at 23:00 → active until Monday 07:00.
    final sundayNight = DateTime(2026, 11, 22, 23, 0);
    expect(state.isActiveAt(sundayNight), isTrue);
    expect(state.currentEnd(sundayNight), DateTime(2026, 11, 23, 7, 0));

    // Monday 06:30: still active from the slot that started on Sunday.
    expect(state.isActiveAt(DateTime(2026, 11, 23, 6, 30)), isTrue);
    // Monday 21:30: Monday is not in the list.
    expect(state.isActiveAt(DateTime(2026, 11, 23, 21, 30)), isFalse);
  });

  test('ignora franjas mal formadas', () {
    final state = StudyModeState.fromJson(config(schedules: [
      {'days': [1], 'start': '25:00', 'end': '18:00'},
      {'days': [], 'start': '16:00', 'end': '18:00'},
      {'days': [1], 'start': '16:00', 'end': '16:00'},
    ]));
    expect(state.schedules, isEmpty);
  });
}
