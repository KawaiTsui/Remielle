import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/gestures.dart';
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
    await tester.pump();
    final input = find.byKey(const ValueKey('todo-input'));
    for (var i = 1; i <= 5; i++) {
      await tester.enterText(input, '测试任务 $i');
      await tester.tap(find.byKey(const ValueKey('add-todo-button')));
      await tester.pump();
    }
    await tester.drag(find.byType(ListView), const Offset(0, -240));
    await tester.pump();
    expect(find.text('测试任务 5'), findsOneWidget);
  });

  testWidgets('点击 Todo 页空白处可以完成添加', (tester) async {
    await tester.pumpWidget(const ControlPanelApp());
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('todo-input')), '点击空白处添加');

    final page = find.byKey(const ValueKey('todo-blank-add-area'));
    final blankPoint = tester.getBottomRight(page) - const Offset(24, 24);
    await tester.tapAt(blankPoint);
    await tester.pump();

    expect(find.text('点击空白处添加'), findsOneWidget);
  });

  testWidgets('设置页使用测试阶段默认值', (tester) async {
    await tester.pumpWidget(const ControlPanelApp());
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('settings-tab')));
    await tester.pump();

    final startup = tester.widget<Switch>(
      find.byKey(const ValueKey('startup-switch')),
    );
    final exitTray = tester.widget<Switch>(
      find.byKey(const ValueKey('exit-tray-switch')),
    );
    final skipDeleteConfirmation = tester.widget<Switch>(
      find.byKey(const ValueKey('skip-delete-confirmation-switch')),
    );
    expect(startup.value, isFalse);
    expect(exitTray.value, isTrue);
    expect(skipDeleteConfirmation.value, isFalse);
    expect(find.text('开机启动'), findsOneWidget);
    expect(find.text('退出时同时退出托盘'), findsOneWidget);
    expect(find.text('删除 Todo 时不再二次提醒'), findsOneWidget);
  });

  testWidgets('减号按钮删除 Todo 前需要确认', (tester) async {
    await tester.pumpWidget(const ControlPanelApp());
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('todo-input')), '待删除任务');
    await tester.tap(find.byKey(const ValueKey('add-todo-button')));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('delete-todo-1')));
    await tester.pumpAndSettle();
    expect(find.text('删除 Todo'), findsOneWidget);
    expect(find.text('确定要删除“待删除任务”吗？'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('待删除任务'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('delete-todo-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-delete-todo')));
    await tester.pumpAndSettle();
    expect(find.text('待删除任务'), findsNothing);
  });

  testWidgets('Todo 右键菜单可以删除', (tester) async {
    await tester.pumpWidget(const ControlPanelApp());
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('todo-input')), '右键删除任务');
    await tester.tap(find.byKey(const ValueKey('add-todo-button')));
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey('todo-row-1')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuDivider), findsNothing);
    expect(
      find.descendant(
        of: find.byType(PopupMenuItem<String>),
        matching: find.byType(Icon),
      ),
      findsNothing,
    );
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, '删除'));
    await tester.pumpAndSettle();

    expect(find.text('删除 Todo'), findsOneWidget);
  });

  testWidgets('可以关闭删除 Todo 二次提醒', (tester) async {
    await tester.pumpWidget(const ControlPanelApp());
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('todo-input')), '直接删除任务');
    await tester.tap(find.byKey(const ValueKey('add-todo-button')));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('settings-tab')));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('skip-delete-confirmation-switch')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('todo-tab')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('delete-todo-1')));
    await tester.pumpAndSettle();

    expect(find.text('删除 Todo'), findsNothing);
    expect(find.text('直接删除任务'), findsNothing);
  });

  testWidgets('鼠标悬停时 Todo 行背景变深', (tester) async {
    await tester.pumpWidget(const ControlPanelApp());
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('todo-input')), '悬停任务');
    await tester.tap(find.byKey(const ValueKey('add-todo-button')));
    await tester.pump();

    final row = find.byKey(const ValueKey('todo-row-1'));
    final background = find.byKey(const ValueKey('todo-row-background-1'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    await mouse.moveTo(tester.getCenter(row));
    await tester.pump(const Duration(milliseconds: 120));

    expect(
      (tester.widget<AnimatedContainer>(background).decoration as BoxDecoration)
          .color,
      const Color(0xffe9e9e9),
    );

    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('todo-tab'))),
    );
    await tester.pump(const Duration(milliseconds: 120));
    expect(
      (tester.widget<AnimatedContainer>(background).decoration as BoxDecoration)
          .color,
      const Color(0xfff5f5f5),
    );
    await mouse.removePointer();
  });

  testWidgets('单击 Todo 文字编辑并点击空白处提交', (tester) async {
    await tester.pumpWidget(const ControlPanelApp());
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('todo-input')), '原始内容');
    await tester.tap(find.byKey(const ValueKey('add-todo-button')));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('todo-title-1')));
    await tester.pumpAndSettle();
    final editInput = find.byKey(const ValueKey('edit-todo-input-1'));
    expect(editInput, findsOneWidget);
    await tester.enterText(editInput, '修改后的内容');

    final page = find.byKey(const ValueKey('todo-blank-add-area'));
    await tester.tapAt(tester.getBottomRight(page) - const Offset(24, 24));
    await tester.pumpAndSettle();

    expect(editInput, findsNothing);
    expect(find.text('修改后的内容'), findsOneWidget);
  });

  testWidgets('Todo 右键菜单可以进入编辑并按回车提交', (tester) async {
    await tester.pumpWidget(const ControlPanelApp());
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('todo-input')), '右键编辑');
    await tester.tap(find.byKey(const ValueKey('add-todo-button')));
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey('todo-row-1')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, '编辑'));
    await tester.pumpAndSettle();

    final editInput = find.byKey(const ValueKey('edit-todo-input-1'));
    await tester.enterText(editInput, '回车提交内容');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(editInput, findsNothing);
    expect(find.text('回车提交内容'), findsOneWidget);
  });
}
