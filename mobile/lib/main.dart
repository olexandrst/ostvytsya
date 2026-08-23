import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';

import 'screens/home_screen.dart';

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
    () {
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
