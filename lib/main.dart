import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

part 'control_panel.dart';

const _petStageWidth = 341.0;
const _petStageHeight = 298.0;

Future<void> main(List<String> args) async {
  final isControlPanel = args.contains('--control-panel');
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  if (isControlPanel) {
    const options = WindowOptions(
      size: Size(960, 720),
      minimumSize: Size(720, 520),
      center: true,
      title: 'Remielle 控制面板',
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.normal,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
    runApp(const ControlPanelApp());
    return;
  }

  final savedPosition = await _PetWindowPositionStore.load();
  final options = WindowOptions(
    size: Size(_petStageWidth, 548),
    minimumSize: Size(_petStageWidth, 548),
    maximumSize: Size(_petStageWidth, 548),
    center: savedPosition == null,
    backgroundColor: Colors.transparent,
    skipTaskbar: true,
    titleBarStyle: TitleBarStyle.hidden,
    alwaysOnTop: true,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.setAsFrameless();
    await windowManager.setBackgroundColor(Colors.transparent);
    await windowManager.setResizable(false);
    if (savedPosition == null) {
      await windowManager.center();
    } else {
      await windowManager.setPosition(savedPosition);
    }
    await windowManager.show();
    await windowManager.focus();
  });
  final panelData = await _PanelDataStore.load();
  runApp(RemielleApp(initialBubbleVisible: panelData.bubbleVisibleByDefault));
}

class _PetWindowPositionStore {
  static File get _file {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    final base = localAppData == null || localAppData.isEmpty
        ? Directory.systemTemp.path
        : localAppData;
    return File('$base\\Remielle\\pet_window.json');
  }

  static Future<Offset?> load() async {
    try {
      if (!await _file.exists()) return null;
      final json = jsonDecode(await _file.readAsString());
      if (json is! Map<String, dynamic>) return null;
      final x = json['x'];
      final y = json['y'];
      if (x is! num || y is! num || !x.isFinite || !y.isFinite) return null;
      return Offset(x.toDouble(), y.toDouble());
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(Offset position) async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(
      jsonEncode({'x': position.dx, 'y': position.dy}),
      flush: true,
    );
  }
}

class RemielleApp extends StatelessWidget {
  const RemielleApp({super.key, this.initialBubbleVisible = true});

  final bool initialBubbleVisible;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Remielle',
    theme: _theme(),
    home: PetHome(initialBubbleVisible: initialBubbleVisible),
  );
}

ThemeData _theme() => ThemeData(
  colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xffe986a9)),
  useMaterial3: true,
);

enum _PetAnimation {
  normal,
  normalEnd,
  tap,
  longPress,
  busy,
  busyEnd,
  todoDone,
}

const _animationSizes = <String, Size>{
  'assets/animations/a.gif': Size(257, 278),
  'assets/animations/a_win.gif': Size(257, 290),
  'assets/animations/b.gif': Size(258, 285),
  'assets/animations/c.gif': Size(273, 280),
  'assets/animations/d.gif': Size(295, 279),
  'assets/animations/d_win.gif': Size(303, 298),
  'assets/animations/e.gif': Size(258, 289),
};

const _animationDurations = <String, Duration>{
  'assets/animations/a_win.gif': Duration(milliseconds: 5320),
  'assets/animations/b.gif': Duration(milliseconds: 5400),
  'assets/animations/c.gif': Duration(milliseconds: 2040),
  'assets/animations/d_win.gif': Duration(milliseconds: 1120),
  'assets/animations/e.gif': Duration(milliseconds: 5400),
};

const _animationOffsets = <String, Offset>{
  'assets/animations/d.gif': Offset(-23, 0),
  'assets/animations/d_win.gif': Offset(-21, 3),
};

const _systemChannel = MethodChannel('remielle/system');
const _caretIdleLimit = Duration(seconds: 10);

File get _petEventFile {
  final localAppData = Platform.environment['LOCALAPPDATA'];
  final base = localAppData == null || localAppData.isEmpty
      ? Directory.systemTemp.path
      : localAppData;
  return File('$base\\Remielle\\pet_events.log');
}

Future<void> _sendPetEvent(String event) async {
  if (Platform.environment.containsKey('FLUTTER_TEST')) return;
  if (Platform.isWindows) {
    await _systemChannel.invokeMethod<void>('sendPetEvent', event);
    return;
  }
  final file = _petEventFile;
  await file.parent.create(recursive: true);
  await file.writeAsString(
    '${DateTime.now().microsecondsSinceEpoch}:$event\n',
    mode: FileMode.append,
    flush: true,
  );
}

class PetHome extends StatefulWidget {
  const PetHome({super.key, this.initialBubbleVisible = true});

  final bool initialBubbleVisible;

  @override
  State<PetHome> createState() => _PetHomeState();
}

class _PetHomeState extends State<PetHome> with WindowListener, TrayListener {
  static const _bubbleInteractionHeight = 240.0;

