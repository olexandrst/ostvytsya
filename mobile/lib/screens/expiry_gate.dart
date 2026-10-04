import 'dart:async';

import 'package:flutter/material.dart';

import '../services/character_sync.dart';
import '../services/status_reporter.dart';
import '../services/trusted_time.dart';
import '../services/win_reporter.dart';
import 'home_screen.dart';

/// Ворота терміну дії квесту — корінь застосунку.
///
/// Поки час з інтернету не підтвердив, що термін не минув
/// (`kQuestExpiresAtUtc` у constants.dart), НІЧОГО не працює: ні головний екран, ні
/// звіти в панель, ні синхронізація персонажів, ні досилання перемог —
/// усе це стартує лише після успішної перевірки.
///
///   • термін минув → на весь екран «Термін дії квесту закінчився», жодних
///     кнопок і функцій;
///   • інтернету немає → «Немає з'єднання з інтернет» і «Перевірити ще раз».
///
/// Час — лише з інтернету (TrustedTime: Google і Cloudflare через HTTPS),
/// годинник телефона ролі не грає.
///
/// АКТИВНИЙ КВЕСТ НЕ ЧІПАЄМО НІКОЛИ. Перевірка відбувається при старті
/// застосунку й повторно лише коли його повернули з фону, а квесту немає
/// (екран квесту закрито) — щоб застосунок, який днями висить у пам'яті на
/// головному екрані, теж зупинився після терміну. При такій повторній
/// перевірці відсутність інтернету НЕ блокує (у цьому процесі термін уже
/// підтверджено) — блокує лише підтверджений кінець терміну. Поки відкрито
/// екран квесту (QuestActivity.active), не перевіряється нічого.
class ExpiryGate extends StatefulWidget {
  const ExpiryGate({super.key, required this.navigatorKey});

  /// Навігатор застосунку — щоб при закінченні терміну закрити відкриті
  /// поверх головного екрана сторінки (налаштування, журнали тощо).
  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<ExpiryGate> createState() => _ExpiryGateState();
}

enum _GateState { checking, valid, expired, offline }

class _ExpiryGateState extends State<ExpiryGate> with WidgetsBindingObserver {
  _GateState _state = _GateState.checking;
  bool _checkInFlight = false;
  bool _servicesStarted = false;
  bool _wentToBackground = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_check(blocking: true));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _wentToBackground = true;
      return;
    }
    if (state != AppLifecycleState.resumed || !_wentToBackground) return;
    _wentToBackground = false;
    // Квест іде чи відкрито його екран — нічого не перевіряємо.
    if (QuestActivity.active) return;
    switch (_state) {
      case _GateState.valid:
        unawaited(_check(blocking: false));
      case _GateState.offline:
        // Повернулись у застосунок (напр. після ввімкнення Wi-Fi) — одразу
        // пробуємо ще раз, не чекаючи кнопки.
        unawaited(_check(blocking: true));
      case _GateState.checking:
      case _GateState.expired:
        break;
    }
  }

  /// [blocking] — перевірка при старті чи з екрана «немає з'єднання»:
  /// поки триває, показуємо «Перевіряю…», а без інтернету блокуємо.
  /// Інакше — тиха повторна перевірка працюючого застосунку: діє лише на
  /// підтверджений кінець терміну.
  Future<void> _check({required bool blocking}) async {
    if (_checkInFlight) return;
    _checkInFlight = true;
    if (blocking && mounted) setState(() => _state = _GateState.checking);
    final ExpiryVerdict verdict;
    try {
      verdict = await QuestExpiry.check();
    } finally {
      _checkInFlight = false;
    }
    if (!mounted) return;
    // Поки чекали відповіді, могли відкрити квест — його не чіпаємо.
    if (!blocking && QuestActivity.active) return;
    switch (verdict) {
      case ExpiryVerdict.valid:
        setState(() => _state = _GateState.valid);
        _startServices();
      case ExpiryVerdict.expired:
        _lock();
      case ExpiryVerdict.offline:
        if (blocking) setState(() => _state = _GateState.offline);
    }
  }

  void _startServices() {
    if (_servicesStarted) return;
    _servicesStarted = true;
    // Звітування саме перевіряє, чи його ввімкнено (типово — так, у
    // панель парку kDefaultServerUrl), — тут просто заводимо таймер.
    StatusReporter.instance.start();
    // Синхронізація персонажів між терміналами через ту саму панель;
    // адресу можна змінити в налаштуваннях.
    CharacterSync.instance.start();
    // Недоставлені повідомлення про перемоги (немає мережі в мить
    // перемоги) — досилаються при старті й далі раз на 5 хвилин.
    WinReporter.instance.start();
  }

  /// Термін минув: зупинити все й лишити тільки повідомлення.
  void _lock() {
    if (_servicesStarted) {
      _servicesStarted = false;
      StatusReporter.instance.stop();
      CharacterSync.instance.stop();
      WinReporter.instance.stop();
    }
    widget.navigatorKey.currentState?.popUntil((route) => route.isFirst);
    setState(() => _state = _GateState.expired);
  }

  @override
  Widget build(BuildContext context) {
    switch (_state) {
      case _GateState.valid:
        return const HomeScreen();
      case _GateState.checking:
        return const _FullScreenMessage(
          icon: null,
          text: 'Перевіряю з\'єднання…',
          busy: true,
        );
      case _GateState.expired:
        return const _FullScreenMessage(
          icon: Icons.event_busy,
          text: 'Термін дії квесту закінчився',
        );
      case _GateState.offline:
        return _FullScreenMessage(
          icon: Icons.wifi_off,
          text: 'Немає з\'єднання з інтернет',
          action: FilledButton.icon(
            onPressed: () => unawaited(_check(blocking: true)),
            icon: const Icon(Icons.refresh),
            label: const Text('Перевірити ще раз'),
          ),
        );
    }
  }
}

class _FullScreenMessage extends StatelessWidget {
  const _FullScreenMessage({
    required this.icon,
    required this.text,
    this.action,
    this.busy = false,
  });

  final IconData? icon;
  final String text;
  final Widget? action;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (busy)
                  const CircularProgressIndicator()
                else if (icon != null)
                  Icon(icon, size: 96, color: theme.colorScheme.primary),
                const SizedBox(height: 32),
                Text(
                  text,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineMedium,
                ),
                if (action != null) ...[
                  const SizedBox(height: 32),
                  action!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
