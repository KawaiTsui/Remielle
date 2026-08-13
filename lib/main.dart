import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

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

  const options = WindowOptions(
    size: Size(303, 298),
    minimumSize: Size(303, 298),
    maximumSize: Size(303, 298),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: true,
    titleBarStyle: TitleBarStyle.hidden,
    alwaysOnTop: true,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.setAsFrameless();
    await windowManager.setBackgroundColor(Colors.transparent);
    await windowManager.setResizable(false);
    await windowManager.show();
    await windowManager.focus();
  });
  runApp(const RemielleApp());
}

class RemielleApp extends StatelessWidget {
  const RemielleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Remielle',
    theme: _theme(),
    home: const PetHome(),
  );
}

ThemeData _theme() => ThemeData(
  colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xffe986a9)),
  useMaterial3: true,
);

enum PetMode { normal, idle, inactive }

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

File get _petEventFile {
  final localAppData = Platform.environment['LOCALAPPDATA'];
  final base = localAppData == null || localAppData.isEmpty
      ? Directory.systemTemp.path
      : localAppData;
  return File('$base\\Remielle\\pet_events.log');
}

Future<void> _sendPetEvent(String event) async {
  if (Platform.environment.containsKey('FLUTTER_TEST')) return;
  final file = _petEventFile;
  await file.parent.create(recursive: true);
  await file.writeAsString(
    '${DateTime.now().microsecondsSinceEpoch}:$event\n',
    mode: FileMode.append,
    flush: true,
  );
}

class PetHome extends StatefulWidget {
  const PetHome({super.key});

  @override
  State<PetHome> createState() => _PetHomeState();
}

