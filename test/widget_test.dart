import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:remielle/main.dart';

void main() {
  testWidgets('宠物主页显示动画资源', (tester) async {
    await tester.pumpWidget(const RemielleApp());
    expect(find.byType(PetHome), findsOneWidget);
    expect(find.byType(AnimatedGif), findsOneWidget);
    expect(find.byType(FittedBox), findsNothing);

    final animation = tester.widget<AnimatedGif>(find.byType(AnimatedGif));
    expect(animation.asset, 'assets/animations/a.gif');
    expect(animation.width, 257);
    expect(animation.height, 278);
    expect(animation.loop, isTrue);
  });

  testWidgets('单击和长按桌宠播放对应的一次性动画', (tester) async {
    await tester.pumpWidget(const RemielleApp());

    await tester.tap(find.byType(GestureDetector));
    await tester.pump();
    var animation = tester.widget<AnimatedGif>(find.byType(AnimatedGif));
    expect(animation.asset, 'assets/animations/b.gif');
    expect(animation.loop, isFalse);

    final center = tester.getCenter(
      find.byKey(const ValueKey('pet-pointer-listener')),
    );
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(5, 0));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    animation = tester.widget<AnimatedGif>(find.byType(AnimatedGif));
    expect(animation.asset, 'assets/animations/e.gif');
    expect(animation.loop, isFalse);

    await gesture.moveBy(const Offset(10, 0));
    await tester.pump();
    animation = tester.widget<AnimatedGif>(find.byType(AnimatedGif));
    expect(animation.asset, 'assets/animations/e.gif');
    expect(animation.loop, isTrue);
    await gesture.up();
  });

  testWidgets('单击和长按动画结束后自动回到常态', (tester) async {
    await tester.pumpWidget(const RemielleApp());
    final listener = find.byKey(const ValueKey('pet-pointer-listener'));

    await tester.tap(listener);
    await tester.pump();
    expect(
      tester.widget<AnimatedGif>(find.byType(AnimatedGif)).asset,
      'assets/animations/b.gif',
    );
    await tester.pump(const Duration(milliseconds: 5600));
    expect(
      tester.widget<AnimatedGif>(find.byType(AnimatedGif)).asset,
      'assets/animations/a.gif',
    );

    final gesture = await tester.startGesture(tester.getCenter(listener));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.widget<AnimatedGif>(find.byType(AnimatedGif)).asset,
      'assets/animations/e.gif',
    );
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 5600));
    expect(
      tester.widget<AnimatedGif>(find.byType(AnimatedGif)).asset,
      'assets/animations/a.gif',
    );
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
