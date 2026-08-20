import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

part 'control_panel.dart';

const _petStageWidth = 341.0;
const _petStageHeight = 298.0;
const _petBubbleGap = 20.0;
const _petBubbleWidth = 300.0;
const _petBubbleMinHeight = 270.0;
const _petBubbleTailHeight = 10.0;
const _minPetScale = 0.5;
const _maxPetScale = 2.0;
const _petScalePerDragPixel = 0.005;
const _remielleVersion = '1.0.2';
const _githubRepository = 'KawaiTsui/Remielle';

enum _UpdateStatus { idle, available, downloading, failed }

class _UpdateInfo {
  const _UpdateInfo({required this.version, required this.downloadUrl});
  final String version;
  final String downloadUrl;
}

class _UpdateService {
  static File get _sameVersionMarker =>
      File('${Directory.systemTemp.path}\\remielle-same-version-update.marker');

  static Future<_UpdateInfo?> check() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(
        Uri.parse(
          'https://api.github.com/repos/$_githubRepository/releases/latest',
        ),
      );
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'Remielle/$_remielleVersion');
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      if (response.statusCode != HttpStatus.ok) {
        return null;
      }
      final data = jsonDecode(await response.transform(utf8.decoder).join());
      if (data is! Map<String, dynamic> || data['tag_name'] is! String) {
        return null;
      }
      final version = (data['tag_name'] as String).replaceFirst(
        RegExp('^v'),
        '',
      );
      final assets = data['assets'];
      if (assets is! List) {
        return null;
      }
      final asset = assets.whereType<Map<String, dynamic>>().firstWhere(
        (item) =>
            item['name'] is String &&
            (item['name'] as String).contains('windows-x64') &&
            (item['name'] as String).endsWith('.zip'),
        orElse: () => <String, dynamic>{},
      );
      final url = asset['browser_download_url'];
      if (url is! String || !_isNewer(version)) {
        return null;
      }
      if (_isSameVersion(version) && await _sameVersionMarker.exists()) {
        await _sameVersionMarker.delete();
        return null;
      }
      return _UpdateInfo(version: version, downloadUrl: url);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> markSameVersionUpdate() async {
    await _sameVersionMarker.writeAsString('completed');
  }

  static Future<File> download(
    _UpdateInfo info,
    ValueChanged<double> progress,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(Uri.parse(info.downloadUrl));
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Remielle/$_remielleVersion',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('download failed');
      }
      final file = File(
        '${Directory.systemTemp.path}\\remielle-${info.version}.zip',
      );
      try {
        final sink = file.openWrite();
        var received = 0;
        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          if (response.contentLength > 0) {
            progress(received / response.contentLength);
          }
        }
        await sink.close();
        progress(1);
        return file;
      } catch (_) {
        try {
          await file.delete();
        } catch (_) {}
        rethrow;
      }
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> launchUpdater(File archive) async {
    final script = File(
      '${Directory.systemTemp.path}\\remielle-updater-${DateTime.now().microsecondsSinceEpoch}.ps1',
    );
    await script.writeAsString(r'''
param([string]$Archive, [string]$Executable, [int]$ProcessId)
$ErrorActionPreference = 'Stop'
$log = Join-Path ([IO.Path]::GetTempPath()) 'remielle-updater.log'
function Write-UpdateLog([string]$Message) {
  Add-Content -LiteralPath $log -Value (('[' + (Get-Date -Format o) + '] ') + $Message)
}
Write-UpdateLog "Updater started. Archive=$Archive Executable=$Executable PID=$ProcessId"
while (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) { Start-Sleep -Milliseconds 250 }
Write-UpdateLog 'Main process exited.'
$root = Split-Path -Parent $Executable
$temp = Join-Path ([IO.Path]::GetTempPath()) ('remielle-update-' + [guid]::NewGuid())
$backup = $root + '.backup-' + [guid]::NewGuid()
try {
  New-Item -ItemType Directory -Force -Path $temp | Out-Null
  Expand-Archive -LiteralPath $Archive -DestinationPath $temp -Force
  $executableName = Split-Path -Leaf $Executable
  if (-not (Test-Path -LiteralPath (Join-Path $temp $executableName))) {
    throw 'The update archive does not contain the application executable.'
  }

  Get-Process | Where-Object {
    try { $_.Path -eq $Executable } catch { $false }
  } | Stop-Process -Force -ErrorAction SilentlyContinue
  Move-Item -LiteralPath $root -Destination $backup -Force
  Move-Item -LiteralPath $temp -Destination $root -Force
  Write-UpdateLog "Installed update into $root"
  Start-Process -FilePath $Executable -WorkingDirectory $root -WindowStyle Hidden
  Write-UpdateLog 'Restart requested.'
  Set-Content -LiteralPath (Join-Path ([IO.Path]::GetTempPath()) 'remielle-update-success.marker') -Value 'success'
  Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
} catch {
  Write-UpdateLog ('Update failed: ' + $_.Exception.Message)
  Set-Content -LiteralPath (Join-Path ([IO.Path]::GetTempPath()) 'remielle-update-failed.marker') -Value $_.Exception.Message
  if (Test-Path -LiteralPath $backup) {
    if (Test-Path -LiteralPath $root) {
      Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
    Move-Item -LiteralPath $backup -Destination $root -Force
    Start-Process -FilePath $Executable -WorkingDirectory $root -WindowStyle Hidden -ErrorAction SilentlyContinue
    Write-UpdateLog 'Rollback restart requested.'
  }
} finally {
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $Archive -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
}
''');
    await Process.start(
      'powershell.exe',
      [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        script.path,
        archive.path,
        Platform.resolvedExecutable,
        pid.toString(),
      ],
      mode: ProcessStartMode.detached,
      workingDirectory: Directory.systemTemp.path,
    );
  }

  static bool _isNewer(String remote) {
    List<int> parse(String value) => value
        .split('.')
        .map(
          (part) =>
              int.tryParse(part.replaceFirst(RegExp(r'[^0-9].*'), '')) ?? 0,
        )
        .toList();
    final a = parse(remote), b = parse(_remielleVersion);
    for (var i = 0; i < max(a.length, b.length); i++) {
      final av = i < a.length ? a[i] : 0, bv = i < b.length ? b[i] : 0;
      if (av != bv) return av > bv;
    }
    return true;
  }

  static bool _isSameVersion(String remote) {
    List<int> parse(String value) => value
        .split('.')
        .map(
          (part) =>
              int.tryParse(part.replaceFirst(RegExp(r'[^0-9].*'), '')) ?? 0,
        )
        .toList();
    final a = parse(remote), b = parse(_remielleVersion);
    for (var i = 0; i < max(a.length, b.length); i++) {
      final av = i < a.length ? a[i] : 0, bv = i < b.length ? b[i] : 0;
      if (av != bv) return false;
    }
    return true;
  }
}