class _PetHomeState extends State<PetHome> with WindowListener, TrayListener {
  _PetAnimation _animation = _PetAnimation.normal;
  bool _mouseThrough = false;
  bool _alwaysOnTop = true;
  Timer? _randomNormalTimer;
  Timer? _eventPoller;
  Timer? _longPressTimer;
  Timer? _animationCompletionTimer;
  int _consumedEventCount = 0;
  int _animationRevision = 0;
  final _random = Random();
  Offset? _pointerDownPosition;
  bool _pointerDragging = false;
  bool _longPressTriggered = false;
  bool _windowDragging = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    trayManager.addListener(this);
    _initialize();
    _initializeEvents();
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
        MenuItem.checkbox(
          key: 'through',
          label: '鼠标穿透',
          checked: _mouseThrough,
        ),
        MenuItem.checkbox(key: 'top', label: '置顶', checked: _alwaysOnTop),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: '退出'),
      ],
    ),
  );

  @override
  void dispose() {
    _randomNormalTimer?.cancel();
    _eventPoller?.cancel();
    _longPressTimer?.cancel();
    _animationCompletionTimer?.cancel();
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
      case 'exit':
        _exitApp();
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

  Future<void> _exitApp() async {
    _panelProcess?.kill();
    await trayManager.destroy();
    exit(0);
  }

  @override
  Future<void> onWindowClose() => windowManager.hide();

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

  Future<void> _initializeEvents() async {
    final file = _petEventFile;
    if (await file.exists()) {
      _consumedEventCount = (await file.readAsLines()).length;
    }
    _eventPoller = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => _readPetEvents(),
    );
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

  Future<void> _readPetEvents() async {
    final file = _petEventFile;
    if (!await file.exists()) return;
    final lines = await file.readAsLines();
    if (_consumedEventCount > lines.length) _consumedEventCount = 0;
    for (final line in lines.skip(_consumedEventCount)) {
      final separator = line.indexOf(':');
      if (separator >= 0) _handlePetEvent(line.substring(separator + 1));
    }
    _consumedEventCount = lines.length;
  }

  void _handlePetEvent(String event) {
    if (!mounted) return;
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
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    _longPressTimer?.cancel();
    if (_pointerDownPosition != null &&
        !_pointerDragging &&
        !_longPressTriggered) {
      _playAnimation(_PetAnimation.tap);
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
    _playAnimation(_PetAnimation.normal);
    _scheduleRandomNormalEnd();
  }

  Process? _panelProcess;

  Future<void> _openPanelWindow() async {
    if (_panelProcess != null) return;
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
        onSecondaryTap: trayManager.popUpContextMenu,
        child: Listener(
          key: const ValueKey('pet-pointer-listener'),
          behavior: HitTestBehavior.opaque,
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerCancel,
          child: Center(
            child: SizedBox.fromSize(
              size: assetSize,
              child: AnimatedGif(
                asset: _animationAsset,
                revision: _animationRevision,
                width: assetSize.width,
                height: assetSize.height,
                loop:
                    _animation == _PetAnimation.normal ||
                    _animation == _PetAnimation.busy ||
                    _windowDragging,
                onCompleted: () => _onAnimationCompleted('player-completed'),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AnimatedGif extends StatefulWidget {
  const AnimatedGif({
    required this.asset,
    required this.revision,
    required this.width,
    required this.height,
    required this.loop,
    required this.onCompleted,
    super.key,
  });

  final String asset;
  final int revision;
  final double width;
  final double height;
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

  @override
  void initState() {
    super.initState();
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
    setState(() => _image = frame.image);
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
  Widget build(BuildContext context) => SizedBox(
    width: widget.width,
    height: widget.height,
    child: _image == null
        ? const SizedBox.shrink()
        : RawImage(
            image: _image,
            width: widget.width,
            height: widget.height,
            fit: BoxFit.none,
            filterQuality: FilterQuality.none,
          ),
  );
}

class ControlPanelApp extends StatelessWidget {
  const ControlPanelApp({super.key});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Remielle 控制面板',
      theme: _theme(),
      home: const ControlPanelPage(),
    ),
  );
}

class ControlPanelPage extends StatefulWidget {
  const ControlPanelPage({super.key});

  @override
  State<ControlPanelPage> createState() => _ControlPanelPageState();
}

class _ControlPanelPageState extends State<ControlPanelPage> {
  final _todoController = TextEditingController();
  final _todoFocusNode = FocusNode();
  final _todos = <TodoEntry>[TodoEntry(id: 1, title: '整理 Remielle 动画素材')];
  int _nextTodoId = 2;
  PetMode _mode = PetMode.normal;
  int _idleMinutes = 5;
  bool _alwaysOnTop = true;
  bool _mouseThrough = false;
  bool _inputSessionActive = false;

  @override
  void initState() {
    super.initState();
    _todoFocusNode.addListener(_onTodoFocusChanged);
  }

  @override
  void dispose() {
    _todoFocusNode.removeListener(_onTodoFocusChanged);
    _todoFocusNode.dispose();
    _todoController.dispose();
    super.dispose();
  }

  void _onTodoFocusChanged() {
    if (_todoFocusNode.hasFocus) {
      _inputSessionActive = true;
      _sendPetEvent('inputFocus');
    }
  }

  void _endInputSession() {
    if (!_inputSessionActive) return;
    _inputSessionActive = false;
    _sendPetEvent('inputEnd');
  }

  void _addTodo() {
    final value = _todoController.text.trim();
    if (value.isEmpty) {
      _endInputSession();
      return;
    }
    setState(() {
      _todos.add(TodoEntry(id: _nextTodoId++, title: value));
      _todoController.clear();
    });
    _endInputSession();
    FocusManager.instance.primaryFocus?.unfocus();
  }

  Future<void> _completeTodo(TodoEntry todo) async {
    setState(() {
      _todos.removeWhere((item) => item.id == todo.id);
    });
    await _sendPetEvent('todoDone');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Remielle 控制面板')),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 980),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Todo', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _todoController,
                      focusNode: _todoFocusNode,
                      decoration: const InputDecoration(
                        hintText: '添加一个 Todo',
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _addTodo(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  IconButton.filled(
                    tooltip: '添加 Todo',
                    onPressed: _addTodo,
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: (_todos.length * 56.0).clamp(56.0, 280.0),
                child: ListView.builder(
                  itemCount: _todos.length,
                  itemBuilder: (context, index) {
                    final todo = _todos[index];
                    return CheckboxListTile(
                      key: ValueKey(todo.id),
                      value: false,
                      title: Text(todo.title),
                      onChanged: (_) => _completeTodo(todo),
                      secondary: IconButton(
                        tooltip: '设置提醒',
                        icon: const Icon(Icons.notifications_none),
                        onPressed: () {},
                      ),
                    );
                  },
                ),
              ),
              const Divider(height: 40),
              Text('宠物设置', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 16),
              DropdownButtonFormField<PetMode>(
                initialValue: _mode,
                decoration: const InputDecoration(
                  labelText: '预览状态',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: PetMode.normal, child: Text('常态')),
                  DropdownMenuItem(value: PetMode.idle, child: Text('待机')),
                  DropdownMenuItem(
                    value: PetMode.inactive,
                    child: Text('长时间无活动'),
                  ),
                ],
                onChanged: (value) => setState(() => _mode = value ?? _mode),
              ),
              const SizedBox(height: 18),
              Text('待机阈值：$_idleMinutes 分钟'),
              Slider(
                value: _idleMinutes.toDouble(),
                min: 1,
                max: 30,
                divisions: 29,
                label: '$_idleMinutes 分钟',
                onChanged: (value) =>
                    setState(() => _idleMinutes = value.round()),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('始终置顶'),
                value: _alwaysOnTop,
                onChanged: (value) {
                  setState(() => _alwaysOnTop = value);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('鼠标穿透'),
                subtitle: const Text('开启后可从任务栏托盘菜单关闭穿透'),
                value: _mouseThrough,
                onChanged: (value) {
                  setState(() => _mouseThrough = value);
                },
              ),
              const SizedBox(height: 20),
              FilledButton.tonalIcon(
                onPressed: () => exit(0),
                icon: const Icon(Icons.exit_to_app),
                label: const Text('关闭控制面板'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class TodoEntry {
  const TodoEntry({required this.id, required this.title});

  final int id;
  final String title;
}
