import 'package:flutter_test/flutter_test.dart';
import 'package:ostvytsya_quest/quest/transcript_utils.dart';

void main() {
  test('ремарка в дужках', () {
    expect(
      findStageDirection('Отакої… (короткий хитрий смішок) вже й про князя!'),
      '(короткий хитрий смішок)',
    );
  });
  test('ремарка в зірочках', () {
    expect(
      findStageDirection('*хитро підморгує* Ну ж бо!'),
      '*хитро підморгує*',
    );
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
