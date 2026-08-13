import 'package:flutter/services.dart';

/// Доступ до `Settings.Secure.ANDROID_ID` — стабільного на цьому пристрої
/// (для цього застосунку й користувача) ідентифікатора, без жодних
/// runtime-дозволів (на відміну від IMEI, недоступного звичайним
/// застосункам на Android 10+). Скидається лише при скиданні пристрою до
/// заводських налаштувань.
class DeviceIdService {
  static const _channel = MethodChannel(
    'com.ostvytsya.ostvytsya_quest/foreground',
  );

  Future<String?> getAndroidId() async {
    try {
      return await _channel.invokeMethod<String>('getAndroidId');
    } on PlatformException {
      return null;
    }
  }
}
