import 'package:flutter/services.dart';

/// Аудіо-пристрій входу чи виходу — нативний список приходить із того
/// самого MethodChannel, що й PcmAudioPlayer, класифікований на
/// "wired" | "bluetooth" | "builtin" | "other" (AudioDeviceUtils.kt).
class AudioDevice {
  final String id;
  final String label;
  final String bucket;

  const AudioDevice({
    required this.id,
    required this.label,
    required this.bucket,
  });

  @override
  bool operator ==(Object other) => other is AudioDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Перелік аудіо-пристроїв входу/виходу, автоматичний вибір за пріоритетом
/// (провідний → bluetooth → вбудований) і живі сповіщення про
/// під'єднання/від'єднання — усе через нативний Android AudioManager
/// (AudioDeviceUtils.kt), бо Flutter-пакети такого не надають "з коробки"
/// для виходу (лише `record` вміє перелік входів, і той без live-подій).
class AudioDeviceService {
  static const _channel = MethodChannel(
    'com.ostvytsya.ostvytsya_quest/foreground',
  );
  static const _eventChannel = EventChannel(
    'com.ostvytsya.ostvytsya_quest/audio_devices',
  );

  static Stream<void>? _sharedChanges;

  /// Тік щоразу, коли Android повідомляє про зміну підключених
  /// аудіо-пристроїв (навушники/USB/Bluetooth). Один спільний broadcast-потік
  /// на весь застосунок — EventChannel сама підтримує кількох слухачів.
  static Stream<void> get onDevicesChanged {
    return _sharedChanges ??= _eventChannel
        .receiveBroadcastStream()
        .map((_) {})
        .handleError((_) {});
  }

  Future<List<AudioDevice>> listInputDevices() => _list('input');
  Future<List<AudioDevice>> listOutputDevices() => _list('output');

  Future<List<AudioDevice>> _list(String direction) async {
    try {
      final raw = await _channel.invokeMethod<List<Object?>>(
        'listAudioDevices',
        {'direction': direction},
      );
      if (raw == null) return const [];
      return raw
          .whereType<Map>()
          .map(
            (e) => AudioDevice(
              id: '${e['id']}',
              label: (e['label'] as String?) ?? 'Аудіо-пристрій',
              bucket: (e['bucket'] as String?) ?? 'other',
            ),
          )
          .toList();
    } on PlatformException {
      return const [];
    }
  }

  /// Прив'язати вихід нативного плеєра до пристрою (id з [listOutputDevices])
  /// або зняти прив'язку (null — система сама обирає). Змінює маршрутизацію
  /// "на льоту", без переривання відтворення.
  Future<void> setOutputDevice(String? deviceId) async {
    try {
      await _channel.invokeMethod('pcmPlayerSetOutputDevice', {
        'deviceId': deviceId == null ? null : int.tryParse(deviceId),
      });
    } on PlatformException {
      // Плеєр міг ще не стартувати — застосується при наступному запуску.
    }
  }

  /// Увімкнути мікрофон Bluetooth-гарнітури (профіль SCO/HFP).
  ///
  /// Без цього `AudioRecord`, прив'язаний до Bluetooth-мікрофона,
  /// відкривається успішно, але віддає суцільну тишу — Android не піднімає
  /// SCO самотужки. Повертає true, якщо маршрут справді перемкнено; тоді
  /// перед стартом запису лінку треба дати трохи часу ([scoSettleDelay]).
  ///
  /// Для пристроїв, які НЕ є Bluetooth-мікрофоном (звичайна колонка з самим
  /// лише A2DP, вбудований чи провідний мікрофон), нативний бік нічого не
  /// робить і повертає false — вмикати SCO для них шкідливо: він глушить
  /// A2DP і переводить звук у вузькосмуговий «телефонний» тракт.
  Future<bool> startBluetoothMic(String deviceId) async {
    try {
      final ok = await _channel.invokeMethod<bool>('startBluetoothMic', {
        'deviceId': int.tryParse(deviceId),
      });
      return ok ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> stopBluetoothMic() async {
    try {
      await _channel.invokeMethod('stopBluetoothMic');
    } on PlatformException {
      // Нічого й не вмикали — нема що вимикати.
    }
  }

  /// Скільки чекати на встановлення SCO-лінку перед стартом запису.
  /// Гарнітура піднімає його не миттєво; якщо почати писати одразу,
  /// перші пів секунди-секунда все одно будуть тишею.
  static const scoSettleDelay = Duration(milliseconds: 1200);

  /// Пріоритет для автоматичного вибору пристрою (менше — вищий пріоритет):
  /// зовнішній провідний (USB/jack) → зовнішній бездротовий (Bluetooth) →
  /// власний внутрішній.
  static int priorityRank(String bucket) {
    switch (bucket) {
      case 'wired':
        return 0;
      case 'bluetooth':
        return 1;
      case 'builtin':
        return 2;
      default:
        return 3;
    }
  }

  /// Обрати пристрій: якщо [preferredId] заданий і досі є серед [devices] —
  /// саме він; інакше найкращий доступний за пріоритетом. Викликається
  /// заново після кожної зміни списку пристроїв, тож відключення
  /// підхоплюється автоматично.
  static AudioDevice? resolve(List<AudioDevice> devices, String? preferredId) {
    if (devices.isEmpty) return null;
    if (preferredId != null) {
      for (final d in devices) {
        if (d.id == preferredId) return d;
      }
    }
    final sorted = [
      ...devices,
    ]..sort((a, b) => priorityRank(a.bucket).compareTo(priorityRank(b.bucket)));
    return sorted.first;
  }
}
