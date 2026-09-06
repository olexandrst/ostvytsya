import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'services/character_sync.dart';
import 'services/settings_store.dart';
import 'services/status_reporter.dart';
import 'services/win_reporter.dart';

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
      // Звітування саме перевіряє, чи його ввімкнено (типово — так, у
      // панель парку kDefaultServerUrl), — тут просто заводимо таймер.
      StatusReporter.instance.start();
      // Синхронізація персонажів між терміналами через ту саму панель;
      // адресу можна змінити в налаштуваннях.
      CharacterSync.instance.start();
      // Недоставлені повідомлення про перемоги (немає мережі в мить
      // перемоги) — досилаються при старті й далі раз на 5 хвилин.
      WinReporter.instance.start();
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
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E7D32)),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
