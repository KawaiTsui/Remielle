import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:remielle/main.dart';

void main() {
  testWidgets('宠物主页显示动画资源', (tester) async {
    await tester.pumpWidget(const RemielleApp());
    expect(find.byType(PetHome), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('控制面板可以添加 Todo', (tester) async {
    await tester.pumpWidget(const ControlPanelApp());
    final input = find.byType(TextField);
    for (var i = 1; i <= 5; i++) {
      await tester.enterText(input, '测试任务 $i');
      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
    }
    await tester.drag(find.byType(ListView), const Offset(0, -240));
    await tester.pump();
    expect(find.text('测试任务 5'), findsOneWidget);
  });
}
