part of 'main.dart';

ThemeData _controlPanelTheme() {
  const accent = Color(0xff0067c0);
  const foreground = Color(0xff1a1a1a);
  final base = ThemeData(
    useMaterial3: true,
    fontFamily: 'Microsoft YaHei',
    scaffoldBackgroundColor: const Color(0xfff5f5f5),
    colorScheme: const ColorScheme.light(
      primary: accent,
      onPrimary: Colors.white,
      surface: Color(0xfff5f5f5),
      onSurface: foreground,
      outline: Color(0xff8a8a8a),
    ),
  );
  return base.copyWith(
    splashFactory: NoSplash.splashFactory,
    hoverColor: const Color(0xffe9e9e9),
    focusColor: const Color(0xffe5e5e5),
    textTheme: base.textTheme.apply(
      fontFamily: 'Microsoft YaHei',
      bodyColor: foreground,
      displayColor: foreground,
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(2)),
        borderSide: BorderSide(color: Color(0xff8a8a8a)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(2)),
        borderSide: BorderSide(color: accent, width: 2),
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
    theme: _controlPanelTheme(),
    home: const ControlPanelPage(),
  );
}

enum _PanelSection { todo, settings }

class ControlPanelPage extends StatefulWidget {
  const ControlPanelPage({super.key});

  @override
  State<ControlPanelPage> createState() => _ControlPanelPageState();
}

