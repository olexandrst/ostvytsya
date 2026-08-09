import 'package:flutter_test/flutter_test.dart';
import 'package:ostvytsya_quest/quest/wake_matcher.dart';

void main() {
  test('оствиця exact', () {
    expect(matchesWakeWord('оствиця', ['Оствиця']), isTrue);
  });
  test('от свиця fuzzy', () {
    expect(matchesWakeWord('от свиця', ['Оствиця']), isTrue);
  });
  test('оствиц (missing last letter) fuzzy', () {
    expect(matchesWakeWord('оствиц', ['Оствиця']), isTrue);
  });
  test('no match', () {
    expect(matchesWakeWord('привіт як справи', ['Оствиця']), isFalse);
  });
  test('вихор', () {
    expect(matchesWakeWord('вихор прийди', ['Вихор', 'вихір']), isTrue);
  });
  test('домовичок', () {
    expect(matchesWakeWord('домовичок будь ласка', ['Домовичок']), isTrue);
  });
}
