import 'package:flutter_test/flutter_test.dart';
import 'package:ostvytsya_quest/quest/transcript_utils.dart';

void main() {
  test('дужки й зірочки в живій мові — не ремарка', () {
    expect(
      findStageDirection('Отакої… (вже й про князя знаєте?) Значить від Морени!'),
      null,
    );
    expect(findStageDirection('*Загадка перша.* Місце, де воскресають Боги.'), null);
  });
  test('окреме речення з означень і слова про сміх', () {
    expect(
      findStageDirection('Короткий хитрий смішок. Отакої!'),
      'Короткий хитрий смішок',
    );
    expect(
      findStageDirection('Дзвінкий пустотливий сміх. Значить від Морени.'),
      'Дзвінкий пустотливий сміх',
    );
  });
  test('окреме речення з дієсловом-описом', () {
    expect(findStageDirection('Дзвінко сміється. Отакої!'), 'Дзвінко сміється');
    expect(findStageDirection('Хихикає. Ну ж бо!'), 'Хихикає');
  });
  test('жива мова не чіпається', () {
    expect(findStageDirection('Успіхів, малята! А я піду вітри рахувати!'), null);
    expect(findStageDirection('Ой, який сміх у вас дзвінкий, малята!'), null);
    expect(findStageDirection('Усмішкою вас зустрічаю, мандрівнички!'), null);
  });
  test('незакінчене речення не перевіряється', () {
    expect(findStageDirection('Ой, дзвінкий сміх'), null);
    expect(findStageDirection('Дзвінкий сміх.'), 'Дзвінкий сміх');
  });
}