int _compareBubbleTodos(TodoEntry a, TodoEntry b) {
  final completionOrder = (a.completedAt == null ? 0 : 1).compareTo(
    b.completedAt == null ? 0 : 1,
  );
  return completionOrder != 0
      ? completionOrder
      : a.createdAt.compareTo(b.createdAt);
}

class _BubbleScrollPhysics extends ClampingScrollPhysics {
  const _BubbleScrollPhysics({super.parent});

  @override
  _BubbleScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      _BubbleScrollPhysics(parent: buildParent(ancestor));

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    final scale = (position.viewportDimension / 340).clamp(0.3, 1.0);
    return super.applyPhysicsToUserOffset(position, offset * scale);
  }
}

double _petWindowHeightForLayout(double scale, double bubbleHeight) =>
    bubbleHeight +
    _petBubbleTailHeight +
    _petBubbleGap +
    _petStageHeight * scale;

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

  final savedLayout = await _PetWindowPositionStore.loadLayout();
  final savedPosition = savedLayout?.position;
  final savedScale = savedLayout?.scale ?? 1.0;
  final savedBubbleHeight = savedLayout?.bubbleHeight ?? _petBubbleMinHeight;
  final options = WindowOptions(
    size: Size(
      max(_petBubbleWidth, _petStageWidth * savedScale),
      _petWindowHeightForLayout(savedScale, savedBubbleHeight),
    ),
    minimumSize: Size(
      max(_petBubbleWidth, _petStageWidth * _minPetScale),
      _petWindowHeightForLayout(_minPetScale, _petBubbleMinHeight),
    ),
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
  runApp(
    RemielleApp(
      initialBubbleVisible: panelData.bubbleVisibleByDefault,
      initialPetScale: savedScale,
      initialBubbleHeight: savedBubbleHeight,
    ),
  );
}

class _PetWindowPositionStore {
  static File get _file {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    final base = localAppData == null || localAppData.isEmpty
        ? Directory.systemTemp.path
        : localAppData;
    return File('$base\\Remielle\\pet_window.json');
  }

