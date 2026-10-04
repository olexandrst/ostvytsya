import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';

import 'screens/expiry_gate.dart';
import 'services/settings_store.dart';

/// Навігатор застосунку — потрібен воротам терміну дії, щоб при його
/// закінченні закрити відкриті сторінки.
final _navigatorKey = GlobalKey<NavigatorState>();

void main() {
  // Ловимо будь-які необроблені помилки Dart і пишемо їх у системний лог
  // (видно через `adb logcat`), замість того щоб дати застосунку тихо
  // впасти без жодного сліду.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    developer.log(
      'Необроблена помилка Flutter',
      error: details.exception,
      stackTrace: details.stack,
    );
  };
  runZonedGuarded(
    () async {
      // Свіже встановлення застосунку? Підтягуємо налаштування (ключі API,
      // вибір аудіо-пристроїв тощо) з резервної копії у спільній теці — сам
      // Android їх не відновлює, бо APK ставиться збоку, а не з Play Store.
      WidgetsFlutterBinding.ensureInitialized();
      await SettingsStore().restoreIfEmpty();
      // Звіти в панель, синхронізація персонажів і досилання перемог
      // стартують НЕ тут, а лише після перевірки терміну дії квесту за часом
      // з інтернету (ExpiryGate) — до неї не працює нічого.
      runApp(const OstvytsyaApp());
    },
    (error, stack) {
      developer.log(
        'Необроблена помилка Dart',
        error: error,
        stackTrace: stack,
      );
    },
  );
}

class OstvytsyaApp extends StatelessWidget {
  const OstvytsyaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Оствиця',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E7D32)),
        useMaterial3: true,
      ),
      // Спершу — перевірка терміну дії квесту за часом з інтернету; головний
      // екран з'являється лише після неї.
      home: ExpiryGate(navigatorKey: _navigatorKey),
    );
  }
}
