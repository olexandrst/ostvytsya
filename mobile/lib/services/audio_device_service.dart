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

/// Один активний запис цього застосунку — з якого пристрою він насправді
/// йде (AudioRecordingConfiguration з Android).
class ActiveRecording {
  final String source;
  final String? device;
  final String? bucket;
  final int? clientSampleRate;
  final int? deviceSampleRate;

  const ActiveRecording({
    required this.source,
    this.device,
    this.bucket,
    this.clientSampleRate,
    this.deviceSampleRate,
  });
}

/// Справжній стан маршрутизації звуку (AudioDeviceUtils.routeState): не
/// «який пристрій ми ОБРАЛИ», а з якого система РЕАЛЬНО пише звук, чи
/// піднято голосовий канал Bluetooth, який режим AudioManager.
class AudioRouteState {
  final String mode;
  final bool scoOn;
  final String? commDevice;
  final String? commBucket;
  final List<ActiveRecording> recordings;

  const AudioRouteState({
    required this.mode,
    required this.scoOn,
    this.commDevice,
    this.commBucket,
    this.recordings = const [],
  });

  /// Запис, що найімовірніше наш (за частотою клієнта), або перший.
  ActiveRecording? recordingAt(int sampleRate) {
    for (final r in recordings) {
      if (r.clientSampleRate == sampleRate) return r;
    }
    return recordings.isEmpty ? null : recordings.first;
  }

  /// Один рядок для журналу.
  String describe({int? sampleRate}) {
    final rec = sampleRate == null
        ? (recordings.isEmpty ? null : recordings.first)
        : recordingAt(sampleRate);
    final buf = StringBuffer();
    if (rec == null) {
      buf.write('активного запису не видно');
    } else {
      buf.write('запис іде з «${rec.device ?? 'невідомо'}»');
      if (rec.bucket != null) buf.write(' [${rec.bucket}]');
      buf.write(', джерело ${rec.source}');
      if (rec.clientSampleRate != null) {
        buf.write(', ${rec.clientSampleRate} Гц');
      }
      if (rec.deviceSampleRate != null &&
          rec.deviceSampleRate != rec.clientSampleRate) {
        buf.write(' (пристрій ${rec.deviceSampleRate} Гц');
        if (rec.deviceSampleRate == 8000) {
          buf.write(', вузькосмуговий канал');
        }
        buf.write(')');
      }
    }
    buf.write(' · пристрій розмови: ');
    buf.write(commDevice == null ? 'не задано' : '«$commDevice»');
    buf.write(' · режим $mode · SCO (старий API): ${scoOn ? 'увімкнено' : 'вимкнено'}');
    return buf.toString();
  }
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

  /// Справжній стан маршрутизації звуку (див. [AudioRouteState]); null, якщо
  /// нативний бік не відповів.
  Future<AudioRouteState?> routeState() async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>(
        'audioRouteState',
      );
      if (raw == null) return null;
      final recs = <ActiveRecording>[];
      final list = raw['recordings'];
      if (list is List) {
        for (final e in list) {
          if (e is! Map) continue;
          recs.add(
            ActiveRecording(
              source: (e['source'] as String?) ?? 'невідомо',
              device: e['device'] as String?,
              bucket: e['bucket'] as String?,
              clientSampleRate: (e['clientSampleRate'] as num?)?.toInt(),
              deviceSampleRate: (e['deviceSampleRate'] as num?)?.toInt(),
            ),
          );
        }
      }
      return AudioRouteState(
        mode: (raw['mode'] as String?) ?? 'невідомо',
        scoOn: raw['scoOn'] == true,
        commDevice: raw['commDevice'] as String?,
        commBucket: raw['commBucket'] as String?,
        recordings: recs,
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
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

  /// Підняти голосовий канал Bluetooth-гарнітури (SCO) на час усього
  /// квесту. Повертає true, якщо канал справді перемкнено.
  ///
  /// Тримати канал мусимо МИ, а не плагін `record`: він піднімає SCO лише
  /// на старті запису, а в напівдуплексі мікрофон вимкнено саме тоді, коли
  /// говорить персонаж. Тоді стан каналу й режим відтворення розходяться —
  /// і голос персонажа зникає (див. CommunicationRouter.kt).
  Future<bool> startSco() async {
    try {
      final ok = await _channel.invokeMethod<bool>('scoStart');
      return ok ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> stopSco() async {
    try {
      await _channel.invokeMethod('scoStop');
    } on PlatformException {
      // Канал і не піднімався — нема чого знімати.
    }
  }

  /// Скільки чекати, поки гарнітура встановить голосовий канал.
  static const scoSettleDelay = Duration(milliseconds: 1200);

  /// Знайти серед [devices] Bluetooth-мікрофон, якщо він є.
  ///
  /// Потрібно, щоб «прилипати» до гарнітури: коли плагін `record` піднімає
  /// SCO, список аудіо-пристроїв перебудовується, і звичайний автопідбір за
  /// пріоритетом устигає перескочити на вбудований мікрофон.
  static AudioDevice? firstBluetooth(List<AudioDevice> devices) {
    for (final d in devices) {
      if (d.bucket == 'bluetooth') return d;
    }
    return null;
  }

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