  static Future<_PetWindowLayout?> loadLayout() async {
    try {
      if (!await _file.exists()) return null;
      final json = jsonDecode(await _file.readAsString());
      if (json is! Map<String, dynamic>) return null;
      final x = json['x'];
      final y = json['y'];
      if (x is! num || y is! num || !x.isFinite || !y.isFinite) return null;
      final scale = json['scale'];
      final bubbleHeight = json['bubbleHeight'];
      return _PetWindowLayout(
        position: Offset(x.toDouble(), y.toDouble()),
        scale: scale is num
            ? scale.toDouble().clamp(_minPetScale, _maxPetScale)
            : 1.0,
        bubbleHeight: bubbleHeight is num
            ? max(_petBubbleMinHeight, bubbleHeight.toDouble())
            : _petBubbleMinHeight,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(
    Offset position, {
    double scale = 1.0,
    double bubbleHeight = _petBubbleMinHeight,
  }) async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(
      jsonEncode({
        'x': position.dx,
        'y': position.dy,
        'scale': scale,
        'bubbleHeight': bubbleHeight,
      }),
      flush: true,
    );
  }
}

class _PetWindowLayout {
  const _PetWindowLayout({
    required this.position,
    required this.scale,
    required this.bubbleHeight,
  });

  final Offset position;
  final double scale;
  final double bubbleHeight;
}

class RemielleApp extends StatelessWidget {
  const RemielleApp({
    super.key,
    this.initialBubbleVisible = true,
    this.initialPetScale = 1.0,
    this.initialBubbleHeight = _petBubbleMinHeight,
  });

  final bool initialBubbleVisible;
  final double initialPetScale;
  final double initialBubbleHeight;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Remielle',
    theme: _theme(),
    home: PetHome(
      initialBubbleVisible: initialBubbleVisible,
      initialPetScale: initialPetScale,
      initialBubbleHeight: initialBubbleHeight,
    ),
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
const _caretHealthCheckInterval = Duration(seconds: 3);
const _localCaretLossConfirmDelay = Duration(milliseconds: 450);

// A stale native caret state must not keep the looping busy animation alive
// indefinitely. Keyboard/focus events still drive normal transitions; this is
// only a final animation-level safety net.
const _busyAnimationSafetyLimit = Duration(seconds: 15);

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
  const PetHome({
    super.key,
    this.initialBubbleVisible = true,
    this.initialPetScale = 1.0,
    this.initialBubbleHeight = _petBubbleMinHeight,
  });

  final bool initialBubbleVisible;
  final double initialPetScale;
  final double initialBubbleHeight;

  @override
  State<PetHome> createState() => _PetHomeState();
}

class _PetHomeState extends State<PetHome> with WindowListener, TrayListener {
  static const _bubbleResizeHitHeight = 24.0;

  _PetAnimation _animation = _PetAnimation.normal;
  final _bubbleTodoController = TextEditingController();
  final _bubbleTodoFocusNode = FocusNode();
  bool _mouseThrough = false;
  bool _alwaysOnTop = true;
  Timer? _randomNormalTimer;
  Timer? _caretIdleTimer;
  Timer? _localCaretLossTimer;
  Timer? _caretHealthCheckTimer;
  StreamSubscription<FileSystemEvent>? _todoFileWatcher;
  Timer? _todoRefreshDebounce;
  Timer? _positionSaveDebounce;
  Timer? _longPressTimer;
  Timer? _animationCompletionTimer;
  Timer? _busyAnimationSafetyTimer;
  int _animationRevision = 0;
  final _random = Random();
  Offset? _pointerDownPosition;
  bool _pointerDragging = false;
  bool _longPressTriggered = false;
  bool _windowDragging = false;
  late double _petScale;
  bool _resizeCandidate = false;
  bool _resizing = false;
  double _resizeStartScale = 1.0;
  double? _resizeStartCursorY;
  bool _petResizeSampleInFlight = false;
  bool _petResizeSamplePending = false;
  late double _bubbleHeight;
  bool _bubbleResizing = false;
  double _bubbleResizeStartHeight = _petBubbleMinHeight;
  double? _bubbleResizeStartCursorY;
  bool _bubbleResizeSampleInFlight = false;
  bool _bubbleResizeSamplePending = false;
  double _appliedPetScale = 1.0;
  double _appliedBubbleHeight = _petBubbleMinHeight;
  double? _pendingLayoutScale;
  double? _pendingLayoutBubbleHeight;
  bool _layoutUpdateInFlight = false;
  bool _petVisible = true;
  bool _systemCaretActive = false;
  bool _caretIdleSuppressed = false;
  bool _requestingCaretRefresh = false;
  bool _bubbleInputActive = false;
  bool _bubbleEditInputActive = false;
  bool _bubbleInputCaretLost = false;
  late bool _bubbleVisible;
  List<TodoEntry> _todos = const [];
  _UpdateInfo? _updateInfo;
  _UpdateStatus _updateStatus = _UpdateStatus.idle;
  double _updateProgress = 0;

  @override
  void initState() {
    super.initState();
    _petScale = widget.initialPetScale.clamp(_minPetScale, _maxPetScale);
    _bubbleHeight = max(_petBubbleMinHeight, widget.initialBubbleHeight);
    _appliedPetScale = _petScale;
    _appliedBubbleHeight = _bubbleHeight;
    _bubbleVisible = widget.initialBubbleVisible;
    windowManager.addListener(this);
    trayManager.addListener(this);
    _initialize();
    _initializeCaretMonitoring();
    _bubbleTodoFocusNode.addListener(_handleBubbleInputFocus);
    _refreshTodos();
    _initializeTodoWatcher();
    _scheduleRandomNormalEnd();
    unawaited(_checkForUpdates());
  }

  Future<void> _checkForUpdates() async {
    if (!Platform.isWindows || _isFlutterTest) return;
    final update = await _UpdateService.check();
    if (!mounted || update == null) return;
    final settings = await _PanelDataStore.load();
    if (!mounted) return;
    setState(() {
      _updateInfo = update;
      _updateStatus = _UpdateStatus.available;
      _bubbleVisible = true;
    });
    if (settings.autoUpdate) unawaited(_downloadUpdate());
  }

  void _dismissUpdate() {
    if (!mounted) return;
    setState(() => _updateStatus = _UpdateStatus.idle);
  }

  Future<void> _downloadUpdate() async {
    final update = _updateInfo;
    if (update == null || _updateStatus == _UpdateStatus.downloading) return;
    setState(() {
      _updateStatus = _UpdateStatus.downloading;
      _updateProgress = 0;
    });
    try {
      final archive = await _UpdateService.download(update, (progress) {
        if (mounted) setState(() => _updateProgress = progress.clamp(0, 1));
      });
      if (!mounted) return;
      await _saveWindowPosition();
      if (_UpdateService._isSameVersion(update.version)) {
        await _UpdateService.markSameVersionUpdate();
      }
      await _UpdateService.launchUpdater(archive);
      exit(0);
    } catch (_) {
      if (mounted) setState(() => _updateStatus = _UpdateStatus.failed);
    }
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
        MenuItem(key: 'resetScale', label: '恢复 100% 大小'),
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
    _localCaretLossTimer?.cancel();
    _caretHealthCheckTimer?.cancel();
    _longPressTimer?.cancel();
    _animationCompletionTimer?.cancel();
    _busyAnimationSafetyTimer?.cancel();
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
      case 'resetScale':
        _resetPetScale();
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

  double get _petWindowWidth =>
      max(_petBubbleWidth, _petStageWidth * _petScale);

  bool _isInBubbleBounds(Offset position) {
    if (!_bubbleVisible) return false;
    final top = _isFlutterTest ? 0.0 : _petBubbleTailHeight;
    final left = (_petWindowWidth - _petBubbleWidth) / 2;
    return Rect.fromLTWH(
      left,
      top,
      _petBubbleWidth,
      _bubbleHeight,
    ).contains(position);
  }

  void _setLayoutPreview({double? scale, double? bubbleHeight}) {
    final nextScale = (scale ?? _petScale)
        .clamp(_minPetScale, _maxPetScale)
        .toDouble();
    final nextBubbleHeight = max(
      _petBubbleMinHeight,
      bubbleHeight ?? _bubbleHeight,
    );
    if (nextScale == _petScale && nextBubbleHeight == _bubbleHeight) return;
    setState(() {
      _petScale = nextScale;
      _bubbleHeight = nextBubbleHeight;
    });
    if (_isFlutterTest) return;
    _pendingLayoutScale = nextScale;
    _pendingLayoutBubbleHeight = nextBubbleHeight;
    unawaited(_drainLayoutUpdates());
  }

  Future<void> _drainLayoutUpdates() async {
    if (_layoutUpdateInFlight) return;
    _layoutUpdateInFlight = true;
    try {
      while (_pendingLayoutScale != null && mounted) {
        final targetScale = _pendingLayoutScale!;
        final targetBubbleHeight = _pendingLayoutBubbleHeight!;
        _pendingLayoutScale = null;
        _pendingLayoutBubbleHeight = null;
        final oldWidth = max(
          _petBubbleWidth,
          _petStageWidth * _appliedPetScale,
        );
        final oldHeight = _petWindowHeightForLayout(
          _appliedPetScale,
          _appliedBubbleHeight,
        );
        final newWidth = max(_petBubbleWidth, _petStageWidth * targetScale);
        final newHeight = _petWindowHeightForLayout(
          targetScale,
          targetBubbleHeight,
        );
        final position = await windowManager.getPosition();
        await windowManager.setBounds(
          Rect.fromLTWH(
            position.dx + (oldWidth - newWidth) / 2,
            position.dy + oldHeight - newHeight,
            newWidth,
            newHeight,
          ),
        );
        _appliedPetScale = targetScale;
        _appliedBubbleHeight = targetBubbleHeight;
      }
    } on MissingPluginException {
      // Widget tests do not load the native window manager plugin.
    } finally {
      _layoutUpdateInFlight = false;
      if (_pendingLayoutScale != null && mounted)
        unawaited(_drainLayoutUpdates());
    }
  }

  void _resetPetScale() => _setLayoutPreview(scale: 1.0);

  Future<void> _samplePetResizeCursor() async {
    if (_petResizeSampleInFlight || !_resizing || !mounted) {
      _petResizeSamplePending = true;
      return;
    }
    _petResizeSampleInFlight = true;
    try {
      final cursor = await screenRetriever.getCursorScreenPoint();
      _resizeStartCursorY ??= cursor.dy;
      final scale =
          _resizeStartScale -
          (cursor.dy - _resizeStartCursorY!) * _petScalePerDragPixel;
      _setLayoutPreview(scale: scale);
    } finally {
      _petResizeSampleInFlight = false;
      if (_petResizeSamplePending) {
        _petResizeSamplePending = false;
        unawaited(_samplePetResizeCursor());
      }
    }
  }

  void _beginBubbleResize(PointerDownEvent event) {
    if (event.buttons != kPrimaryMouseButton) return;
    if (event.localPosition.dy > _bubbleResizeHitHeight) return;
    _bubbleResizing = true;
    _bubbleResizeStartHeight = _bubbleHeight;
    _bubbleResizeStartCursorY = null;
  }

  void _updateBubbleResize(PointerMoveEvent event) {
    if (!_bubbleResizing) return;
    unawaited(_sampleBubbleResizeCursor());
  }

  Future<void> _sampleBubbleResizeCursor() async {
    if (_bubbleResizeSampleInFlight || !_bubbleResizing || !mounted) {
      _bubbleResizeSamplePending = true;
      return;
    }
    _bubbleResizeSampleInFlight = true;
    try {
      final cursor = await screenRetriever.getCursorScreenPoint();
      _bubbleResizeStartCursorY ??= cursor.dy;
      final height =
          _bubbleResizeStartHeight + (_bubbleResizeStartCursorY! - cursor.dy);
      _setLayoutPreview(bubbleHeight: height);
    } finally {
      _bubbleResizeSampleInFlight = false;
      if (_bubbleResizeSamplePending) {
        _bubbleResizeSamplePending = false;
        unawaited(_sampleBubbleResizeCursor());
      }
    }
  }

  void _endBubbleResize() {
    _bubbleResizing = false;
    _bubbleResizeStartCursorY = null;
  }

  Future<void> _refreshTodos() async {
    final data = await _PanelDataStore.load();
    if (!mounted) return;
    final now = DateTime.now();
    final visibleTodos =
        data.todos.where((todo) => _isSameDay(todo.createdAt, now)).toList()
          ..sort(_compareBubbleTodos);
    final next = List<TodoEntry>.unmodifiable(visibleTodos);
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
        autoUpdate: current.autoUpdate,
      ),
    );
    if (mounted) {
      final now = DateTime.now();
      setState(() {
        final visibleTodos =
            todos.where((todo) => _isSameDay(todo.createdAt, now)).toList()
              ..sort(_compareBubbleTodos);
        _todos = List.unmodifiable(visibleTodos);
      });
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

  Future<void> _reorderBubbleTodo(
    TodoEntry dragged,
    TodoEntry target,
    bool placeAfter,
  ) async {
    final current = await _PanelDataStore.load();
    final items =
        current.todos
            .where((todo) => _isSameDay(todo.createdAt, DateTime.now()))
            .toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final from = items.indexWhere((todo) => todo.id == dragged.id);
    if (from < 0 || dragged.id == target.id) return;
    final item = items.removeAt(from);
    final targetIndex = items.indexWhere((todo) => todo.id == target.id);
    if (targetIndex < 0) return;
    items.insert(targetIndex + (placeAfter ? 1 : 0), item);
    final day = DateTime.now();
    final updates = <int, TodoEntry>{};
    for (var i = 0; i < items.length; i++) {
      updates[items[i].id] = items[i].copyWith(
        createdAt: DateTime(day.year, day.month, day.day, 12, i),
      );
    }
    final todos = current.todos
        .map((todo) => updates[todo.id] ?? todo)
        .toList();
    await _saveBubbleTodos(current, todos);
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
      _localCaretLossTimer?.cancel();
      _bubbleInputCaretLost = false;
      if (!_windowDragging && _animation != _PetAnimation.busy) {
        _playAnimation(_PetAnimation.busy);
      }
    } else if (!_bubbleInputActive && !_systemCaretActive && !_windowDragging) {
      _localCaretLossTimer?.cancel();
      _bubbleInputCaretLost = false;
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
    unawaited(_requestCaretStateRefresh());
    _caretHealthCheckTimer = Timer.periodic(
      _caretHealthCheckInterval,
      (_) => unawaited(_requestCaretStateRefresh()),
    );
  }

  Future<void> _requestCaretStateRefresh() async {
    if (!mounted || _requestingCaretRefresh) return;
    _requestingCaretRefresh = true;
    try {
      await _systemChannel.invokeMethod<void>('requestCaretStateRefresh');
    } on MissingPluginException {
      // Widget tests and non-Windows runners do not provide the native channel.
    } on PlatformException {
      // The next health check retries transient native channel failures.
    } finally {
      _requestingCaretRefresh = false;
    }
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
      _localCaretLossTimer?.cancel();
      _bubbleInputCaretLost = false;
      if (!_windowDragging && _animation != _PetAnimation.busy) {
        _playAnimation(_PetAnimation.busy);
      }
    } else if (!_bubbleEditInputActive &&
        !_systemCaretActive &&
        !_windowDragging) {
      _localCaretLossTimer?.cancel();
      _bubbleInputCaretLost = false;
      _playAnimation(_PetAnimation.busyEnd);
    }
  }

  void _handleCaretState(bool active) {
    if (!mounted) return;
    if (!active) {
      _caretIdleTimer?.cancel();
      _caretIdleTimer = null;
      if (_bubbleInputActive || _bubbleEditInputActive) {
        if (_bubbleInputCaretLost) {
          return;
        }
        _confirmLocalCaretLossLater();
        return;
      }
      if (!_systemCaretActive) return;
      _systemCaretActive = false;
      final wasIdleSuppressed = _caretIdleSuppressed;
      _caretIdleSuppressed = false;
      if (!wasIdleSuppressed &&
          !_bubbleInputActive &&
          !_bubbleEditInputActive &&
          !_windowDragging) {
        _playAnimation(_PetAnimation.busyEnd);
      }
      return;
    }
    _localCaretLossTimer?.cancel();
    _bubbleInputCaretLost = false;
    if (_systemCaretActive) return;
    _systemCaretActive = true;
    _caretIdleSuppressed = false;
    _resetCaretIdleTimer();
    if (!_windowDragging && _animation != _PetAnimation.busy) {
      _playAnimation(_PetAnimation.busy);
    }
  }

  void _confirmLocalCaretLossLater() {
    if (_localCaretLossTimer?.isActive ?? false) {
      return;
    }
    _localCaretLossTimer = Timer(_localCaretLossConfirmDelay, () {
      _localCaretLossTimer = null;
      if (!mounted || (!_bubbleInputActive && !_bubbleEditInputActive)) {
        return;
      }
      _bubbleInputCaretLost = true;
      _systemCaretActive = false;
      _caretIdleSuppressed = false;
      _playAnimation(_PetAnimation.busyEnd);
    });
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
    _busyAnimationSafetyTimer?.cancel();
    _busyAnimationSafetyTimer = null;
    setState(() {
      _animation = animation;
      _animationRevision++;
    });
    if (animation == _PetAnimation.busy) {
      _busyAnimationSafetyTimer = Timer(
        _busyAnimationSafetyLimit,
        _expireBusyAnimation,
      );
    }
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

  void _expireBusyAnimation() {
    _busyAnimationSafetyTimer = null;
    if (!mounted || _animation != _PetAnimation.busy || _windowDragging) {
      return;
    }
    if (_bubbleInputActive || _bubbleEditInputActive) return;
    // Treat the external caret sample as stale. This also prevents
    // _onAnimationCompleted from immediately restarting d.gif.
    _caretIdleTimer?.cancel();
    _caretIdleTimer = null;
    _systemCaretActive = false;
    _caretIdleSuppressed = true;
    _playAnimation(_PetAnimation.busyEnd);
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_isInBubbleBounds(event.localPosition)) return;
    if (event.buttons != kPrimaryMouseButton) return;
    final resizeWithCtrl = HardwareKeyboard.instance.logicalKeysPressed.any(
      (key) =>
          key == LogicalKeyboardKey.controlLeft ||
          key == LogicalKeyboardKey.controlRight,
    );
    _pointerDownPosition = event.position;
    _pointerDragging = false;
    _longPressTriggered = false;
    _resizeCandidate = resizeWithCtrl;
    _resizing = false;
    _resizeStartScale = _petScale;
    _resizeStartCursorY = null;
    _longPressTimer?.cancel();
    _longPressTimer = Timer(const Duration(milliseconds: 250), () {
      if (!mounted || _pointerDownPosition == null || _pointerDragging) return;
      if (_resizeCandidate) {
        _resizing = true;
        _longPressTriggered = true;
        return;
      }
      _longPressTriggered = true;
      _playAnimation(_PetAnimation.longPress);
    });
  }

  void _onPointerMove(PointerMoveEvent event) {
    final origin = _pointerDownPosition;
    if (origin == null) return;
    if (_resizing) {
      if (_isFlutterTest) {
        final scale =
            _resizeStartScale -
            (event.position.dy -
                    (_pointerDownPosition?.dy ?? event.position.dy)) *
                _petScalePerDragPixel;
        _setLayoutPreview(scale: scale);
        return;
      }
      unawaited(_samplePetResizeCursor());
      return;
    }
    if (_resizeCandidate || _pointerDragging) return;
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
    if (_resizing) {
      _setLayoutPreview();
      _resetPointerGesture();
      return;
    }
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
    if (_resizing) _setLayoutPreview();
    _resetPointerGesture();
  }

  void _resetPointerGesture() {
    _pointerDownPosition = null;
    _pointerDragging = false;
    _longPressTriggered = false;
    _resizeCandidate = false;
    _resizing = false;
    _resizeStartCursorY = null;
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
      await _PetWindowPositionStore.save(
        position,
        scale: _petScale,
        bubbleHeight: _bubbleHeight,
      );
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
        (_bubbleInputActive && !_bubbleInputCaretLost) ||
        (_bubbleEditInputActive && !_bubbleInputCaretLost)) {
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
    final executable = File(Platform.resolvedExecutable);
    final log = File('${Directory.systemTemp.path}\\remielle-panel.log');
    try {
      await log.writeAsString(
        'launch=${executable.path}\nexists=${await executable.exists()}\n',
        mode: FileMode.write,
      );
      final process = await Process.start(
        executable.path,
        const ['--control-panel'],
        workingDirectory: executable.parent.path,
        mode: ProcessStartMode.detached,
      );
      _panelProcess = process;
      process.exitCode.then((_) {
        if (identical(_panelProcess, process)) _panelProcess = null;
      });
      await log.writeAsString('pid=${process.pid}\n', mode: FileMode.append);
    } catch (error) {
      await log.writeAsString('error=$error\n', mode: FileMode.append);
    }
  }

  @override
  Widget build(BuildContext context) {
    final assetSize = _assetSize;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapDown: (details) {
          if (!_isInBubbleBounds(details.localPosition)) {
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
                    top: _isFlutterTest ? 0 : null,
                    bottom: _isFlutterTest
                        ? null
                        : _petStageHeight * _petScale + _petBubbleGap,
                    left: (_petWindowWidth - _petBubbleWidth) / 2,
                    child: Listener(
                      behavior: HitTestBehavior.translucent,
                      onPointerDown: _beginBubbleResize,
                      onPointerMove: _updateBubbleResize,
                      onPointerUp: (_) => _endBubbleResize(),
                      onPointerCancel: (_) => _endBubbleResize(),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          _TodoSpeechBubble(
                            height: _bubbleHeight,
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
                            onReorder: _reorderBubbleTodo,
                            onMenu: _showBubbleTodoMenu,
                            onEdit: _renameBubbleTodo,
                            onEditFocusChanged: _handleBubbleEditFocus,
                            updateInfo: _updateInfo,
                            updateStatus: _updateStatus,
                            updateProgress: _updateProgress,
                            onUpdateNow: _downloadUpdate,
                            onUpdateDismissed: _dismissUpdate,
                          ),
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            height: _bubbleResizeHitHeight,
                            child: MouseRegion(
                              cursor: SystemMouseCursors.resizeUpDown,
                              child: Listener(
                                behavior: HitTestBehavior.opaque,
                                onPointerDown: _beginBubbleResize,
                                onPointerMove: _updateBubbleResize,
                                onPointerUp: (_) => _endBubbleResize(),
                                onPointerCancel: (_) => _endBubbleResize(),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                Transform.translate(
                  key: const ValueKey('pet-animation-position'),
                  offset: Offset.zero,
                  child: SizedBox(
                    width: _petStageWidth,
                    height: _petStageHeight,
                    child: Transform.scale(
                      key: const ValueKey('pet-animation-scale'),
                      scale: _petScale,
                      alignment: Alignment.bottomCenter,
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
    required this.height,
    required this.todos,
    required this.controller,
    required this.focusNode,
    required this.onAdd,
    required this.onBlankTap,
    required this.onClose,
    required this.onToggle,
    required this.onReorder,
    required this.onMenu,
    required this.onEdit,
    required this.onEditFocusChanged,
    required this.updateInfo,
    required this.updateStatus,
    required this.updateProgress,
    required this.onUpdateNow,
    required this.onUpdateDismissed,
  });

  final double height;
  final List<TodoEntry> todos;
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onAdd;
  final VoidCallback onBlankTap;
  final VoidCallback onClose;
  final ValueChanged<TodoEntry> onToggle;
  final Future<void> Function(TodoEntry, TodoEntry, bool) onReorder;
  final void Function(TodoEntry, Offset) onMenu;
  final Future<void> Function(TodoEntry, String) onEdit;
  final ValueChanged<bool> onEditFocusChanged;
  final _UpdateInfo? updateInfo;
  final _UpdateStatus updateStatus;
  final double updateProgress;
  final VoidCallback onUpdateNow;
  final VoidCallback onUpdateDismissed;

  @override
  State<_TodoSpeechBubble> createState() => _TodoSpeechBubbleState();
}

class _TodoSpeechBubbleState extends State<_TodoSpeechBubble> {
  final _editController = TextEditingController();
  final _editFocusNode = FocusNode();
  int? _editingTodoId;

  _UpdateInfo? get updateInfo => widget.updateInfo;
  _UpdateStatus get updateStatus => widget.updateStatus;
  double get updateProgress => widget.updateProgress;
  VoidCallback get onUpdateNow => widget.onUpdateNow;
  VoidCallback get onUpdateDismissed => widget.onUpdateDismissed;

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
        if (focusNode.hasFocus || _editFocusNode.hasFocus) return;
        final p = event.localPosition;
        if (p.dy <= 24) return;
        final inHeaderClose = p.dx >= 250 && p.dy <= 42;
        final inTodoArea = p.dy >= 48 && p.dy < widget.height - 52;
        final inInputArea = p.dy >= widget.height - 52;
        if (!inHeaderClose && !inTodoArea && !inInputArea) onBlankTap();
      },
      child: SizedBox(
        width: 300,
        height: widget.height,
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
                  if (updateStatus != _UpdateStatus.idle)
                    _UpdateNotice(
                      info: updateInfo,
                      status: updateStatus,
                      progress: updateProgress,
                      onUpdateNow: onUpdateNow,
                      onDismissed: onUpdateDismissed,
                    ),
                  if (updateStatus != _UpdateStatus.idle)
                    const SizedBox(height: 12),
                  Expanded(
                    child: ScrollConfiguration(
                      behavior: ScrollConfiguration.of(
                        context,
                      ).copyWith(scrollbars: false),
                      child: todos.isEmpty
                          ? const _BubbleEmptyPlaceholder()
                          : ListView.separated(
                              physics: const _BubbleScrollPhysics(),
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
                                  onReorder: widget.onReorder,
                                );
                              },
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: 10),
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
                                fontSize: 12,
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

class _UpdateNotice extends StatelessWidget {
  const _UpdateNotice({
    required this.info,
    required this.status,
    required this.progress,
    required this.onUpdateNow,
    required this.onDismissed,
  });

  final _UpdateInfo? info;
  final _UpdateStatus status;
  final double progress;
  final VoidCallback onUpdateNow;
  final VoidCallback onDismissed;

  @override
  Widget build(BuildContext context) {
    final downloading = status == _UpdateStatus.downloading;
    final failed = status == _UpdateStatus.failed;
    final version = info?.version ?? '';
    final title = downloading
        ? '正在更新至 v$version'
        : failed
        ? '更新下载失败'
        : '发现新版本 v$version';
    final subtitle = downloading
        ? '下载中 ${(progress * 100).round()}%'
        : failed
        ? '请检查网络后重试'
        : '是否立即更新？';
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xfffff0f3),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xffffd5dc)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontFamily: 'Microsoft YaHei',
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xff4a4a4a),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            subtitle,
            style: const TextStyle(
              fontFamily: 'Microsoft YaHei',
              fontSize: 11,
              color: Color(0xff8a6870),
            ),
          ),
          if (downloading) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 5,
                backgroundColor: const Color(0xffffdce2),
                color: const Color(0xffff8fa4),
              ),
            ),
          ] else ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: onDismissed,
                    child: const Text('暂不更新'),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: FilledButton(
                    onPressed: onUpdateNow,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xffff8fa4),
                      minimumSize: const Size.fromHeight(30),
                    ),
                    child: Text(failed ? '重试' : '立即更新'),
                  ),
                ),
              ],
            ),
          ],
        ],
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
    required this.onReorder,
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
  final Future<void> Function(TodoEntry, TodoEntry, bool) onReorder;

  @override
  Widget build(BuildContext context) {
    final targetKey = GlobalKey();
    return Column(
      children: [
        DragTarget<TodoEntry>(
          onWillAcceptWithDetails: (details) => details.data.id != todo.id,
          onAcceptWithDetails: (details) =>
              onReorder(details.data, todo, false),
          builder: (context, candidates, rejected) => SizedBox(
            height: 8,
            width: double.infinity,
            child: candidates.isEmpty
                ? null
                : const ColoredBox(color: Color(0x22ff8fa4)),
          ),
        ),
        LongPressDraggable<TodoEntry>(
          data: todo,
          delay: const Duration(milliseconds: 180),
          dragAnchorStrategy: pointerDragAnchorStrategy,
          feedback: Material(
            color: Colors.transparent,
            child: Container(
              width: 260,
              height: 24,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              color: const Color(0xe6ffffff),
              alignment: Alignment.centerLeft,
              child: Text(todo.title, overflow: TextOverflow.ellipsis),
            ),
          ),
          childWhenDragging: Opacity(opacity: 0.35, child: _buildRow(context)),
          child: DragTarget<TodoEntry>(
            onWillAcceptWithDetails: (details) => details.data.id != todo.id,
            onAcceptWithDetails: (details) {
              final box =
                  targetKey.currentContext?.findRenderObject() as RenderBox?;
              final placeAfter = box == null
                  ? false
                  : box.globalToLocal(details.offset).dy >= box.size.height / 2;
              onReorder(details.data, todo, placeAfter);
            },
            builder: (context, candidates, rejected) =>
                SizedBox(key: targetKey, child: _buildRow(context)),
          ),
        ),
        DragTarget<TodoEntry>(
          onWillAcceptWithDetails: (details) => details.data.id != todo.id,
          onAcceptWithDetails: (details) => onReorder(details.data, todo, true),
          builder: (context, candidates, rejected) => SizedBox(
            height: 10,
            width: double.infinity,
            child: candidates.isEmpty
                ? null
                : const ColoredBox(color: Color(0x22ff8fa4)),
          ),
        ),
      ],
    );
  }

  Widget _buildRow(BuildContext context) {
    final completed = todo.completedAt != null;
    return Listener(
      onPointerDown: (event) {
        if (event.buttons == kSecondaryMouseButton) {
          onMenu(event.position);
        }
      },
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 18),
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
              textDirection: Directionality.of(context),
            )..layout(maxWidth: constraints.maxWidth - 26);
            final textHitWidth = min(constraints.maxWidth, 26 + painter.width);
            return Listener(
              onPointerUp: (event) {
                if (event.localPosition.dx > textHitWidth) onBlankTap();
              },
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onToggle,
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
                            minLines: 1,
                            maxLines: null,
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
                        : GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: onEditTap,
                            child: Text(
                              todo.title,
                              softWrap: true,
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

class _BubbleEmptyPlaceholder extends StatelessWidget {
  const _BubbleEmptyPlaceholder();

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.auto_awesome, size: 20, color: Color(0xffffb6c1)),
        const SizedBox(height: 12),
        const Text(
          '今天没有待办哦~',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'Microsoft YaHei',
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: Color(0xffff69b4),
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          '可以休息一下啦 🌸',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'Microsoft YaHei',
            fontSize: 11,
            color: Color(0xff9ca3af),
          ),
        ),
      ],
    ),
  );
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
