import 'package:flutter_test/flutter_test.dart';

import 'package:ostvytsya_quest/main.dart';

void main() {
  testWidgets('Застосунок запускається й показує заголовок', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const OstvytsyaApp());
    await tester.pump();

    // Кнопка "+" з'являється лише після того, як модель Vosk готова
    // ((не)вдале мережеве завантаження в тестовому середовищі — окрема
    // історія), тож тут перевіряємо тільки заголовок екрана.
    expect(find.text('Оствиця — квести'), findsOneWidget);
  });
}
