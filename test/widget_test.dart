import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:remielle/main.dart';

class _FakePeer implements PetWindowPeer {
  final calls = <({String method, Object? arguments})>[];

  @override
  Future<void> invoke(String method, [dynamic arguments]) async {
    calls.add((method: method, arguments: arguments));
  }

  bool hasCall(String method, [Object? arguments]) => calls.any(
    (call) =>
        call.method == method &&
        (arguments == null || call.arguments == arguments),
  );
}

Future<void> _pumpBubbleWindow(WidgetTester tester, _FakePeer peer) async {
  await tester.pumpWidget(
    RemielleApp(
      windowRole: PetWindowRole.bubble,
      rootWindowId: 'test-root',
      peer: peer,
    ),
  );
  await tester.pump();
}

Finder _petAnimationFinder(String asset) => find.byWidgetPredicate(
  (widget) => widget is AnimatedGif && widget.asset == asset,
);

AnimatedGif _petAnimation(WidgetTester tester, String asset) =>
    tester.widget<AnimatedGif>(_petAnimationFinder(asset));

Positioned _petAnimationPosition(WidgetTester tester, String asset) =>
    tester.widget<Positioned>(
      find.ancestor(
        of: _petAnimationFinder(asset),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Positioned &&
              widget.key == const ValueKey('pet-animation-position'),
        ),
      ),
    );

