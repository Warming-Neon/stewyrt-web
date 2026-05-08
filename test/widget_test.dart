import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:stewyrt/main.dart';
import 'package:stewyrt/theme/theme_notifier.dart';

void main() {
  testWidgets('App renders smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ThemeNotifier(),
        child: const StewyrtApp(),
      ),
    );
    expect(find.text('The Pulse'), findsOneWidget);
  });
}
