import 'dart:io';

import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  if (args.contains('--control-panel')) {
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
    size: Size(320, 340),
    minimumSize: Size(180, 190),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: true,
    titleBarStyle: TitleBarStyle.hidden,
    alwaysOnTop: true,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.setAsFrameless();
    await windowManager.setBackgroundColor(Colors.transparent);
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

class PetHome extends StatefulWidget {
  const PetHome({super.key});

  @override
  State<PetHome> createState() => _PetHomeState();
}

class _PetHomeState extends State<PetHome> with WindowListener, TrayListener {
  final PetMode _mode = PetMode.normal;
  bool _mouseThrough = false;
  bool _alwaysOnTop = true;
  bool _clamping = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    trayManager.addListener(this);
    _initialize();
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

  @override
  Future<void> onWindowMove() async {
    if (_clamping) return;
    final display = await screenRetriever.getPrimaryDisplay();
    final position = await windowManager.getPosition();
    final size = await windowManager.getSize();
    final origin = display.visiblePosition ?? Offset.zero;
    final area = display.visibleSize ?? display.size;
    final bounded = Offset(
      position.dx
          .clamp(origin.dx, origin.dx + area.width - size.width)
          .toDouble(),
      position.dy
          .clamp(origin.dy, origin.dy + area.height - size.height)
          .toDouble(),
    );
    if (bounded != position) {
      _clamping = true;
      await windowManager.setPosition(bounded);
      _clamping = false;
    }
  }

  String get _asset => switch (_mode) {
    PetMode.normal => 'assets/animations/a.gif',
    PetMode.idle => 'assets/animations/b.gif',
    PetMode.inactive => 'assets/animations/e.gif',
  };

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
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    body: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTap: trayManager.popUpContextMenu,
      onPanStart: (_) => windowManager.startDragging(),
      child: Center(
        child: FittedBox(
          fit: BoxFit.contain,
          child: Image.asset(
            _asset,
            filterQuality: FilterQuality.high,
            gaplessPlayback: true,
          ),
        ),
      ),
    ),
  );
}

class ControlPanelApp extends StatelessWidget {
  const ControlPanelApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Remielle 控制面板',
    theme: _theme(),
    home: const ControlPanelPage(),
  );
}

class ControlPanelPage extends StatefulWidget {
  const ControlPanelPage({super.key});

  @override
  State<ControlPanelPage> createState() => _ControlPanelPageState();
}

class _ControlPanelPageState extends State<ControlPanelPage> {
  final _todoController = TextEditingController();
  final _todos = <TodoEntry>[TodoEntry(id: 1, title: '整理 Remielle 动画素材')];
  int _nextTodoId = 2;
  PetMode _mode = PetMode.normal;
  int _idleMinutes = 5;
  bool _alwaysOnTop = true;
  bool _mouseThrough = false;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _todoController.dispose();
    super.dispose();
  }

  void _addTodo() {
    final value = _todoController.text.trim();
    if (value.isEmpty) return;
    setState(() {
      _todos.add(TodoEntry(id: _nextTodoId++, title: value));
      _todoController.clear();
    });
    FocusManager.instance.primaryFocus?.unfocus();
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
                      onChanged: (_) => setState(() {
                        _todos.removeWhere((item) => item.id == todo.id);
                      }),
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
