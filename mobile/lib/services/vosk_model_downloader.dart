import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:vosk_flutter_service/vosk_flutter_service.dart';

import '../constants.dart';

/// Прогрес завантаження моделі Vosk. [total] — null, якщо сервер не віддав
/// Content-Length (тоді показуємо лише мегабайти, без відсотка).
class VoskDownloadProgress {
  final int received;
  final int? total;

  const VoskDownloadProgress(this.received, this.total);

  double? get fraction =>
      (total == null || total == 0) ? null : received / total!;
}

/// Завантажує модель Vosk із живим прогресом — на відміну від
/// ModelLoader.loadFromNetwork (vosk_flutter_service), який чекає повну
/// HTTP-відповідь без жодного колбека прогресу. Кешує модель в той самий
/// каталог, що й ModelLoader (${ApplicationDocumentsDirectory}/models/<ім'я>),
/// тож пізніші виклики ModelLoader().loadFromNetwork() (з WakeGateService)
/// бачать той самий кеш і не качають повторно.
class VoskModelDownloader {
  String get modelName => path.basenameWithoutExtension(kVoskModelUrl);

  Future<bool> isAlreadyDownloaded() =>
      ModelLoader().isModelAlreadyLoaded(modelName);

  Future<void> download({
    required void Function(VoskDownloadProgress progress) onProgress,
  }) async {
    if (await isAlreadyDownloaded()) return;

    final request = http.Request('GET', Uri.parse(kVoskModelUrl));
    final response = await request.send();
    if (response.statusCode != 200) {
      throw Exception(
        'Сервер повернув ${response.statusCode} під час завантаження моделі',
      );
    }

    final total = response.contentLength;
    final builder = BytesBuilder(copy: false);
    var received = 0;
    await for (final chunk in response.stream) {
      builder.add(chunk);
      received += chunk.length;
      onProgress(VoskDownloadProgress(received, total));
    }
    final bytes = builder.takeBytes();

    final decompressionPath = path.join(
      (await getApplicationDocumentsDirectory()).path,
      'models',
    );
    final targetDir = Directory(path.join(decompressionPath, modelName));
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      // Розпакування великого архіву — важка синхронна робота, тож в
      // окремому ізоляті, як і в оригінальному ModelLoader._extractModel.
      await compute(
        (_) => extractArchiveToDisk(archive, decompressionPath),
        null,
      );
    } catch (_) {
      // Не лишаємо частково розпакований каталог — інакше
      // isModelAlreadyLoaded() надалі помилково вважатиме модель готовою.
      if (await targetDir.exists()) {
        await targetDir.delete(recursive: true);
      }
      rethrow;
    }
  }
}
