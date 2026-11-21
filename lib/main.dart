import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'firebase_options.dart';
import 'theme_notifier.dart';
import 'screens/setup_screen.dart';
import 'screens/tracker_active_screen.dart';
import 'screens/success_screen.dart';
import 'screens/accessibility_permission_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  try {
    if (FirebaseAuth.instance.currentUser == null) {
      await FirebaseAuth.instance.signInAnonymously();
    }
  } catch (e) {
    debugPrint("Error de autenticación: $e");
  }

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();
  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(const AndroidNotificationChannel(
        'vesta_tracker_channel',
        'Vesta Tracker',
        description: 'Canal de seguridad para rastreo en tiempo real',
        importance: Importance.high,
      ));

  final prefs = await SharedPreferences.getInstance();
  final String? childIdSaved = prefs.getString('child_id');

  runApp(
    ChangeNotifierProvider(
      create: (_) => ThemeNotifier(),
      child: VestaTrackerApp(initialChildId: childIdSaved),
    ),
  );
}

class VestaTrackerApp extends StatefulWidget {
  final String? initialChildId;
  const VestaTrackerApp({super.key, this.initialChildId});

  @override
  State<VestaTrackerApp> createState() => _VestaTrackerAppState();
}

class _VestaTrackerAppState extends State<VestaTrackerApp> {
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    _router = GoRouter(
      initialLocation: widget.initialChildId == null
          ? '/setup'
          : '/accessibility/${widget.initialChildId}',
      routes: [
        GoRoute(
          path: '/setup',
          builder: (context, state) => const SetupScreen(),
        ),
        GoRoute(
          path: '/success/:childId',
          builder: (context, state) =>
              SuccessScreen(childId: state.pathParameters['childId']!),
        ),
        GoRoute(
          path: '/accessibility/:childId',
          builder: (context, state) => AccessibilityPermissionScreen(
            childId: state.pathParameters['childId']!,
          ),
        ),
        GoRoute(
          path: '/tracker/:childId',
          builder: (context, state) =>
              TrackerActiveScreen(childId: state.pathParameters['childId']!),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeNotifier = Provider.of<ThemeNotifier>(context);

    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF792D43),
          brightness: Brightness.light,
          primary: const Color(0xFF792D43),
          secondary: const Color(0xFFC15B68),
          surface: const Color(0xFFF4EDEA),
        ),
        scaffoldBackgroundColor: const Color(0xFFF4EDEA),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFC15B68),
          brightness: Brightness.dark,
          primary: const Color(0xFFC15B68),
          secondary: const Color(0xFFD6B7A6),
          surface: const Color(0xFF30232B),
        ),
        scaffoldBackgroundColor: const Color(0xFF211B20),
      ),
      themeMode: themeNotifier
          .themeMode, // Aplica Claro, Oscuro o Sistema dinámicamente
      routerConfig: _router,
    );
  }
}