  _PetAnimation _animation = _PetAnimation.normal;
  final _bubbleTodoController = TextEditingController();
  final _bubbleTodoFocusNode = FocusNode();
  bool _mouseThrough = false;
  bool _alwaysOnTop = true;
  Timer? _randomNormalTimer;
  Timer? _caretIdleTimer;
  StreamSubscription<FileSystemEvent>? _todoFileWatcher;
  Timer? _todoRefreshDebounce;
  Timer? _positionSaveDebounce;
  Timer? _longPressTimer;
  Timer? _animationCompletionTimer;
  int _animationRevision = 0;
  final _random = Random();
  Offset? _pointerDownPosition;
  bool _pointerDragging = false;
  bool _longPressTriggered = false;
  bool _windowDragging = false;
  bool _petVisible = true;
  bool _systemCaretActive = false;
  bool _caretIdleSuppressed = false;
  bool _bubbleInputActive = false;
  bool _bubbleEditInputActive = false;
  late bool _bubbleVisible;
  List<TodoEntry> _todos = const [];

  @override
  void initState() {
    super.initState();
    _bubbleVisible = widget.initialBubbleVisible;
    windowManager.addListener(this);
    trayManager.addListener(this);
    _initialize();
    _initializeCaretMonitoring();
    _bubbleTodoFocusNode.addListener(_handleBubbleInputFocus);
    _refreshTodos();
    _initializeTodoWatcher();
    _scheduleRandomNormalEnd();
  }

  Future<void> _initialize() async {
    await trayManager.setIcon('windows/runner/resources/app_icon.ico');
    await trayManager.setToolTip('Remielle 桌面宠物');
    await _refreshMenu();
  }

  Future<void> _refreshMenu() => trayManager.setContextMenu(
    Menu(
      items: [
        MenuItem(key: 'panel', label: '控制面板'),
        if (!_petVisible) MenuItem(key: 'showPet', label: '显示桌宠'),
        MenuItem.checkbox(
          key: 'through',
          label: '鼠标穿透',
          checked: _mouseThrough,
        ),
        MenuItem.checkbox(key: 'top', label: '置顶', checked: _alwaysOnTop),
        MenuItem.separator(),
        MenuItem(
          key: _petVisible ? 'exitPet' : 'exitTray',
          label: _petVisible ? '退出桌宠' : '退出托盘',
        ),
      ],
    ),
  );

  @override
  void dispose() {
    _randomNormalTimer?.cancel();
    _caretIdleTimer?.cancel();
    _longPressTimer?.cancel();
    _animationCompletionTimer?.cancel();
    _todoRefreshDebounce?.cancel();
    _positionSaveDebounce?.cancel();
    _todoFileWatcher?.cancel();
    _bubbleTodoFocusNode.removeListener(_handleBubbleInputFocus);
    _bubbleTodoController.dispose();
    _bubbleTodoFocusNode.dispose();
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    super.dispose();
  }

