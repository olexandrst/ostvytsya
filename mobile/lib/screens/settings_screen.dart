import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../constants.dart';
import '../services/audio_device_service.dart';
import '../services/character_sync.dart';
import '../services/settings_store.dart';
import '../services/status_reporter.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _store = SettingsStore();
  final _audioDevices = AudioDeviceService();
  final _geminiCtrl = TextEditingController();
  final _openaiCtrl = TextEditingController();
  final _instanceIdCtrl = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  bool _showGemini = false;
  bool _showOpenAi = false;
  bool _sessionRecordingEnabled = false;
  bool _statusReportingEnabled = false;
  final _statusServerCtrl = TextEditingController();

  List<AudioDevice> _inputDevices = [];
  List<AudioDevice> _outputDevices = [];
  String? _selectedInputId;
  String? _selectedOutputId;
  StreamSubscription<void>? _deviceChangeSub;

  @override
  void initState() {
    super.initState();
    _load();
    _deviceChangeSub = AudioDeviceService.onDevicesChanged.listen(
      (_) => _loadDevices(),
    );
  }

  Future<void> _load() async {
    final gemini = await _store.getGeminiApiKey();
    final openai = await _store.getOpenAiApiKey();
    final instanceId = await _store.getInstanceId();
    _selectedInputId = await _store.getPreferredInputDeviceId();
    _selectedOutputId = await _store.getPreferredOutputDeviceId();
    _sessionRecordingEnabled = await _store.getSessionRecordingEnabled();
    _statusReportingEnabled = await _store.getStatusReportingEnabled();
    _statusServerCtrl.text = await _store.getStatusServerUrl() ?? '';
    _geminiCtrl.text = gemini ?? '';
    _openaiCtrl.text = openai ?? '';
    _instanceIdCtrl.text = instanceId;
    // Без цього дозволу Android 12+ приховує Bluetooth-пристрої зі списку
    // (AudioManager.getDevices) — без нього автопідбір їх просто не бачить.
    await Permission.bluetoothConnect.request();
    await _loadDevices();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadDevices() async {
    final inputs = await _audioDevices.listInputDevices();
    final outputs = await _audioDevices.listOutputDevices();
    if (mounted) {
      setState(() {
        _inputDevices = inputs;
        _outputDevices = outputs;
      });
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await _store.setGeminiApiKey(_geminiCtrl.text);
    await _store.setOpenAiApiKey(_openaiCtrl.text);
    await _store.setInstanceId(_instanceIdCtrl.text);
    await _store.setPreferredInputDeviceId(_selectedInputId);
    await _store.setPreferredOutputDeviceId(_selectedOutputId);
    await _store.setSessionRecordingEnabled(_sessionRecordingEnabled);
    await _store.setStatusReportingEnabled(_statusReportingEnabled);
    await _store.setStatusServerUrl(_statusServerCtrl.text);
    // Перезапускаємо звітування з новими налаштуваннями (або зупиняємо,
    // якщо його щойно вимкнули).
    if (_statusReportingEnabled) {
      StatusReporter.instance.start();
    } else {
      StatusReporter.instance.stop();
    }
    // Адресу сервера могли щойно вписати/змінити — одразу пробуємо
    // синхронізувати персонажів, не чекаючи наступного такту.
    CharacterSync.instance.syncNow();
    if (mounted) {
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Налаштування збережено на пристрої')),
      );
    }
  }

  void _regenerateInstanceId() {
    setState(() {
      _instanceIdCtrl.text = SettingsStore.generateInstanceId();
    });
  }

  void _copyInstanceId() {
    Clipboard.setData(ClipboardData(text: _instanceIdCtrl.text));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Скопійовано в буфер обміну')));
  }

  @override
  void dispose() {
    _deviceChangeSub?.cancel();
    _geminiCtrl.dispose();
    _openaiCtrl.dispose();
    _instanceIdCtrl.dispose();
    _statusServerCtrl.dispose();
    super.dispose();
  }

  String _bucketIcon(String bucket) {
    switch (bucket) {
      case 'wired':
        return '🔌 ';
      case 'bluetooth':
        return '📶 ';
      case 'builtin':
        return '📱 ';
      default:
        return '';
    }
  }

  Widget _deviceDropdown({
    required String label,
    required List<AudioDevice> devices,
    required String? selectedId,
    required void Function(String?) onChanged,
  }) {
    final valueExists = devices.any((d) => d.id == selectedId);
    return DropdownButtonFormField<String?>(
      initialValue: valueExists ? selectedId : null,
      decoration: InputDecoration(labelText: label),
      isExpanded: true,
      items: [
        const DropdownMenuItem<String?>(
          value: null,
          child: Text('Автоматично (за пріоритетом)'),
        ),
        ...devices.map(
          (d) => DropdownMenuItem<String?>(
            value: d.id,
            child: Text(
              '${_bucketIcon(d.bucket)}${d.label}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
      onChanged: onChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Налаштування'),
        actions: [
          IconButton(
            icon: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.check),
            onPressed: _saving ? null : _save,
            tooltip: 'Зберегти',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Ключі API зберігаються лише на цьому пристрої (захищене '
                  'сховище). Жодного сервера й логіна — застосунок звертається '
                  'до Gemini/OpenAI напряму з цими ключами.',
                  style: TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _geminiCtrl,
                  obscureText: !_showGemini,
                  decoration: InputDecoration(
                    labelText: 'Gemini API ключ',
                    helperText: 'aistudio.google.com/apikey',
                    suffixIcon: IconButton(
                      icon: Icon(
                        _showGemini ? Icons.visibility_off : Icons.visibility,
                      ),
                      onPressed: () =>
                          setState(() => _showGemini = !_showGemini),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _openaiCtrl,
                  obscureText: !_showOpenAi,
                  decoration: InputDecoration(
                    labelText: 'OpenAI API ключ',
                    helperText: 'platform.openai.com/api-keys',
                    suffixIcon: IconButton(
                      icon: Icon(
                        _showOpenAi ? Icons.visibility_off : Icons.visibility,
                      ),
                      onPressed: () =>
                          setState(() => _showOpenAi = !_showOpenAi),
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                const Divider(),
                const SizedBox(height: 8),
                const Text(
                  'Аудіо-пристрої',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'За замовчуванням — автоматичний вибір за пріоритетом: '
                  'провідний (USB/jack) → бездротовий (Bluetooth) → '
                  'вбудований. Якщо обраний пристрій від\'єднається, '
                  'застосунок сам перемкнеться на наступний за пріоритетом, '
                  'не перериваючи квест.',
                  style: TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 12),
                _deviceDropdown(
                  label: 'Вхід (мікрофон)',
                  devices: _inputDevices,
                  selectedId: _selectedInputId,
                  onChanged: (id) => setState(() => _selectedInputId = id),
                ),
                const SizedBox(height: 16),
                _deviceDropdown(
                  label: 'Вихід (звук)',
                  devices: _outputDevices,
                  selectedId: _selectedOutputId,
                  onChanged: (id) => setState(() => _selectedOutputId = id),
                ),
                const SizedBox(height: 32),
                const Divider(),
                const SizedBox(height: 8),
                const Text(
                  'Ідентифікатор пристрою',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'За замовчуванням прив\'язаний саме до цього телефону '
                  '(лишається той самий навіть після перевстановлення '
                  'застосунку) — допомагає розрізняти примірники (напр. на '
                  'різних телефонах чи в різних локаціях квесту). Можеш '
                  'замінити на власну назву.',
                  style: TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _instanceIdCtrl,
                  decoration: InputDecoration(
                    labelText: 'Ідентифікатор',
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.copy),
                          tooltip: 'Копіювати',
                          onPressed: _copyInstanceId,
                        ),
                        IconButton(
                          icon: const Icon(Icons.refresh),
                          tooltip: 'Згенерувати новий',
                          onPressed: _regenerateInstanceId,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                const Divider(),
                const SizedBox(height: 8),
                const Text(
                  'Запис сесій',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Увімкнено за замовчуванням (займає місце на диску — до '
                  '~11 МБ на одну сесію). Зберігається в теці застосунку на '
                  'зовнішній пам\'яті (Android/data/…/files/sessions) — '
                  'дістати файли можна файловим менеджером або через '
                  '«Записи сесій» на головному екрані.',
                  style: TextStyle(color: Colors.grey),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Записувати кожну сесію квесту'),
                  value: _sessionRecordingEnabled,
                  onChanged: (v) =>
                      setState(() => _sessionRecordingEnabled = v),
                ),
                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 8),
                const Text(
                  'Звіти в панель',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Вимкнено за замовчуванням. Якщо увімкнути — раз на 5 хвилин '
                  'застосунок надсилає в панель свій стан: ідентифікатор, чи '
                  'йде квест, модель телефону, заряд (свій і Bluetooth-'
                  'пристроїв) та координати. Працює у фоні й ні на що не '
                  'впливає: якщо сервер недоступний, квест іде як завжди.\n\n'
                  'Сама адреса сервера (незалежно від перемикача звітів) '
                  'також вмикає синхронізацію персонажів між терміналами: '
                  'правка персонажа на одному телефоні за кілька хвилин '
                  "з'являється на всіх інших.",
                  style: TextStyle(color: Colors.grey),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Надсилати статус у панель'),
                  value: _statusReportingEnabled,
                  onChanged: (v) => setState(() => _statusReportingEnabled = v),
                ),
                TextField(
                  controller: _statusServerCtrl,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'Адреса сервера',
                    hintText: 'https://host:port',
                    // Адреса важлива і без перемикача звітів (нею ж
                    // вмикається синхронізація персонажів) — тож і помилку
                    // показуємо незалежно від нього.
                    errorText:
                        _statusServerCtrl.text.trim().isNotEmpty &&
                            StatusReporter.normalizeServerUrl(
                                  _statusServerCtrl.text,
                                ) ==
                                null
                        ? 'Очікується адреса у вигляді https://host:port'
                        : null,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Номер телефону Android віддає лише тоді, коли його записав '
                  'на SIM-карту оператор — здебільшого ця колонка в панелі '
                  'лишається порожньою. Заряд Bluetooth-пристрою теж доступний '
                  'не на всіх телефонах.',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 8),
                Text(
                  'Версія: ${kAppVersion.isEmpty ? 'локальна збірка' : kAppVersion}',
                  style: const TextStyle(color: Colors.grey),
                ),
              ],
            ),
    );
  }
}