Future<void> _sendSystemEvent(
  WidgetTester tester,
  String method, {
  Object? arguments,
}) async {
  const codec = StandardMethodCodec();
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'remielle/system',
    codec.encodeMethodCall(MethodCall(method, arguments)),
    (_) {},
  );
}

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
    expect(
      tester
          .widget<Transform>(find.byKey(const ValueKey('pet-animation-scale')))
          .transform,
      Matrix4.identity(),
    );
  });

  testWidgets('单击和长按桌宠播放对应的一次性动画', (tester) async {
    await tester.pumpWidget(const RemielleApp());

    await tester.tap(find.byType(GestureDetector));
    await tester.pump();
    var animation = _petAnimation(tester, 'assets/animations/b.gif');
    expect(animation.asset, 'assets/animations/b.gif');
    expect(animation.loop, isFalse);

    final center = tester.getCenter(
      find.byKey(const ValueKey('pet-pointer-listener')),
    );
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(5, 0));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    animation = _petAnimation(tester, 'assets/animations/e.gif');
    expect(animation.asset, 'assets/animations/e.gif');
    expect(animation.loop, isFalse);

    await gesture.moveBy(const Offset(10, 0));
    await tester.pump();
    animation = _petAnimation(tester, 'assets/animations/e.gif');
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
      _petAnimation(tester, 'assets/animations/b.gif').asset,
      'assets/animations/b.gif',
    );
    await tester.pump(const Duration(milliseconds: 5600));
    expect(
      _petAnimation(tester, 'assets/animations/a.gif').asset,
      'assets/animations/a.gif',
    );

    final gesture = await tester.startGesture(tester.getCenter(listener));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      _petAnimation(tester, 'assets/animations/e.gif').asset,
      'assets/animations/e.gif',
    );
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 5600));
    expect(
      _petAnimation(tester, 'assets/animations/a.gif').asset,
      'assets/animations/a.gif',
    );
  });

  testWidgets('Ctrl 长按拖动可以等比调整人物大小', (tester) async {
    await tester.pumpWidget(const RemielleApp());
    final listener = find.byKey(const ValueKey('pet-pointer-listener'));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    final gesture = await tester.startGesture(tester.getCenter(listener));
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump();
    expect(
      tester
          .widget<Transform>(find.byKey(const ValueKey('pet-animation-scale')))
          .transform
          .getMaxScaleOnAxis(),
      closeTo(1.4, 0.01),
    );
    await gesture.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  });

  testWidgets('bubble input focus drives the busy animation', (tester) async {
    final peer = _FakePeer();
    await _pumpBubbleWindow(tester, peer);

    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(peer.hasCall('petEvent', 'inputFocus'), isTrue);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
  });

  testWidgets('bubble due date uses the Figma calendar dialog', (tester) async {
    await _pumpBubbleWindow(tester, _FakePeer());
    await tester.enterText(find.byType(TextField), 'due-date');
    await tester.pump();

    await tester.tap(find.byIcon(Icons.calendar_today_outlined));
    await tester.pumpAndSettle();

    final picker = find.byKey(const ValueKey('bubble-date-time-picker'));
    expect(picker, findsOneWidget);
    expect(tester.getSize(picker).width, 300);
    expect(find.text('\u65e5\u671f'), findsOneWidget);
    expect(find.text('\u65f6\u95f4'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('bubble-date-time-confirm-button')),
      findsOneWidget,
    );
  });

  testWidgets('气泡 Todo 右键编辑会进入行内编辑并全选文字', (tester) async {
    await _pumpBubbleWindow(tester, _FakePeer());
    final input = find.byType(TextField);
    await tester.enterText(input, '气泡右键编辑');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    await tester.tap(find.text('气泡右键编辑'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, '编辑'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    final editInput = find.byKey(const ValueKey('bubble-edit-todo-1'));
    final textField = tester.widget<TextField>(editInput);
    expect(
      textField.controller?.selection,
      const TextSelection(baseOffset: 0, extentOffset: 6),
    );
    final selectionTheme = tester.widget<TextSelectionTheme>(
      find.ancestor(of: editInput, matching: find.byType(TextSelectionTheme)),
    );
    expect(selectionTheme.data.selectionColor, const Color(0xffffb6c1));
  });

  testWidgets('bubble Todo editing accepts text input', (tester) async {
    await _pumpBubbleWindow(tester, _FakePeer());
    final input = find.byType(TextField);
    await tester.enterText(input, '原始标题');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    await tester.tap(find.text('原始标题'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, '编辑'));
    await tester.pumpAndSettle();

    final editInput = find.byKey(const ValueKey('bubble-edit-todo-1'));
    await tester.enterText(editInput, '修改后的标题');
    expect(tester.widget<TextField>(editInput).controller!.text, '修改后的标题');
  });

  testWidgets(
    'bubble Todo context reminder menu includes custom date and time',
    (tester) async {
      await _pumpBubbleWindow(tester, _FakePeer());
      final input = find.byType(TextField);
      await tester.enterText(input, 'context-reminder');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      await tester.tap(
        find.text('context-reminder'),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(PopupMenuItem<String>, '提醒'));
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(PopupMenuItem<String>, '自定义日期和时间'),
        findsOneWidget,
      );
    },
  );

  testWidgets('bubble custom reminder opens the Figma calendar dialog', (
    tester,
  ) async {
    await _pumpBubbleWindow(tester, _FakePeer());
    await tester.enterText(find.byType(TextField), 'custom-reminder');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    await tester.tap(
      find.text('custom-reminder'),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(PopupMenuItem<String>, '\u63d0\u9192'),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(
        PopupMenuItem<String>,
        '\u81ea\u5b9a\u4e49\u65e5\u671f\u548c\u65f6\u95f4',
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('bubble-date-time-picker')),
      findsOneWidget,
    );
  });

  testWidgets(
    'double-click bubble Todo editing selects text and accepts input',
    (tester) async {
      await _pumpBubbleWindow(tester, _FakePeer());
      final input = find.byType(TextField);
      await tester.enterText(input, '单击编辑');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      await tester.tap(find.text('单击编辑'));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(find.text('单击编辑'));
      await tester.pumpAndSettle();

      final editInput = find.byKey(const ValueKey('bubble-edit-todo-1'));
      final editField = tester.widget<TextField>(editInput);
      expect(
        editField.controller!.selection,
        const TextSelection(baseOffset: 0, extentOffset: 4),
      );
      await tester.enterText(editInput, '单击后输入');
      expect(tester.widget<TextField>(editInput).controller!.text, '单击后输入');
    },
  );

  testWidgets('系统文本光标激活和结束时播放忙碌动画', (tester) async {
    await tester.pumpWidget(const RemielleApp());
    await tester.pump();
    await _sendSystemEvent(tester, 'caretStateChanged', arguments: true);
    await tester.pump();
    expect(
      _petAnimation(tester, 'assets/animations/d.gif').asset,
      'assets/animations/d.gif',
    );
    var position = _petAnimationPosition(tester, 'assets/animations/d.gif');
    expect(position.left, 0);
    expect(position.bottom, 0);

    await _sendSystemEvent(tester, 'caretStateChanged', arguments: false);
    await tester.pump();
    expect(
      _petAnimation(tester, 'assets/animations/d_win.gif').asset,
      'assets/animations/d_win.gif',
    );
    position = _petAnimationPosition(tester, 'assets/animations/d_win.gif');
    expect(position.left, 0);
    expect(position.bottom, 0);

    await tester.pump(const Duration(milliseconds: 1300));
    expect(
      _petAnimation(tester, 'assets/animations/a.gif').asset,
      'assets/animations/a.gif',
    );
    position = _petAnimationPosition(tester, 'assets/animations/a.gif');
    expect(position.left, 0);
    expect(position.bottom, 0);
  });

  testWidgets('全部完成后延迟显示庆祝状态并在五秒后恢复', (tester) async {
    final peer = _FakePeer();
    await tester.pumpWidget(RemielleApp(peer: peer));
    await tester.pump();

    await _sendSystemEvent(tester, 'petEvent', arguments: 'allTodosCompleted');
    await tester.pump(const Duration(milliseconds: 999));
    expect(find.text('今天所有任务都完成啦~'), findsNothing);

    await tester.pump(const Duration(milliseconds: 1));
    expect(peer.hasCall('showAllCompleted'), isTrue);

    await tester.pump(const Duration(seconds: 5));
    expect(peer.hasCall('showAllCompleted'), isTrue);
  });

  testWidgets('光标激活但系统空闲 30 秒后回到待机', (tester) async {
    await tester.pumpWidget(const RemielleApp());
    await tester.pump();
    await _sendSystemEvent(tester, 'caretStateChanged', arguments: true);
    await tester.pump();
    expect(
      _petAnimation(tester, 'assets/animations/d.gif').asset,
      'assets/animations/d.gif',
    );

    await tester.pump(const Duration(seconds: 9));
    expect(
      _petAnimation(tester, 'assets/animations/d.gif').asset,
      'assets/animations/d.gif',
    );
    await tester.pump(const Duration(seconds: 2));
    expect(
      _petAnimation(tester, 'assets/animations/d_win.gif').asset,
      'assets/animations/d_win.gif',
    );
    await tester.pump(const Duration(milliseconds: 1300));
    expect(
      _petAnimation(tester, 'assets/animations/a.gif').asset,
      'assets/animations/a.gif',
    );

    await _sendSystemEvent(tester, 'keyboardActivity');
    await tester.pump();
    expect(
      _petAnimation(tester, 'assets/animations/d.gif').asset,
      'assets/animations/d.gif',
    );
    await _sendSystemEvent(tester, 'caretStateChanged', arguments: false);
  });

  testWidgets('caret health check requests an initial and periodic refresh', (
    tester,
  ) async {
    var refreshCount = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('remielle/system'),
      (call) async {
        if (call.method == 'requestCaretStateRefresh') refreshCount++;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('remielle/system'),
        null,
      ),
    );

    await tester.pumpWidget(const RemielleApp());
    await tester.pump();
    expect(refreshCount, 1);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(refreshCount, 2);
  });

  testWidgets('duplicate active samples do not extend the typing idle timer', (
    tester,
  ) async {
    await tester.pumpWidget(const RemielleApp());
    await tester.pump();
    await _sendSystemEvent(tester, 'caretStateChanged', arguments: true);
    await tester.pump(const Duration(seconds: 6));
    await _sendSystemEvent(tester, 'caretStateChanged', arguments: true);
    await tester.pump(const Duration(milliseconds: 4100));
    expect(
      _petAnimation(tester, 'assets/animations/d_win.gif').asset,
      'assets/animations/d_win.gif',
    );
  });

  testWidgets('bubble Todo editing can recover after deleting all text', (
    tester,
  ) async {
    await _pumpBubbleWindow(tester, _FakePeer());
    final input = find.byType(TextField);
    await tester.enterText(input, '可清空后继续编辑');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    await tester.tap(find.text('可清空后继续编辑'));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.text('可清空后继续编辑'));
    await tester.pumpAndSettle();
    final editInput = find.byKey(const ValueKey('bubble-edit-todo-1'));
    await tester.enterText(editInput, '');
    await tester.enterText(editInput, '重新输入');
    expect(tester.widget<TextField>(editInput).controller!.text, '重新输入');
  });

  testWidgets('external caret loss does not interrupt local bubble input', (
    tester,
  ) async {
    final peer = _FakePeer();
    await _pumpBubbleWindow(tester, peer);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await _sendSystemEvent(tester, 'caretStateChanged', arguments: true);
    await _sendSystemEvent(tester, 'caretStateChanged', arguments: false);
    await tester.pump();
    expect(peer.hasCall('petEvent', 'inputFocus'), isTrue);
  });

  testWidgets('pet caret loss exits busy animation after confirmation', (
    tester,
  ) async {
    await tester.pumpWidget(const RemielleApp());
    await tester.pump();
    await _sendSystemEvent(tester, 'caretStateChanged', arguments: true);
    await tester.pump();
    await _sendSystemEvent(tester, 'caretStateChanged', arguments: false);
    await tester.pump();
    expect(
      _petAnimation(tester, 'assets/animations/d_win.gif').asset,
      'assets/animations/d_win.gif',
    );
    await tester.pump(const Duration(milliseconds: 1300));
    expect(
      _petAnimation(tester, 'assets/animations/a.gif').asset,
      'assets/animations/a.gif',
    );
  });

  testWidgets('local bubble caret recovery cancels loss confirmation', (
    tester,
  ) async {
    await tester.pumpWidget(const RemielleApp());
    await tester.pump();
    await _sendSystemEvent(tester, 'caretStateChanged', arguments: true);
    await tester.pump();
    await _sendSystemEvent(tester, 'caretStateChanged', arguments: false);
    await tester.pump(const Duration(milliseconds: 200));
    await _sendSystemEvent(tester, 'caretStateChanged', arguments: true);
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      _petAnimation(tester, 'assets/animations/d.gif').asset,
      'assets/animations/d.gif',
    );
  });

  testWidgets('confirmed local caret loss is not reactivated by a refresh', (
    tester,
  ) async {
    await tester.pumpWidget(const RemielleApp());
    await tester.pump();
    await _sendSystemEvent(tester, 'caretStateChanged', arguments: true);
    await tester.pump();
    await _sendSystemEvent(tester, 'caretStateChanged', arguments: false);
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      _petAnimation(tester, 'assets/animations/d_win.gif').asset,
      'assets/animations/d_win.gif',
    );
    await _sendSystemEvent(tester, 'caretStateChanged', arguments: false);
    await tester.pump(const Duration(milliseconds: 1300));
    expect(
      _petAnimation(tester, 'assets/animations/a.gif').asset,
      'assets/animations/a.gif',
    );
  });

  testWidgets('busy animation exits after the safety limit', (tester) async {
    await tester.pumpWidget(const RemielleApp());
    await tester.pump();
    await _sendSystemEvent(tester, 'caretStateChanged', arguments: true);
    await tester.pump();
    expect(
      _petAnimation(tester, 'assets/animations/d.gif').asset,
      'assets/animations/d.gif',
    );

    // Keep the caret logically active and repeatedly reset its idle timer.
    // The animation-level safety timer must still force the exit transition.
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 4));
      await _sendSystemEvent(tester, 'keyboardActivity');
      await tester.pump();
      expect(
        _petAnimation(tester, 'assets/animations/d.gif').asset,
        'assets/animations/d.gif',
      );
    }

    await tester.pump(const Duration(milliseconds: 3100));
    expect(
      _petAnimation(tester, 'assets/animations/d_win.gif').asset,
      'assets/animations/d_win.gif',
    );
    await tester.pump(const Duration(milliseconds: 1300));
    expect(
      _petAnimation(tester, 'assets/animations/a.gif').asset,
      'assets/animations/a.gif',
    );
  });

  testWidgets('控制面板可以添加 Todo', (tester) async {
    await tester.pumpWidget(const ControlPanelApp());
    await tester.pump();
    final input = find.byKey(const ValueKey('todo-input'));
    expect(tester.widget<TextField>(input).decoration?.hintText, isNull);
    for (var i = 1; i <= 5; i++) {
      await tester.enterText(input, '测试任务 $i');
      await tester.tap(find.byKey(const ValueKey('add-todo-button')));
      await tester.pump();
    }
    await tester.drag(find.byType(ListView), const Offset(0, -240));
    await tester.pump();
    expect(find.text('测试任务 5'), findsOneWidget);
  });

  testWidgets('控制面板空 Todo 提交会结束输入状态', (tester) async {
    Future<void> expectInputEnded() async {
      await tester.pump();
      final input = tester.widget<TextField>(
        find.byKey(const ValueKey('todo-input')),
      );
      expect(input.focusNode?.hasFocus, isFalse);
      expect(find.byKey(const ValueKey('todo-row-1')), findsNothing);
    }

    await tester.pumpWidget(const ControlPanelApp());
    await tester.pump();
    final input = find.byKey(const ValueKey('todo-input'));

    await tester.tap(input);
    await tester.pump();
    expect(tester.widget<TextField>(input).focusNode?.hasFocus, isTrue);
    final page = find.byKey(const ValueKey('todo-blank-add-area'));
    await tester.tapAt(tester.getBottomRight(page) - const Offset(24, 24));
    await expectInputEnded();

    await tester.tap(input);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('add-todo-button')));
    await expectInputEnded();

    await tester.tap(input);
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await expectInputEnded();
  });

  testWidgets('气泡窗口空 Todo 提交会结束忙碌动画', (tester) async {
    final peer = _FakePeer();
    await _pumpBubbleWindow(tester, peer);
    final input = find.byType(TextField);

    await tester.tap(input);
    await tester.pump();
    expect(peer.hasCall('petEvent', 'inputFocus'), isTrue);

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(peer.hasCall('petEvent', 'inputEnd'), isTrue);
  });

  testWidgets('bubble recurrence selection does not submit the draft Todo', (
    tester,
  ) async {
    await _pumpBubbleWindow(tester, _FakePeer());
    final input = find.byType(TextField);

    await tester.enterText(input, '循环草稿');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.sync));
    await tester.pumpAndSettle();

    expect(find.text('每天'), findsOneWidget);
    await tester.tap(find.text('每天'));
    await tester.pump();

    expect(tester.widget<TextField>(input).controller!.text, '循环草稿');

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.text('循环草稿'), findsOneWidget);
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

  testWidgets('完成 Todo 后自动归档并可恢复到今日待办', (tester) async {
    await tester.pumpWidget(const ControlPanelApp());
    await tester.pump();

    expect(find.text('待办清单'), findsOneWidget);
    expect(find.text('今日待办'), findsOneWidget);
    expect(find.text('已完成'), findsNothing);
    expect(find.text('完成的 Todo 会自动归档到这里'), findsNothing);

    await tester.enterText(find.byKey(const ValueKey('todo-input')), '归档任务');
    await tester.tap(find.byKey(const ValueKey('add-todo-button')));
    await tester.pump();

    var checkbox = tester.widget<Checkbox>(
      find.byKey(const ValueKey('todo-checkbox-1')),
    );
    expect(checkbox.value, isFalse);

    await tester.tap(find.byKey(const ValueKey('todo-checkbox-1')));
    await tester.pump();

    expect(find.text('归档任务'), findsNothing);
    final now = DateTime.now();
    final archiveDay =
        '${now.year}/${now.month.toString().padLeft(2, '0')}/${now.day.toString().padLeft(2, '0')}';
    await tester.tap(find.byKey(const ValueKey('all-tasks-tab')));
    await tester.pump();
    expect(find.byKey(ValueKey('archive-day-$archiveDay')), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('archive-day-$archiveDay')));
    await tester.pump();

    checkbox = tester.widget<Checkbox>(
      find.byKey(const ValueKey('todo-checkbox-1')),
    );
    expect(checkbox.value, isTrue);
    final archivedTitle = tester.widget<Text>(find.text('归档任务'));
    expect(archivedTitle.style?.decoration, TextDecoration.lineThrough);
    expect(find.byKey(const ValueKey('todo-created-date-1')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('todo-checkbox-1')));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('todo-tab')));
    await tester.pump();

    checkbox = tester.widget<Checkbox>(
      find.byKey(const ValueKey('todo-checkbox-1')),
    );
    expect(checkbox.value, isFalse);
  });

  test('气泡只显示今天截止且未完成的 Todo', () {
    final today = DateTime(2026, 9, 10, 15);
    final visible = visibleTodayTodos([
      TodoEntry(id: 1, title: '今天', createdAt: today, dueAt: today),
      TodoEntry(
        id: 2,
        title: '未来',
        createdAt: today,
        dueAt: DateTime(2026, 9, 11),
      ),
      TodoEntry(
        id: 3,
        title: '逾期',
        createdAt: DateTime(2026, 9, 9),
        dueAt: DateTime(2026, 9, 9),
      ),
      TodoEntry(
        id: 4,
        title: '今天已完成',
        createdAt: today,
        dueAt: today,
        completedAt: today,
      ),
    ], today);

    expect(visible.map((todo) => todo.id), [1]);
  });

  test('Todo 时间和完成状态可以序列化，并兼容旧数据', () {
    final createdAt = DateTime(2026, 8, 17, 9, 30);
    final completedAt = DateTime(2026, 8, 17, 10, 15);
    final restored = TodoEntry.fromJson(
      TodoEntry(
        id: 7,
        title: '持久化任务',
        createdAt: createdAt,
        completedAt: completedAt,
      ).toJson(),
    );

    expect(restored.createdAt, createdAt);
    expect(restored.completedAt, completedAt);

    final legacy = TodoEntry.fromJson({'id': 8, 'title': '旧任务'});
    expect(legacy.completedAt, isNull);
    expect(legacy.createdAt, isNotNull);
  });

  test('Todo 子项可以序列化，并兼容没有子项的旧数据', () {
    final todo = TodoEntry(
      id: 9,
      title: '父项',
      createdAt: DateTime(2026, 9, 8),
      subtasks: const [
        TodoSubtask(id: 'a', title: '已完成子项', isCompleted: true),
        TodoSubtask(id: 'b', title: '未完成子项'),
      ],
    );
    final restored = TodoEntry.fromJson(todo.toJson());

    expect(restored.subtasks.length, 2);
    expect(restored.subtasks.first.isCompleted, isTrue);
    final todos = <TodoEntry>[
      TodoEntry(
        id: 1,
        title: 'A',
        createdAt: DateTime(2026, 9, 11),
        subtasks: const [
          TodoSubtask(id: 'a', title: 'A1'),
          TodoSubtask(id: 'b', title: 'A2'),
          TodoSubtask(id: 'c', title: 'A3'),
        ],
      ),
      TodoEntry(
        id: 2,
        title: 'B',
        createdAt: DateTime(2026, 9, 11),
        subtasks: const [TodoSubtask(id: 'd', title: 'B1')],
      ),
    ];
    expect(
      moveTodoSubtask(
        todos,
        const TodoSubtaskDragData(parentId: 1, subtaskId: 'c'),
        targetParentId: 1,
        targetSubtaskId: 'a',
      ),
      isTrue,
    );
    expect(todos.first.subtasks.map((item) => item.id), ['c', 'a', 'b']);
    expect(
      moveTodoSubtask(
        todos,
        const TodoSubtaskDragData(parentId: 1, subtaskId: 'a'),
        targetParentId: 2,
      ),
      isTrue,
    );
    expect(todos.first.subtasks.map((item) => item.id), ['c', 'b']);
    expect(todos[1].subtasks.map((item) => item.id), ['d', 'a']);
    expect(
      moveTodoSubtask(
        todos,
        const TodoSubtaskDragData(parentId: 2, subtaskId: 'd'),
        targetParentId: 1,
        targetSubtaskId: 'c',
      ),
      isTrue,
    );
    expect(todos[1].subtasks.map((item) => item.id), ['a']);
    expect(todos.first.subtasks.map((item) => item.id), ['d', 'c', 'b']);
    expect(
      promoteTodoSubtask(
        todos,
        const TodoSubtaskDragData(parentId: 1, subtaskId: 'c'),
        targetTodoId: 1,
        after: false,
        newTodoId: 3,
      ),
      isFalse,
    );
    expect(todos.length, 2);
    expect(
      promoteTodoSubtask(
        todos,
        const TodoSubtaskDragData(parentId: 1, subtaskId: 'c'),
        targetTodoId: 2,
        after: true,
        newTodoId: 3,
      ),
      isTrue,
    );
    expect(todos.length, 3);
    expect(todos.last.title, 'A3');
    expect(TodoEntry.fromJson({'id': 10, 'title': '旧任务'}).subtasks, isEmpty);
  });

  test('循环 Todo 生成下一期时重置子项完成状态', () {
    final next = nextRecurringTodo(
      TodoEntry(
        id: 1,
        title: '每日任务',
        createdAt: DateTime(2026, 9, 8),
        recurrence: TodoRecurrence.daily,
        subtasks: const [TodoSubtask(id: 'a', title: '子项', isCompleted: true)],
      ),
      const [],
    );

    expect(next, isNotNull);
    expect(next!.subtasks.single.isCompleted, isFalse);
    expect(next.subtasks.single.title, '子项');
  });

  test('循环下一期按自然周和自然月边界计算', () {
    final weekly = nextRecurringTodo(
      TodoEntry(
        id: 1,
        title: '每周任务',
        createdAt: DateTime(2026, 9, 8),
        dueAt: DateTime(2026, 9, 8),
        completedAt: DateTime(2026, 9, 8, 12),
        recurrence: TodoRecurrence.weekly,
      ),
      const [],
    );
    final monthly = nextRecurringTodo(
      TodoEntry(
        id: 2,
        title: '每月任务',
        createdAt: DateTime(2026, 9, 10),
        dueAt: DateTime(2026, 9, 10),
        completedAt: DateTime(2026, 9, 10, 12),
        recurrence: TodoRecurrence.monthly,
      ),
      const [],
    );

    expect(weekly!.createdAt, DateTime(2026, 9, 14));
    expect(weekly.dueAt, DateTime(2026, 9, 20, 23, 59, 59, 999));
    expect(monthly!.createdAt, DateTime(2026, 10, 1));
    expect(monthly.dueAt, DateTime(2026, 10, 31, 23, 59, 59, 999));
  });

  test('未完成 Todo 自动顺延到今天，已完成 Todo 保持原日期', () {
    final carriedOver = <TodoEntry>[
      TodoEntry(id: 1, title: '昨天未完成', createdAt: DateTime(2026, 9, 6, 9, 15)),
      TodoEntry(
        id: 2,
        title: '昨天已完成',
        createdAt: DateTime(2026, 9, 6, 10),
        completedAt: DateTime(2026, 9, 6, 11),
      ),
      TodoEntry(id: 3, title: '今天待办', createdAt: DateTime(2026, 9, 7, 8)),
    ];

    expect(carriedOver[0].createdAt, DateTime(2026, 9, 6, 9, 15));
    expect(carriedOver[1].createdAt, DateTime(2026, 9, 6, 10));
    expect(carriedOver[1].completedAt, DateTime(2026, 9, 6, 11));
    expect(carriedOver[2].createdAt, DateTime(2026, 9, 7, 8));
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
    final autoUpdate = tester.widget<Switch>(
      find.byKey(const ValueKey('auto-update-switch')),
    );
    final skipDeleteConfirmation = tester.widget<Switch>(
      find.byKey(const ValueKey('skip-delete-confirmation-switch')),
    );
    expect(startup.value, isFalse);
    expect(autoUpdate.value, isFalse);
    expect(exitTray.value, isTrue);
    expect(skipDeleteConfirmation.value, isFalse);
    expect(find.text('开机启动'), findsOneWidget);
    expect(find.text('退出时同时退出托盘'), findsOneWidget);
    expect(find.text('删除 Todo 时不再二次提醒'), findsOneWidget);
    expect(find.text('桌宠启动时默认显示待办气泡'), findsOneWidget);
    expect(find.text('系统设置'), findsNothing);
    expect(find.byType(Divider), findsNothing);

    final theme = Theme.of(
      tester.element(find.byKey(const ValueKey('startup-switch'))),
    );
    expect(
      theme.switchTheme.overlayColor?.resolve({WidgetState.hovered}),
      Colors.transparent,
    );
    expect(
      theme.checkboxTheme.overlayColor?.resolve({WidgetState.hovered}),
      Colors.transparent,
    );
    final checkboxSide = theme.checkboxTheme.side as WidgetStateBorderSide;
    expect(checkboxSide.resolve({})?.width, 1);
    expect(checkboxSide.resolve({})?.color, const Color(0xffd1d5db));
    expect(
      checkboxSide.resolve({WidgetState.hovered})?.color,
      const Color(0xff111111),
    );

    await tester.tap(find.byKey(const ValueKey('auto-update-switch')));
    await tester.pump();
    expect(
      tester
          .widget<Switch>(find.byKey(const ValueKey('auto-update-switch')))
          .value,
      isTrue,
    );
  });

  testWidgets('控制面板使用说明页显示操作指南和 GitHub 链接', (tester) async {
    await tester.pumpWidget(const ControlPanelApp());
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('help-tab')));
    await tester.pump();

    expect(find.byKey(const ValueKey('help-page')), findsOneWidget);
    expect(find.text('使用说明'), findsWidgets);
    expect(find.text('桌宠操作'), findsOneWidget);
    expect(find.text('气泡窗口'), findsOneWidget);
    expect(find.text('控制面板'), findsOneWidget);
    expect(find.text('Remielle 操作指南'), findsNothing);
    expect(find.textContaining('已完成归档按日期默认折叠'), findsNothing);
    await tester.drag(
      find.descendant(
        of: find.byKey(const ValueKey('help-page')),
        matching: find.byType(ListView),
      ),
      const Offset(0, -600),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('github-repository-link')),
      findsOneWidget,
    );
    expect(find.text('GitHub：KawaiTsui/Remielle'), findsOneWidget);
    expect(find.byKey(const ValueKey('github-icon')), findsOneWidget);
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
      const Color(0xfff3f4f6),
    );

    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('todo-tab'))),
    );
    await tester.pump(const Duration(milliseconds: 120));
    expect(
      (tester.widget<AnimatedContainer>(background).decoration as BoxDecoration)
          .color,
      Colors.white,
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

  testWidgets('panel due date uses the Figma date-time dialog', (tester) async {
    await tester.pumpWidget(const ControlPanelApp());
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('todo-due-date-button')));
    await tester.pumpAndSettle();

    final picker = find.byKey(const ValueKey('panel-date-time-picker'));
    expect(picker, findsOneWidget);
    expect(tester.getSize(picker), const Size(500, 362));
    expect(find.text('选择日期和时间'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('panel-date-time-confirm-button')),
      findsOneWidget,
    );
  });

  testWidgets('panel custom reminder uses the Figma date-time dialog', (
    tester,
  ) async {
    await tester.pumpWidget(const ControlPanelApp());
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('todo-reminder-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, '自定义日期和时间'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('panel-date-time-picker')),
      findsOneWidget,
    );
  });
}