  @override
  void onTrayIconMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem item) {
    switch (item.key) {
      case 'panel':
        _openPanelWindow();
      case 'through':
        _setMouseThrough(!_mouseThrough);
      case 'top':
        _setAlwaysOnTop(!_alwaysOnTop);
      case 'showPet':
        _showPet();
      case 'exitPet':
        _exitPet();
      case 'exitTray':
        _exitApplication();
    }
  }

  Future<void> _setMouseThrough(bool value) async {
    setState(() => _mouseThrough = value);
    await windowManager.setIgnoreMouseEvents(value, forward: true);
    await _refreshMenu();
  }

  Future<void> _setAlwaysOnTop(bool value) async {
    setState(() => _alwaysOnTop = value);
    await windowManager.setAlwaysOnTop(value);
    await _refreshMenu();
  }

  Future<void> _showPet() async {
    _petVisible = true;
    await windowManager.show();
    await windowManager.focus();
    await _refreshMenu();
  }

  Future<void> _hidePet() async {
    await _saveWindowPosition();
    _petVisible = false;
    await windowManager.hide();
    await _refreshMenu();
  }

  Future<void> _exitPet() async {
    final settings = await _PanelDataStore.load();
    if (settings.exitTrayOnPetExit) {
      await _exitApplication();
      return;
    }
    await _hidePet();
  }

  Future<void> _exitApplication() async {
    await _saveWindowPosition();
    _panelProcess?.kill();
    await trayManager.destroy();
    exit(0);
  }

  @override
  Future<void> onWindowClose() => _hidePet();

  String get _animationAsset => switch (_animation) {
    _PetAnimation.normal => 'assets/animations/a.gif',
    _PetAnimation.normalEnd => 'assets/animations/a_win.gif',
    _PetAnimation.tap => 'assets/animations/b.gif',
    _PetAnimation.longPress => 'assets/animations/e.gif',
    _PetAnimation.busy => 'assets/animations/d.gif',
    _PetAnimation.busyEnd => 'assets/animations/d_win.gif',
    _PetAnimation.todoDone => 'assets/animations/c.gif',
  };

  Size get _assetSize => _animationSizes[_animationAsset]!;

  Offset get _assetOffset => _animationOffsets[_animationAsset] ?? Offset.zero;

  Future<void> _refreshTodos() async {
    final data = await _PanelDataStore.load();
    if (!mounted) return;
    final now = DateTime.now();
    final next = List<TodoEntry>.unmodifiable(
      data.todos.where((todo) => _isSameDay(todo.createdAt, now)),
    );
    if (_todos.length == next.length &&
        _todos.asMap().entries.every(
          (entry) =>
              entry.value.id == next[entry.key].id &&
              entry.value.title == next[entry.key].title &&
              entry.value.completedAt == next[entry.key].completedAt,
        )) {
      return;
    }
    setState(() => _todos = next);
  }

  Future<void> _saveBubbleTodos(
    _PanelData current,
    List<TodoEntry> todos,
  ) async {
    await _PanelDataStore.save(
      _PanelData(
        todos: List.unmodifiable(todos),
        launchAtStartup: current.launchAtStartup,
        exitTrayOnPetExit: current.exitTrayOnPetExit,
        skipTodoDeleteConfirmation: current.skipTodoDeleteConfirmation,
        bubbleVisibleByDefault: current.bubbleVisibleByDefault,
      ),
    );
    if (mounted) {
      final now = DateTime.now();
      setState(
        () => _todos = List.unmodifiable(
          todos.where((todo) => _isSameDay(todo.createdAt, now)),
        ),
      );
    }
  }

  Future<void> _addBubbleTodo() async {
    final title = _bubbleTodoController.text.trim();
    if (title.isEmpty) return;
    final current = await _PanelDataStore.load();
    final nextId =
        current.todos.fold<int>(0, (maxId, todo) => max(maxId, todo.id)) + 1;
    final todos = List<TodoEntry>.of(current.todos)
      ..add(TodoEntry(id: nextId, title: title, createdAt: DateTime.now()));
    await _saveBubbleTodos(current, todos);
    _bubbleTodoController.clear();
    _bubbleTodoFocusNode.unfocus();
  }

  Future<void> _toggleBubbleTodo(TodoEntry todo) async {
    final current = await _PanelDataStore.load();
    final todos = List<TodoEntry>.of(current.todos);
    final index = todos.indexWhere((item) => item.id == todo.id);
    if (index < 0) return;
    final completing = todos[index].completedAt == null;
    todos[index] = completing
        ? todos[index].copyWith(completedAt: DateTime.now())
        : todos[index].copyWith(
            createdAt: DateTime.now(),
            clearCompletedAt: true,
          );
    await _saveBubbleTodos(current, todos);
    if (completing && mounted) _playAnimation(_PetAnimation.todoDone);
  }

  Future<void> _showBubbleTodoMenu(
    TodoEntry todo,
    Offset globalPosition,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = overlay.globalToLocal(globalPosition);
    final selected = await showMenu<String>(
      context: context,
      color: const Color(0xfffffbfc),
      elevation: 6,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Color(0xfffde8ed)),
      ),
      position: RelativeRect.fromSize(
        Rect.fromLTWH(position.dx, position.dy, 0, 0),
        overlay.size,
      ),
      items: [
        if (todo.completedAt == null)
          const PopupMenuItem(
            value: 'edit',
            height: 34,
            child: Text(
              '编辑',
              style: TextStyle(
                fontFamily: 'Microsoft YaHei',
                fontSize: 12,
                color: Color(0xff4a4a4a),
              ),
            ),
          ),
        const PopupMenuItem(
          value: 'delete',
          height: 34,
          child: Text(
            '删除',
            style: TextStyle(
              fontFamily: 'Microsoft YaHei',
              fontSize: 12,
              color: Color(0xffff6f8e),
            ),
          ),
        ),
      ],
    );
    if (!mounted) return;
    if (selected == 'edit') await _editBubbleTodo(todo);
    if (selected == 'delete') await _deleteBubbleTodo(todo);
  }

  Future<void> _editBubbleTodo(TodoEntry todo) async {
    final controller = TextEditingController(text: todo.title);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xfffffbfc),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0xfffde8ed)),
        ),
        title: const Text(
          '编辑 Todo',
          style: TextStyle(fontFamily: 'Microsoft YaHei', fontSize: 15),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (value) => Navigator.of(context).pop(value),
          style: const TextStyle(fontFamily: 'Microsoft YaHei', fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    final title = value?.trim();
    if (title == null || title.isEmpty) return;
    final current = await _PanelDataStore.load();
    final todos = List<TodoEntry>.of(current.todos);
    final index = todos.indexWhere((item) => item.id == todo.id);
    if (index < 0) return;
    todos[index] = todos[index].copyWith(title: title);
    await _saveBubbleTodos(current, todos);
  }

  Future<void> _renameBubbleTodo(TodoEntry todo, String title) async {
    final value = title.trim();
    if (value.isEmpty) return;
    final current = await _PanelDataStore.load();
    final todos = List<TodoEntry>.of(current.todos);
    final index = todos.indexWhere((item) => item.id == todo.id);
    if (index < 0) return;
    todos[index] = todos[index].copyWith(title: value);
    await _saveBubbleTodos(current, todos);
  }

  void _handleBubbleEditFocus(bool active) {
    if (!mounted) return;
    _bubbleEditInputActive = active;
    if (active) {
      if (!_windowDragging && _animation != _PetAnimation.busy) {
        _playAnimation(_PetAnimation.busy);
      }
    } else if (!_bubbleInputActive && !_systemCaretActive && !_windowDragging) {
      _playAnimation(_PetAnimation.busyEnd);
    }
  }

  Future<void> _deleteBubbleTodo(TodoEntry todo) async {
    final current = await _PanelDataStore.load();
    if (!current.skipTodoDeleteConfirmation) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xfffffbfc),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0xfffde8ed)),
          ),
          title: const Text('删除 Todo'),
          content: Text('确定要删除“${todo.title}”吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('删除'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    final latest = await _PanelDataStore.load();
    final todos = List<TodoEntry>.of(latest.todos)
      ..removeWhere((item) => item.id == todo.id);
    await _saveBubbleTodos(latest, todos);
  }

  void _initializeCaretMonitoring() {
    if (!Platform.isWindows) return;
    _systemChannel.setMethodCallHandler(_handleSystemEvent);
  }

  Future<void> _initializeTodoWatcher() async {
    if (_isFlutterTest) return;
    final file = _PanelDataStore._file;
    await file.parent.create(recursive: true);
    _todoFileWatcher = file.parent.watch().listen((event) {
      if (!event.path.toLowerCase().endsWith('control_panel.json')) return;
      _todoRefreshDebounce?.cancel();
      _todoRefreshDebounce = Timer(
        const Duration(milliseconds: 100),
        _refreshTodos,
      );
    });
  }

  Future<void> _handleSystemEvent(MethodCall call) async {
    switch (call.method) {
      case 'caretStateChanged':
        _handleCaretState(call.arguments == true);
      case 'keyboardActivity':
        _handleKeyboardActivity();
      case 'petEvent':
        final event = call.arguments;
        if (event is String) _handlePetEvent(event);
    }
  }

  void _handleBubbleInputFocus() {
    if (!mounted) return;
    final active = _bubbleTodoFocusNode.hasFocus;
    if (active == _bubbleInputActive) return;
    _bubbleInputActive = active;
    if (active) {
      if (!_windowDragging && _animation != _PetAnimation.busy) {
        _playAnimation(_PetAnimation.busy);
      }
    } else if (!_systemCaretActive && !_windowDragging) {
      _playAnimation(_PetAnimation.busyEnd);
    }
  }

  void _handleCaretState(bool active) {
    if (!mounted) return;
    if (!active) {
      _caretIdleTimer?.cancel();
      _caretIdleTimer = null;
      if (!_systemCaretActive) return;
      _systemCaretActive = false;
      final wasIdleSuppressed = _caretIdleSuppressed;
      _caretIdleSuppressed = false;
      if (!wasIdleSuppressed) _playAnimation(_PetAnimation.busyEnd);
      return;
    }
    _systemCaretActive = true;
    _caretIdleSuppressed = false;
    _resetCaretIdleTimer();
    if (!_windowDragging && _animation != _PetAnimation.busy) {
      _playAnimation(_PetAnimation.busy);
    }
  }

  void _handleKeyboardActivity() {
    if (!mounted || !_systemCaretActive) return;
    _caretIdleSuppressed = false;
    _resetCaretIdleTimer();
    if (!_windowDragging && _animation != _PetAnimation.busy) {
      _playAnimation(_PetAnimation.busy);
    }
  }

  void _resetCaretIdleTimer() {
    _caretIdleTimer?.cancel();
    _caretIdleTimer = Timer(_caretIdleLimit, () {
      if (!mounted || !_systemCaretActive || _windowDragging) return;
      _caretIdleSuppressed = true;
      _playAnimation(_PetAnimation.busyEnd);
    });
  }

  void _scheduleRandomNormalEnd() {
    _randomNormalTimer?.cancel();
    final delay = Duration(seconds: 20 + _random.nextInt(21));
    _randomNormalTimer = Timer(delay, () {
      if (!mounted) return;
      if (_animation == _PetAnimation.normal) {
        _playAnimation(_PetAnimation.normalEnd);
      } else {
        _scheduleRandomNormalEnd();
      }
    });
  }

  void _handlePetEvent(String event) {
    if (!mounted) return;
    if (event == 'panelClosed') {
      _panelProcess = null;
      return;
    }
    final next = switch (event) {
      'inputFocus' => _PetAnimation.busy,
      'inputEnd' => _PetAnimation.busyEnd,
      'todoDone' => _PetAnimation.todoDone,
      _ => null,
    };
    if (next != null && next != _animation) {
      _playAnimation(next);
    }
  }

  void _playAnimation(_PetAnimation animation) {
    _randomNormalTimer?.cancel();
    _animationCompletionTimer?.cancel();
    setState(() {
      _animation = animation;
      _animationRevision++;
    });
    if (animation != _PetAnimation.normal &&
        animation != _PetAnimation.busy &&
        !_windowDragging) {
      final duration = _animationDurations[_animationAsset];
      if (duration != null) {
        _animationCompletionTimer = Timer(
          duration + const Duration(milliseconds: 100),
          () => _onAnimationCompleted('fallback-timer-fired'),
        );
      }
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_bubbleVisible && event.position.dy < _bubbleInteractionHeight) return;
    if (event.buttons != kPrimaryMouseButton) return;
    _pointerDownPosition = event.position;
    _pointerDragging = false;
    _longPressTriggered = false;
    _longPressTimer?.cancel();
    _longPressTimer = Timer(const Duration(milliseconds: 250), () {
      if (!mounted || _pointerDownPosition == null || _pointerDragging) return;
      _longPressTriggered = true;
      _playAnimation(_PetAnimation.longPress);
    });
  }

  void _onPointerMove(PointerMoveEvent event) {
    final origin = _pointerDownPosition;
    if (origin == null || _pointerDragging) return;
    if ((event.position - origin).distance < 10) return;
    _pointerDragging = true;
    _longPressTimer?.cancel();
    _startWindowDrag();
  }

  Future<void> _startWindowDrag() async {
    _windowDragging = true;
    if (_animation != _PetAnimation.longPress) {
      _playAnimation(_PetAnimation.longPress);
    } else {
      setState(() {});
    }
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !_windowDragging) return;
    try {
      await windowManager.startDragging();
      _finishWindowDrag('native-startDragging-returned');
    } on MissingPluginException {
      // Widget tests do not load the native window manager plugin.
    } catch (_) {
      // A position write failure must not block hiding or exiting the pet.
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    _longPressTimer?.cancel();
    if (_pointerDownPosition != null &&
        !_pointerDragging &&
        !_longPressTriggered) {
      _playAnimation(_PetAnimation.tap);
      setState(() => _bubbleVisible = !_bubbleVisible);
    }
    _resetPointerGesture();
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _longPressTimer?.cancel();
    _resetPointerGesture();
  }

  void _resetPointerGesture() {
    _pointerDownPosition = null;
    _pointerDragging = false;
    _longPressTriggered = false;
  }

  @override
  void onWindowMoved() {
    _finishWindowDrag('onWindowMoved');
    _positionSaveDebounce?.cancel();
    _positionSaveDebounce = Timer(
      const Duration(milliseconds: 250),
      _saveWindowPosition,
    );
  }

  Future<void> _saveWindowPosition() async {
    if (_isFlutterTest || !_petVisible) return;
    try {
      final position = await windowManager.getPosition();
      await _PetWindowPositionStore.save(position);
    } on MissingPluginException {
      // Widget tests do not load the native window manager plugin.
    }
  }

  void _finishWindowDrag(String source) {
    if (!_windowDragging || !mounted) {
      return;
    }
    _windowDragging = false;
    _playAnimation(_PetAnimation.normal);
    _scheduleRandomNormalEnd();
  }

  void _onAnimationCompleted(String source) {
    if (!mounted) return;
    if (_animation == _PetAnimation.normal || _windowDragging) {
      return;
    }
    _animationCompletionTimer?.cancel();
    _animationCompletionTimer = null;
    if ((_systemCaretActive && !_caretIdleSuppressed) ||
        _bubbleInputActive ||
        _bubbleEditInputActive) {
      _playAnimation(_PetAnimation.busy);
      return;
    }
    _playAnimation(_PetAnimation.normal);
    _scheduleRandomNormalEnd();
  }

  Process? _panelProcess;

  Future<void> _openPanelWindow() async {
    if (Platform.isWindows) {
      final existing = await _systemChannel.invokeMethod<bool>(
        'showExistingControlPanel',
      );
      if (existing == true) return;
    }
    final process = await Process.start(Platform.resolvedExecutable, [
      '--control-panel',
    ], mode: ProcessStartMode.detachedWithStdio);
    _panelProcess = process;
    process.exitCode.then((_) {
      if (identical(_panelProcess, process)) _panelProcess = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final assetSize = _assetSize;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapDown: (details) {
          if (!_bubbleVisible ||
              details.localPosition.dy >= _bubbleInteractionHeight) {
            trayManager.popUpContextMenu();
          }
        },
        child: Listener(
          key: const ValueKey('pet-pointer-listener'),
          behavior: HitTestBehavior.opaque,
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerCancel,
          child: SizedBox.expand(
            child: Stack(
              alignment: Alignment.bottomCenter,
              children: [
                if (_bubbleVisible)
                  Positioned(
                    top: 0,
                    left: (_petStageWidth - 300) / 2,
                    child: _TodoSpeechBubble(
                      todos: _todos,
                      controller: _bubbleTodoController,
                      focusNode: _bubbleTodoFocusNode,
                      onAdd: _addBubbleTodo,
                      onBlankTap: _addBubbleTodo,
                      onClose: () {
                        _bubbleTodoFocusNode.unfocus();
                        setState(() => _bubbleVisible = false);
                      },
                      onToggle: _toggleBubbleTodo,
                      onMenu: _showBubbleTodoMenu,
                      onEdit: _renameBubbleTodo,
                      onEditFocusChanged: _handleBubbleEditFocus,
                    ),
                  ),
                Transform.translate(
                  key: const ValueKey('pet-animation-position'),
                  offset: Offset.zero,
                  child: SizedBox(
                    width: _petStageWidth,
                    height: _petStageHeight,
                    child: AnimatedGif(
                      asset: _animationAsset,
                      revision: _animationRevision,
                      width: assetSize.width,
                      height: assetSize.height,
                      offset: _assetOffset,
                      loop:
                          _animation == _PetAnimation.normal ||
                          _animation == _PetAnimation.busy ||
                          _windowDragging,
                      onCompleted: () =>
                          _onAnimationCompleted('player-completed'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ignore: unused_element
class _LegacyTodoSpeechBubble extends StatelessWidget {
  const _LegacyTodoSpeechBubble({required this.todos});

  final List<TodoEntry> todos;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 300,
    height: 220,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xb3ffffff),
            border: Border.all(color: const Color(0xfffde8ed)),
            borderRadius: BorderRadius.circular(16),
            boxShadow: const [
              BoxShadow(
                color: Color(0x29ffb6c1),
                offset: Offset(0, 4),
                blurRadius: 16,
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 18,
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '待办清单 ✨',
                        style: TextStyle(
                          fontFamily: 'Microsoft YaHei',
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Color(0xff4a4a4a),
                        ),
                      ),
                    ),
                    Container(
                      width: 18,
                      height: 18,
                      decoration: const BoxDecoration(
                        color: Color(0xfffff0f3),
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.close,
                        size: 9,
                        color: Color(0xffff8fa4),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 102,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [
                    for (final todo in todos.take(4)) ...[
                      _LegacyTodoBubbleRow(todo: todo),
                      if (todo != todos.take(4).last)
                        const SizedBox(height: 10),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 32,
                child: Row(
                  children: [
                    Expanded(
                      child: Container(
                        height: 32,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        alignment: Alignment.centerLeft,
                        decoration: BoxDecoration(
                          color: const Color(0xfffff0f3),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text(
                          '添加新任务...',
                          style: TextStyle(
                            fontFamily: 'Microsoft YaHei',
                            fontSize: 11,
                            color: Color(0xff9ca3af),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: const Color(0xffffb6c1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.add,
                        size: 15,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Positioned(
          left: 142,
          bottom: -10,
          child: CustomPaint(
            size: const Size(8, 10),
            painter: _BubbleTailPainter(),
          ),
        ),
      ],
    ),
  );
}

class _LegacyTodoBubbleRow extends StatelessWidget {
  const _LegacyTodoBubbleRow({required this.todo});

  final TodoEntry todo;

  @override
  Widget build(BuildContext context) {
    final completed = todo.completedAt != null;
    return SizedBox(
      height: 18,
      child: Row(
        children: [
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: completed ? const Color(0xffffb6c1) : Colors.white,
              border: completed
                  ? null
                  : Border.all(color: const Color(0xffffb6c1), width: 1.5),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: completed
                ? const Icon(Icons.check, size: 10, color: Colors.white)
                : null,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              todo.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Microsoft YaHei',
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: completed
                    ? const Color(0xff9ca3af)
                    : const Color(0xff4a4a4a),
                decoration: completed ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TodoSpeechBubble extends StatefulWidget {
  const _TodoSpeechBubble({
    required this.todos,
    required this.controller,
    required this.focusNode,
    required this.onAdd,
    required this.onBlankTap,
    required this.onClose,
    required this.onToggle,
    required this.onMenu,
    required this.onEdit,
    required this.onEditFocusChanged,
  });

  final List<TodoEntry> todos;
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onAdd;
  final VoidCallback onBlankTap;
  final VoidCallback onClose;
  final ValueChanged<TodoEntry> onToggle;
  final void Function(TodoEntry, Offset) onMenu;
  final Future<void> Function(TodoEntry, String) onEdit;
  final ValueChanged<bool> onEditFocusChanged;

  @override
  State<_TodoSpeechBubble> createState() => _TodoSpeechBubbleState();
}

class _TodoSpeechBubbleState extends State<_TodoSpeechBubble> {
  final _editController = TextEditingController();
  final _editFocusNode = FocusNode();
  int? _editingTodoId;

  List<TodoEntry> get todos => widget.todos;
  TextEditingController get controller => widget.controller;
  FocusNode get focusNode => widget.focusNode;
  VoidCallback get onAdd => widget.onAdd;
  VoidCallback get onBlankTap => widget.onBlankTap;
  VoidCallback get onClose => widget.onClose;
  ValueChanged<TodoEntry> get onToggle => widget.onToggle;
  void Function(TodoEntry, Offset) get onMenu => widget.onMenu;

  @override
  void initState() {
    super.initState();
    _editFocusNode.addListener(_handleEditFocus);
  }

  @override
  void didUpdateWidget(covariant _TodoSpeechBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_editingTodoId != null &&
        !widget.todos.any((todo) => todo.id == _editingTodoId)) {
      _cancelEditing();
    }
  }

  @override
  void dispose() {
    final id = _editingTodoId;
    if (id != null) {
      final title = _editController.text.trim();
      for (final todo in todos) {
        if (todo.id == id && title.isNotEmpty && title != todo.title) {
          unawaited(widget.onEdit(todo, title));
          break;
        }
      }
    }
    if (_editFocusNode.hasFocus) widget.onEditFocusChanged(false);
    _editFocusNode.removeListener(_handleEditFocus);
    _editController.dispose();
    _editFocusNode.dispose();
    super.dispose();
  }

  void _handleEditFocus() => widget.onEditFocusChanged(_editFocusNode.hasFocus);

  Future<void> _startEditing(TodoEntry todo) async {
    if (todo.completedAt != null || _editingTodoId == todo.id) return;
    if (_editingTodoId != null) await _finishEditing();
    _editController.text = todo.title;
    setState(() => _editingTodoId = todo.id);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || _editingTodoId != todo.id) return;
    _editFocusNode.requestFocus();
    _editController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _editController.text.length,
    );
  }

  Future<void> _finishEditing() async {
    final id = _editingTodoId;
    if (id == null) return;
    TodoEntry? todo;
    for (final item in todos) {
      if (item.id == id) {
        todo = item;
        break;
      }
    }
    final title = _editController.text.trim();
    setState(() => _editingTodoId = null);
    _editFocusNode.unfocus();
    if (todo != null && title.isNotEmpty && title != todo.title) {
      await widget.onEdit(todo, title);
    }
  }

  void _cancelEditing() {
    if (_editingTodoId == null) return;
    setState(() => _editingTodoId = null);
    _editFocusNode.unfocus();
  }

  Future<void> _closeBubble() async {
    await _finishEditing();
    if (mounted) onClose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerUp: (event) {
        final p = event.localPosition;
        final inHeaderClose = p.dx >= 250 && p.dy <= 42;
        final inTodoArea = p.dy >= 48 && p.dy <= 170;
        final inInputArea = p.dy >= 176 && p.dy <= 220;
        if (!inHeaderClose && !inTodoArea && !inInputArea) onBlankTap();
      },
      child: SizedBox(
        width: 300,
        height: 220,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xb3ffffff),
                border: Border.all(color: const Color(0xfffde8ed)),
                borderRadius: BorderRadius.circular(16),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x29ffb6c1),
                    offset: Offset(0, 4),
                    blurRadius: 16,
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: 18,
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '本日待办✨️',
                            style: TextStyle(
                              fontFamily: 'Microsoft YaHei',
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: Color(0xff4a4a4a),
                            ),
                          ),
                        ),
                        Listener(
                          onPointerUp: (_) => unawaited(_closeBubble()),
                          child: Container(
                            width: 18,
                            height: 18,
                            decoration: const BoxDecoration(
                              color: Color(0xfffff0f3),
                              shape: BoxShape.circle,
                            ),
                            alignment: Alignment.center,
                            child: const Icon(
                              Icons.close,
                              size: 9,
                              color: Color(0xffff8fa4),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 102,
                    child: ScrollConfiguration(
                      behavior: ScrollConfiguration.of(
                        context,
                      ).copyWith(scrollbars: false),
                      child: ListView.separated(
                        padding: EdgeInsets.zero,
                        itemCount: todos.length,
                        itemBuilder: (context, index) {
                          final todo = todos[index];
                          return _TodoBubbleRow(
                            todo: todo,
                            editing: _editingTodoId == todo.id,
                            editController: _editController,
                            editFocusNode: _editFocusNode,
                            onEditTap: () => _startEditing(todo),
                            onEditSubmitted: _finishEditing,
                            onEditTapOutside: (_) => _finishEditing(),
                            onBlankTap: onBlankTap,
                            onToggle: () => onToggle(todo),
                            onMenu: (position) => onMenu(todo, position),
                          );
                        },
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 32,
                    child: Row(
                      children: [
                        Expanded(
                          child: Container(
                            height: 32,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            alignment: Alignment.centerLeft,
                            decoration: BoxDecoration(
                              color: const Color(0xfffff0f3),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: TextField(
                              controller: controller,
                              focusNode: focusNode,
                              onSubmitted: (_) => onAdd(),
                              textInputAction: TextInputAction.done,
                              style: const TextStyle(
                                fontFamily: 'Microsoft YaHei',
                                fontSize: 11,
                                color: Color(0xff4a4a4a),
                              ),
                              decoration: const InputDecoration(
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Listener(
                          onPointerUp: (_) => onAdd(),
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: const Color(0xffffb6c1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            alignment: Alignment.center,
                            child: const Icon(
                              Icons.add,
                              size: 15,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              left: 142,
              bottom: -10,
              child: CustomPaint(
                size: const Size(8, 10),
                painter: _BubbleTailPainter(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TodoBubbleRow extends StatelessWidget {
  const _TodoBubbleRow({
    required this.todo,
    required this.editing,
    required this.editController,
    required this.editFocusNode,
    required this.onEditTap,
    required this.onEditSubmitted,
    required this.onEditTapOutside,
    required this.onBlankTap,
    required this.onToggle,
    required this.onMenu,
  });

  final TodoEntry todo;
  final bool editing;
  final TextEditingController editController;
  final FocusNode editFocusNode;
  final VoidCallback onEditTap;
  final VoidCallback onEditSubmitted;
  final TapRegionCallback onEditTapOutside;
  final VoidCallback onBlankTap;
  final VoidCallback onToggle;
  final ValueChanged<Offset> onMenu;

  @override
  Widget build(BuildContext context) {
    final completed = todo.completedAt != null;
    return Listener(
      onPointerDown: (event) {
        if (event.buttons == kSecondaryMouseButton) {
          onMenu(event.position);
        }
      },
      child: SizedBox(
        height: 18,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final textStyle = TextStyle(
              fontFamily: 'Microsoft YaHei',
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: completed
                  ? const Color(0xff9ca3af)
                  : const Color(0xff4a4a4a),
              decoration: completed ? TextDecoration.lineThrough : null,
            );
            final painter = TextPainter(
              text: TextSpan(text: todo.title, style: textStyle),
              maxLines: 1,
              textDirection: Directionality.of(context),
            )..layout(maxWidth: constraints.maxWidth - 26);
            final textHitWidth = min(constraints.maxWidth, 26 + painter.width);
            return Listener(
              onPointerUp: (event) {
                if (event.localPosition.dx > textHitWidth) onBlankTap();
              },
              child: Row(
                children: [
                  Listener(
                    onPointerDown: (event) {
                      if (event.buttons == kPrimaryMouseButton) onToggle();
                    },
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: completed
                            ? const Color(0xffffb6c1)
                            : Colors.white,
                        border: completed
                            ? null
                            : Border.all(
                                color: const Color(0xffffb6c1),
                                width: 1.5,
                              ),
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: completed
                          ? const Icon(
                              Icons.check,
                              size: 10,
                              color: Colors.white,
                            )
                          : null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: editing
                        ? TextField(
                            key: ValueKey('bubble-edit-todo-${todo.id}'),
                            controller: editController,
                            focusNode: editFocusNode,
                            onSubmitted: (_) => onEditSubmitted(),
                            onTapOutside: onEditTapOutside,
                            textInputAction: TextInputAction.done,
                            style: const TextStyle(
                              fontFamily: 'Microsoft YaHei',
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: Color(0xff4a4a4a),
                            ),
                            decoration: const InputDecoration(
                              border: InputBorder.none,
                              isDense: true,
                              contentPadding: EdgeInsets.zero,
                            ),
                          )
                        : Listener(
                            behavior: HitTestBehavior.opaque,
                            onPointerDown: (event) {
                              if (event.buttons == kPrimaryMouseButton) {
                                onEditTap();
                              }
                            },
                            child: Text(
                              todo.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textStyle,
                            ),
                          ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _BubbleTailPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = const Color(0xb3ffffff));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class AnimatedGif extends StatefulWidget {
  const AnimatedGif({
    required this.asset,
    required this.revision,
    required this.width,
    required this.height,
    required this.offset,
    required this.loop,
    required this.onCompleted,
    super.key,
  });

  final String asset;
  final int revision;
  final double width;
  final double height;
  final Offset offset;
  final bool loop;
  final VoidCallback onCompleted;

  @override
  State<AnimatedGif> createState() => _AnimatedGifState();
}

class _AnimatedGifState extends State<AnimatedGif> {
  ui.Codec? _codec;
  ui.Image? _image;
  Timer? _timer;
  int _frame = 0;
  int _frameCount = 0;
  int _generation = 0;
  late Size _displaySize;
  late Offset _displayOffset;

  @override
  void initState() {
    super.initState();
    _displaySize = Size(widget.width, widget.height);
    _displayOffset = widget.offset;
    _load();
  }

  @override
  void didUpdateWidget(covariant AnimatedGif oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset != widget.asset ||
        oldWidget.revision != widget.revision) {
      _generation++;
      _timer?.cancel();
      _codec?.dispose();
      _codec = null;
      _frame = 0;
      _load();
    }
  }

  Future<void> _load() async {
    final generation = _generation;
    final data = await rootBundle.load(widget.asset);
    final codec = await ui.instantiateImageCodec(Uint8List.sublistView(data));
    if (!mounted || generation != _generation) {
      codec.dispose();
      return;
    }
    _codec = codec;
    _frameCount = codec.frameCount;
    await _showNextFrame(generation);
  }

  Future<void> _showNextFrame(int generation) async {
    final codec = _codec;
    if (codec == null || !mounted || generation != _generation) return;
    if (!widget.loop && _frame >= _frameCount) {
      widget.onCompleted();
      return;
    }
    final frame = await codec.getNextFrame();
    if (!mounted || generation != _generation) {
      frame.image.dispose();
      return;
    }
    final oldImage = _image;
    setState(() {
      _image = frame.image;
      if (_frame == 0) {
        _displaySize = Size(widget.width, widget.height);
        _displayOffset = widget.offset;
      }
    });
    if (oldImage != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => oldImage.dispose());
    }
    _frame++;
    _timer = Timer(frame.duration, () => _showNextFrame(generation));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _image?.dispose();
    _codec?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.expand(
    child: Stack(
      children: [
        if (_image != null)
          Positioned(
            left: (_petStageWidth - _displaySize.width) / 2 + _displayOffset.dx,
            top: _petStageHeight - _displaySize.height + _displayOffset.dy,
            width: _displaySize.width,
            height: _displaySize.height,
            child: RawImage(
              image: _image,
              width: _displaySize.width,
              height: _displaySize.height,
              fit: BoxFit.none,
              filterQuality: FilterQuality.none,
            ),
          ),
      ],
    ),
  );
}