class _ControlPanelPageState extends State<ControlPanelPage>
    with WindowListener {
  final _todoController = TextEditingController();
  final _todoFocusNode = FocusNode();
  final _editController = TextEditingController();
  final _editFocusNode = FocusNode();
  final _todos = <TodoEntry>[];
  _PanelSection _section = _PanelSection.todo;
  int _nextTodoId = 1;
  bool _launchAtStartup = false;
  bool _exitTrayOnPetExit = true;
  bool _skipTodoDeleteConfirmation = false;
  bool _updatingStartup = false;
  bool _closing = false;
  bool _inputSessionActive = false;
  int? _hoveredTodoId;
  int? _editingTodoId;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _todoFocusNode.addListener(_onInputFocusChanged);
    _editFocusNode.addListener(_onInputFocusChanged);
    _initializePanel();
  }

  Future<void> _initializePanel() async {
    if (!_isFlutterTest) await windowManager.setPreventClose(true);
    final data = await _PanelDataStore.load();
    if (!mounted) return;
    setState(() {
      _todos
        ..clear()
        ..addAll(data.todos);
      _nextTodoId =
          _todos.fold<int>(
            0,
            (maxId, todo) => todo.id > maxId ? todo.id : maxId,
          ) +
          1;
      _launchAtStartup = data.launchAtStartup;
      _exitTrayOnPetExit = data.exitTrayOnPetExit;
      _skipTodoDeleteConfirmation = data.skipTodoDeleteConfirmation;
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _todoFocusNode.removeListener(_onInputFocusChanged);
    _editFocusNode.removeListener(_onInputFocusChanged);
    _todoFocusNode.dispose();
    _editFocusNode.dispose();
    _todoController.dispose();
    _editController.dispose();
    super.dispose();
  }

  void _onInputFocusChanged() {
    if ((_todoFocusNode.hasFocus || _editFocusNode.hasFocus) &&
        !_inputSessionActive) {
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
    if (value.isEmpty) return;
    setState(() {
      _todos.add(TodoEntry(id: _nextTodoId++, title: value));
      _todoController.clear();
    });
    _endInputSession();
    FocusManager.instance.primaryFocus?.unfocus();
    _savePanelData();
  }

  Future<void> _completeTodo(TodoEntry todo) async {
    if (_editingTodoId == todo.id) _cancelEditing();
    setState(() => _todos.removeWhere((item) => item.id == todo.id));
    await _savePanelData();
    await _sendPetEvent('todoDone');
  }

  Future<void> _requestDeleteTodo(TodoEntry todo) async {
    if (!_skipTodoDeleteConfirmation) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(3)),
          ),
          title: const Text('删除 Todo'),
          content: Text('确定要删除“${todo.title}”吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('confirm-delete-todo'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('删除'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    if (_editingTodoId == todo.id) _cancelEditing();
    setState(() => _todos.removeWhere((item) => item.id == todo.id));
    await _savePanelData();
  }

  Future<void> _startEditing(TodoEntry todo) async {
    if (_editingTodoId == todo.id) return;
    if (_editingTodoId != null) _finishEditing();
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

  void _finishEditing() {
    final editingId = _editingTodoId;
    if (editingId == null) return;
    final value = _editController.text.trim();
    final index = _todos.indexWhere((todo) => todo.id == editingId);
    setState(() {
      if (index >= 0 && value.isNotEmpty) {
        _todos[index] = TodoEntry(id: editingId, title: value);
      }
      _editingTodoId = null;
    });
    _editFocusNode.unfocus();
    _endInputSession();
    _savePanelData();
  }

  void _cancelEditing() {
    if (_editingTodoId == null) return;
    setState(() => _editingTodoId = null);
    _editFocusNode.unfocus();
    _endInputSession();
  }

  Future<void> _showTodoMenu(TodoEntry todo, Offset globalPosition) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = overlay.globalToLocal(globalPosition);
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromSize(
        Rect.fromLTWH(position.dx, position.dy, 0, 0),
        overlay.size,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(3)),
      ),
      items: const [
        PopupMenuItem(value: 'edit', height: 36, child: Text('编辑')),
        PopupMenuItem(value: 'delete', height: 36, child: Text('删除')),
      ],
    );
    if (selected == 'edit' && mounted) await _startEditing(todo);
    if (selected == 'delete' && mounted) await _requestDeleteTodo(todo);
  }

  Future<void> _savePanelData() => _PanelDataStore.save(
    _PanelData(
      todos: List.unmodifiable(_todos),
      launchAtStartup: _launchAtStartup,
      exitTrayOnPetExit: _exitTrayOnPetExit,
      skipTodoDeleteConfirmation: _skipTodoDeleteConfirmation,
    ),
  );

  Future<void> _setLaunchAtStartup(bool value) async {
    if (_updatingStartup) return;
    setState(() => _updatingStartup = true);
    try {
      await _WindowsStartup.setEnabled(value);
      if (!mounted) return;
      setState(() => _launchAtStartup = value);
      await _savePanelData();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法更新开机启动设置。')));
      }
    } finally {
      if (mounted) setState(() => _updatingStartup = false);
    }
  }

  Future<void> _setExitTrayOnPetExit(bool value) async {
    setState(() => _exitTrayOnPetExit = value);
    await _savePanelData();
  }

  Future<void> _setSkipTodoDeleteConfirmation(bool value) async {
    setState(() => _skipTodoDeleteConfirmation = value);
    await _savePanelData();
  }

  @override
  Future<void> onWindowClose() => _closePanel();

  Future<void> _closePanel() async {
    if (_closing) return;
    _closing = true;
    if (_editingTodoId != null) {
      _finishEditing();
    } else {
      _endInputSession();
    }
    await _savePanelData();
    if (!_isFlutterTest) await windowManager.destroy();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Row(
      children: [
        _NavigationPane(
          selected: _section,
          onSelected: (section) {
            if (_editingTodoId != null) _finishEditing();
            setState(() => _section = section);
          },
        ),
        const VerticalDivider(width: 1, thickness: 1, color: Color(0xffd6d6d6)),
        Expanded(
          child: _section == _PanelSection.todo
              ? _buildTodoPage()
              : _buildSettingsPage(),
        ),
      ],
    ),
  );

  Widget _buildTodoPage() => GestureDetector(
    key: const ValueKey('todo-blank-add-area'),
    behavior: HitTestBehavior.opaque,
    onTap: () {
      if (_editingTodoId != null) {
        _finishEditing();
      } else {
        _addTodo();
      }
    },
    child: Padding(
      padding: const EdgeInsets.fromLTRB(36, 30, 36, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _PageHeader(title: 'Todo', subtitle: '管理待办事项'),
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('todo-input'),
                  controller: _todoController,
                  focusNode: _todoFocusNode,
                  style: const TextStyle(fontSize: 14),
                  decoration: const InputDecoration(
                    hintText: '添加 Todo',
                    fillColor: Colors.white,
                    hoverColor: Colors.white,
                    constraints: BoxConstraints(minHeight: 42, maxHeight: 42),
                  ),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _addTodo(),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox.square(
                dimension: 42,
                child: IconButton(
                  key: const ValueKey('add-todo-button'),
                  tooltip: '添加 Todo',
                  style: IconButton.styleFrom(
                    foregroundColor: Colors.white,
                    backgroundColor: const Color(0xff0067c0),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(2)),
                    ),
                  ),
                  onPressed: _addTodo,
                  icon: const Icon(Icons.add, size: 20),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            'Todo 列表',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Divider(height: 1, color: Color(0xffcfcfcf)),
          Expanded(child: _buildTodoList()),
        ],
      ),
    ),
  );

  Widget _buildTodoList() {
    if (_todos.isEmpty) {
      return const Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: EdgeInsets.only(top: 22),
          child: Text(
            '暂无待办事项',
            style: TextStyle(color: Color(0xff666666), fontSize: 13),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: _todos.length,
      separatorBuilder: (_, _) =>
          const Divider(height: 1, color: Color(0xffdedede)),
      itemBuilder: (context, index) {
        final todo = _todos[index];
        return MouseRegion(
          key: ValueKey('todo-row-${todo.id}'),
          cursor: SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hoveredTodoId = todo.id),
          onExit: (_) {
            if (_hoveredTodoId == todo.id) {
              setState(() => _hoveredTodoId = null);
            }
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onSecondaryTapDown: (details) =>
                _showTodoMenu(todo, details.globalPosition),
            child: AnimatedContainer(
              key: ValueKey('todo-row-background-${todo.id}'),
              duration: const Duration(milliseconds: 100),
              color: _hoveredTodoId == todo.id
                  ? const Color(0xffe9e9e9)
                  : const Color(0xfff5f5f5),
              height: 52,
              child: Row(
                children: [
                  Checkbox(
                    key: ValueKey('todo-checkbox-${todo.id}'),
                    value: false,
                    onChanged: (_) => _completeTodo(todo),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: _editingTodoId == todo.id
                        ? TextField(
                            key: ValueKey('edit-todo-input-${todo.id}'),
                            controller: _editController,
                            focusNode: _editFocusNode,
                            style: const TextStyle(fontSize: 14),
                            decoration: const InputDecoration(
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 8,
                              ),
                              constraints: BoxConstraints(
                                minHeight: 36,
                                maxHeight: 36,
                              ),
                            ),
                            textInputAction: TextInputAction.done,
                            onSubmitted: (_) => _finishEditing(),
                          )
                        : GestureDetector(
                            key: ValueKey('todo-title-${todo.id}'),
                            behavior: HitTestBehavior.opaque,
                            onTap: () => _startEditing(todo),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                todo.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 14),
                              ),
                            ),
                          ),
                  ),
                  SizedBox.square(
                    dimension: 30,
                    child: IconButton(
                      key: ValueKey('delete-todo-${todo.id}'),
                      tooltip: '删除 Todo',
                      padding: EdgeInsets.zero,
                      style: IconButton.styleFrom(
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.all(Radius.circular(2)),
                        ),
                      ),
                      onPressed: () => _requestDeleteTodo(todo),
                      icon: const Icon(Icons.remove, size: 17),
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSettingsPage() => Padding(
    padding: const EdgeInsets.fromLTRB(36, 30, 36, 28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _PageHeader(title: '设置', subtitle: '系统设置'),
        const SizedBox(height: 28),
        _SettingRow(
          title: '开机启动',
          subtitle: '登录 Windows 后自动启动 Remielle',
          control: Switch(
            key: const ValueKey('startup-switch'),
            value: _launchAtStartup,
            onChanged: _updatingStartup ? null : _setLaunchAtStartup,
          ),
        ),
        _SettingRow(
          title: '退出时同时退出托盘',
          subtitle: '从桌宠右键菜单退出时，同时结束托盘进程',
          control: Switch(
            key: const ValueKey('exit-tray-switch'),
            value: _exitTrayOnPetExit,
            onChanged: _setExitTrayOnPetExit,
          ),
        ),
        _SettingRow(
          title: '删除 Todo 时不再二次提醒',
          subtitle: '删除 Todo 时不显示确认窗口',
          control: Switch(
            key: const ValueKey('skip-delete-confirmation-switch'),
            value: _skipTodoDeleteConfirmation,
            onChanged: _setSkipTodoDeleteConfirmation,
          ),
        ),
      ],
    ),
  );
}

class _NavigationPane extends StatelessWidget {
  const _NavigationPane({required this.selected, required this.onSelected});

  final _PanelSection selected;
  final ValueChanged<_PanelSection> onSelected;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 220,
    child: ColoredBox(
      color: const Color(0xffeeeeee),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 26, 14, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                'Remielle',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 30),
            _NavigationItem(
              key: const ValueKey('todo-tab'),
              icon: Icons.check_box_outlined,
              label: 'Todo',
              selected: selected == _PanelSection.todo,
              onTap: () => onSelected(_PanelSection.todo),
            ),
            const SizedBox(height: 4),
            _NavigationItem(
              key: const ValueKey('settings-tab'),
              icon: Icons.settings_outlined,
              label: '设置',
              selected: selected == _PanelSection.settings,
              onTap: () => onSelected(_PanelSection.settings),
            ),
          ],
        ),
      ),
    ),
  );
}

