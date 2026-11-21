import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vesta_tracker/main.dart';
import 'package:vesta_tracker/screens/setup_screen.dart';
import 'package:vesta_tracker/theme_notifier.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('La App carga SetupScreen cuando no hay un perfil vinculado',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ThemeNotifier(),
        child: const VestaTrackerApp(),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.byType(SetupScreen), findsOneWidget);
    expect(find.text('VINCULAR DISPOSITIVO'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('XXXXXXXXXX'), findsOneWidget);
  });
}
