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
  'assets/animations/d.gif': Offset(-14, 0),
  'assets/animations/d_win.gif': Offset(-21, -7),
};

const _systemChannel = MethodChannel('remielle/system');
const _caretIdleLimit = Duration(seconds: 30);

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
  Timer? _caretPoller;
  Timer? _longPressTimer;
  Timer? _animationCompletionTimer;
  int _consumedEventCount = 0;
  int _animationRevision = 0;
  final _random = Random();
  Offset? _pointerDownPosition;
  bool _pointerDragging = false;
  bool _longPressTriggered = false;
  bool _windowDragging = false;
  bool _petVisible = true;
  bool _systemCaretActive = false;
  bool _caretIdleSuppressed = false;
  bool _checkingSystemCaret = false;
  int _keyboardIdleBaselineMilliseconds = 0;
  int _lastKeyboardIdleMilliseconds = 0;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    trayManager.addListener(this);
    _initialize();
    _initializeEvents();
    _initializeCaretMonitoring();
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
    _eventPoller?.cancel();
    _caretPoller?.cancel();
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

  void _initializeCaretMonitoring() {
    if (!Platform.isWindows) return;
    _checkSystemCaret();
    _caretPoller = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => _checkSystemCaret(),
    );
  }

  Future<void> _checkSystemCaret() async {
    if (_checkingSystemCaret || !mounted) return;
    _checkingSystemCaret = true;
    try {
      final active =
          await _systemChannel.invokeMethod<bool>('isTextCaretActive') ?? false;
      final keyboardIdleMilliseconds = active
          ? await _systemChannel.invokeMethod<int>(
                  'getKeyboardInputIdleMilliseconds',
                ) ??
                0
          : 0;
      if (!mounted) return;
      if (active) {
        if (!_systemCaretActive) {
          _keyboardIdleBaselineMilliseconds = keyboardIdleMilliseconds;
        } else if (keyboardIdleMilliseconds < _lastKeyboardIdleMilliseconds) {
          _keyboardIdleBaselineMilliseconds = 0;
        }
        _lastKeyboardIdleMilliseconds = keyboardIdleMilliseconds;
        _systemCaretActive = true;
        final idleMilliseconds = max(
          0,
          keyboardIdleMilliseconds - _keyboardIdleBaselineMilliseconds,
        );
        if (idleMilliseconds >= _caretIdleLimit.inMilliseconds) {
          if (!_caretIdleSuppressed && !_windowDragging) {
            _caretIdleSuppressed = true;
            _playAnimation(_PetAnimation.busyEnd);
          }
        } else {
          _caretIdleSuppressed = false;
        }
        if (!_caretIdleSuppressed &&
            _animation != _PetAnimation.busy &&
            !_windowDragging) {
          _playAnimation(_PetAnimation.busy);
        }
      } else if (_systemCaretActive) {
        _systemCaretActive = false;
        _keyboardIdleBaselineMilliseconds = 0;
        _lastKeyboardIdleMilliseconds = 0;
        final wasIdleSuppressed = _caretIdleSuppressed;
        _caretIdleSuppressed = false;
        if (!wasIdleSuppressed) _playAnimation(_PetAnimation.busyEnd);
      }
    } on MissingPluginException {
      // Widget tests do not load the native Windows runner channel.
    } on PlatformException {
      // A transient native query failure should not affect the desktop pet.
    } finally {
      _checkingSystemCaret = false;
    }
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
    if (_systemCaretActive && !_caretIdleSuppressed) {
      _playAnimation(_PetAnimation.busy);
      return;
    }
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
            child: Transform.translate(
              key: const ValueKey('pet-animation-position'),
              offset: _assetOffset,
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