class _NavigationItem extends StatelessWidget {
  const _NavigationItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? const Color(0xffdddddd) : Colors.transparent,
    borderRadius: const BorderRadius.all(Radius.circular(3)),
    child: InkWell(
      onTap: onTap,
      borderRadius: const BorderRadius.all(Radius.circular(3)),
      child: SizedBox(
        height: 42,
        child: Row(
          children: [
            SizedBox(
              width: 4,
              height: 20,
              child: ColoredBox(
                color: selected ? const Color(0xff0067c0) : Colors.transparent,
              ),
            ),
            const SizedBox(width: 12),
            Icon(icon, size: 19),
            const SizedBox(width: 12),
            Text(label, style: const TextStyle(fontSize: 14)),
          ],
        ),
      ),
    ),
  );
}

class _PageHeader extends StatelessWidget {
  const _PageHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 5),
      Text(
        subtitle,
        style: const TextStyle(fontSize: 13, color: Color(0xff666666)),
      ),
    ],
  );
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.title,
    required this.subtitle,
    required this.control,
  });

  final String title;
  final String subtitle;
  final Widget control;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minHeight: 76),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: Color(0xffd6d6d6))),
    ),
    child: Row(
      children: [
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 14)),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: const TextStyle(fontSize: 12, color: Color(0xff666666)),
              ),
            ],
          ),
        ),
        const SizedBox(width: 24),
        control,
      ],
    ),
  );
}

