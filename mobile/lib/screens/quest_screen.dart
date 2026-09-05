import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/character.dart';
import '../quest/gemini_transport.dart';
import '../quest/openai_transport.dart';
import '../quest/quest_controller.dart';
import '../quest/transport.dart';
import '../services/foreground_service.dart';
import '../services/settings_store.dart';
import '../services/status_reporter.dart';

class QuestScreen extends StatefulWidget {
  final Character character;

  const QuestScreen({super.key, required this.character});

  @override
  State<QuestScreen> createState() => _QuestScreenState();
}

class _QuestScreenState extends State<QuestScreen> {
  final _settings = SettingsStore();
  final _foreground = ForegroundServiceControl();
  final _transcript = <TranscriptLine>[];
  final _scrollCtrl = ScrollController();

  /// Термінал слухає годинами, а кожна зміна часткового розпізнавання —
  /// новий рядок. Тримаємо лише хвіст, інакше список (пам'ять і
  /// перемальовування) росте без кінця; повна історія — у журналі сесії.
  static const _maxTranscriptLines = 400;

  QuestController? _controller;
  QuestStatusUpdate _status = const QuestStatusUpdate(QuestPhase.listening);
  String? _fatalError;
  bool _stopping = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      setState(
        () => _fatalError = 'Без дозволу на мікрофон квест не можна почати.',
      );
      return;
    }
    await Permission.notification.request();
    // Не критично — якщо відмовлено, автопідбір аудіо-пристрою просто не
    // побачить Bluetooth-навушники/мікрофони (Android 12+ приховує їх без
    // цього дозволу), провідні й вбудований пристрій лишаються доступні.
    await Permission.bluetoothConnect.request();

    final character = widget.character;
    final apiKey = character.provider == 'google'
        ? await _settings.getGeminiApiKey()
        : await _settings.getOpenAiApiKey();

    if (apiKey == null || apiKey.trim().isEmpty) {
      final providerLabel = character.provider == 'google'
          ? 'Gemini'
          : 'OpenAI';
      setState(() {
        _fatalError =
            'Немає ключа $providerLabel API. Додай його в налаштуваннях застосунку.';
      });
      return;
    }

    await _foreground.start();
    final ignoringOptimizations = await _foreground
        .isIgnoringBatteryOptimizations();
    if (!ignoringOptimizations && mounted) {
      _promptBatteryExemption();
    }

    final transportFactory = character.provider == 'google'
        ? (Character c, String key) => GeminiTransport(c, key) as QuestTransport
        : (Character c, String key) =>
              OpenAiTransport(c, key) as QuestTransport;

    final controller = QuestController(
      character: character,
      apiKey: apiKey.trim(),
      transportFactory: transportFactory,
    );
    _controller = controller;

    controller.statusStream.listen((s) {
      if (mounted) setState(() => _status = s);
    });
    controller.transcriptStream.listen((line) {
      if (!mounted) return;
      setState(() {
        _transcript.add(line);
        if (_transcript.length > _maxTranscriptLines) {
          _transcript.removeRange(
            0,
            _transcript.length - _maxTranscriptLines,
          );
        }
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollCtrl.hasClients) {
          _scrollCtrl.animateTo(
            _scrollCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    });

    // Панель має бачити, що на цьому терміналі саме зараз іде квест.
    QuestActivity.started(character.displayName);
    StatusReporter.instance.reportNow();
    unawaited(controller.run());
  }

  void _promptBatteryExemption() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 8),
        content: const Text(
          'Щоб квест не засинав з вимкненим екраном, дозволь роботу без '
          'обмежень батареї.',
        ),
        action: SnackBarAction(
          label: 'Дозволити',
          onPressed: () => _foreground.requestIgnoreBatteryOptimizations(),
        ),
      ),
    );
  }

  Future<void> _stop() async {
    setState(() => _stopping = true);
    await _controller?.stop();
    await _foreground.stop();
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    QuestActivity.stopped();
    StatusReporter.instance.reportNow();
    _controller?.dispose();
    _foreground.stop();
    _scrollCtrl.dispose();
    super.dispose();
  }

  String _phaseLabel(QuestPhase phase) {
    switch (phase) {
      case QuestPhase.listening:
        final words = widget.character.effectiveWakeWords.join(', ');
        return '💤 Слухаю кодове слово: «$words»';
      case QuestPhase.connecting:
        return "🔌 З'єднання...";
      case QuestPhase.running:
        return '🎙 Квест триває';
      case QuestPhase.restarting:
        return '🔁 Перезапуск квесту...';
      case QuestPhase.stopped:
        return '⏹ Зупинено';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.character.displayName)),
      body: _fatalError != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 48,
                      color: Colors.red,
                    ),
                    const SizedBox(height: 16),
                    Text(_fatalError!, textAlign: TextAlign.center),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Назад'),
                    ),
                  ],
                ),
              ),
            )
          : Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Column(
                    children: [
                      Text(
                        _phaseLabel(_status.phase),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (_status.runCount > 0)
                        Text(
                          'Спроба №${_status.runCount}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: _transcript.isEmpty
                      ? Center(
                          child: Text(
                            _status.phase == QuestPhase.listening
                                ? 'Промов кодове слово вголос, щоб розбудити персонажа...'
                                : 'Персонаж зараз заговорить...',
                            textAlign: TextAlign.center,
                          ),
                        )
                      : ListView.builder(
                          controller: _scrollCtrl,
                          padding: const EdgeInsets.all(12),
                          itemCount: _transcript.length,
                          itemBuilder: (context, i) {
                            final line = _transcript[i];
                            final isAgent = line.who == 'agent';
                            final isSystem = line.who == 'system';
                            return Align(
                              alignment: isSystem
                                  ? Alignment.center
                                  : (isAgent
                                        ? Alignment.centerLeft
                                        : Alignment.centerRight),
                              child: Container(
                                margin: const EdgeInsets.symmetric(vertical: 4),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                constraints: BoxConstraints(
                                  maxWidth:
                                      MediaQuery.of(context).size.width * 0.8,
                                ),
                                decoration: BoxDecoration(
                                  color: isSystem
                                      ? Colors.grey.shade300
                                      : (isAgent
                                            ? Theme.of(
                                                context,
                                              ).colorScheme.primaryContainer
                                            : Theme.of(
                                                context,
                                              ).colorScheme.secondaryContainer),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(line.text),
                                    const SizedBox(height: 2),
                                    // Таймкод кожного рядка — для розбору
                                    // проблем «коли саме» важить не менше,
                                    // ніж «що саме».
                                    Text(
                                      line.timeLabel,
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.outline,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: FilledButton.icon(
                      onPressed: _stopping ? null : _stop,
                      icon: const Icon(Icons.stop),
                      label: Text(_stopping ? 'Зупиняю...' : 'Зупинити квест'),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.red,
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
