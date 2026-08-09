import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ostvytsya_quest/main.dart';

void main() {
  testWidgets('Застосунок запускається й показує заголовок', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const OstvytsyaApp());
    await tester.pump();

    expect(find.text('Оствиця — квести'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
  });
}