class TodoEntry {
  const TodoEntry({required this.id, required this.title});

  final int id;
  final String title;

  factory TodoEntry.fromJson(Map<String, dynamic> json) =>
      TodoEntry(id: json['id'] as int, title: json['title'] as String);

  Map<String, Object> toJson() => {'id': id, 'title': title};
}

class _PanelData {
  const _PanelData({
    required this.todos,
    required this.launchAtStartup,
    required this.exitTrayOnPetExit,
    required this.skipTodoDeleteConfirmation,
  });

  const _PanelData.defaults()
    : todos = const [],
      launchAtStartup = false,
      exitTrayOnPetExit = true,
      skipTodoDeleteConfirmation = false;

  final List<TodoEntry> todos;
  final bool launchAtStartup;
  final bool exitTrayOnPetExit;
  final bool skipTodoDeleteConfirmation;
}

class _PanelDataStore {
  static File get _file {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    final base = localAppData == null || localAppData.isEmpty
        ? Directory.systemTemp.path
        : localAppData;
    return File('$base\\Remielle\\control_panel.json');
  }

  static Future<_PanelData> load() async {
    if (_isFlutterTest) return const _PanelData.defaults();
    try {
      if (!await _file.exists()) return const _PanelData.defaults();
      final json =
          jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      final todosJson = json['todos'] as List<dynamic>? ?? const [];
      return _PanelData(
        todos: todosJson
            .map((item) => TodoEntry.fromJson(item as Map<String, dynamic>))
            .toList(),
        launchAtStartup: json['launchAtStartup'] as bool? ?? false,
        exitTrayOnPetExit:
            json['exitTrayOnPetExit'] as bool? ??
            json['exitTrayOnClose'] as bool? ??
            true,
        skipTodoDeleteConfirmation:
            json['skipTodoDeleteConfirmation'] as bool? ?? false,
      );
    } catch (_) {
      return const _PanelData.defaults();
    }
  }

  static Future<void> save(_PanelData data) async {
    if (_isFlutterTest) return;
    await _file.parent.create(recursive: true);
    await _file.writeAsString(
      jsonEncode({
        'todos': data.todos.map((todo) => todo.toJson()).toList(),
        'launchAtStartup': data.launchAtStartup,
        'exitTrayOnPetExit': data.exitTrayOnPetExit,
        'skipTodoDeleteConfirmation': data.skipTodoDeleteConfirmation,
      }),
      flush: true,
    );
  }
}

class _WindowsStartup {
  static const _registryKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const _valueName = 'Remielle';

  static Future<void> setEnabled(bool enabled) async {
    if (_isFlutterTest) return;
    if (!Platform.isWindows) {
      throw UnsupportedError('Windows startup is only supported on Windows.');
    }
    final arguments = enabled
        ? [
            'add',
            _registryKey,
            '/v',
            _valueName,
            '/t',
            'REG_SZ',
            '/d',
            '"${Platform.resolvedExecutable}"',
            '/f',
          ]
        : ['delete', _registryKey, '/v', _valueName, '/f'];
    final result = await Process.run('reg.exe', arguments);
    if (result.exitCode != 0) {
      throw ProcessException('reg.exe', arguments, result.stderr.toString());
    }
  }
}

bool get _isFlutterTest => Platform.environment.containsKey('FLUTTER_TEST');
