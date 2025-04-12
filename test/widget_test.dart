import 'package:flutter_test/flutter_test.dart';
import 'package:allowance/main.dart';

void main() {
  testWidgets('AllowanceApp loads successfully', (WidgetTester tester) async {
    await tester.pumpWidget(const AllowanceApp());
    expect(find.byType(AllowanceApp), findsOneWidget);
  });
}
