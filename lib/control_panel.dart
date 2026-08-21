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

enum _PanelSection { todo, settings, help }

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
  bool _bubbleVisibleByDefault = true;
  bool _autoUpdate = false;
  bool _checkingForUpdate = false;
  bool _updatingStartup = false;
  bool _closing = false;
  bool _inputSessionActive = false;
  int? _hoveredTodoId;
  int? _editingTodoId;
  StreamSubscription<FileSystemEvent>? _todoFileWatcher;
  Timer? _todoRefreshDebounce;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _todoFocusNode.addListener(_onInputFocusChanged);
    _editFocusNode.addListener(_onInputFocusChanged);
    _initializePanel();
    _initializeTodoWatcher();
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
      _bubbleVisibleByDefault = data.bubbleVisibleByDefault;
      _autoUpdate = data.autoUpdate;
    });
  }

  @override
  void dispose() {
    _todoFileWatcher?.cancel();
    _todoRefreshDebounce?.cancel();
    windowManager.removeListener(this);
    _todoFocusNode.removeListener(_onInputFocusChanged);
    _editFocusNode.removeListener(_onInputFocusChanged);
    _todoFocusNode.dispose();
    _editFocusNode.dispose();
    _todoController.dispose();
    _editController.dispose();
    super.dispose();
  }

  Future<void> _initializeTodoWatcher() async {
    if (_isFlutterTest) return;
    final file = _PanelDataStore._file;
    await file.parent.create(recursive: true);
    _todoFileWatcher = file.parent.watch().listen((event) {
      if (!event.path.toLowerCase().endsWith('control_panel.json')) return;
      _todoRefreshDebounce?.cancel();
      _todoRefreshDebounce = Timer(
        const Duration(milliseconds: 120),
        _refreshTodosFromDisk,
      );
    });
  }

  Future<void> _refreshTodosFromDisk() async {
    final data = await _PanelDataStore.load();
    if (!mounted || _editingTodoId != null) return;
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
    });
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
      _todos.add(
        TodoEntry(id: _nextTodoId++, title: value, createdAt: DateTime.now()),
      );
      _todoController.clear();
    });
    _endInputSession();
    FocusManager.instance.primaryFocus?.unfocus();
    _savePanelData();
  }

  Future<void> _completeTodo(TodoEntry todo) async {
    if (_editingTodoId == todo.id) _cancelEditing();
    final index = _todos.indexWhere((item) => item.id == todo.id);
    if (index < 0) return;
    setState(() {
      _todos[index] = todo.copyWith(completedAt: DateTime.now());
    });
    await _savePanelData();
    await _sendPetEvent('todoDone');
  }

  Future<void> _restoreTodo(TodoEntry todo) async {
    final index = _todos.indexWhere((item) => item.id == todo.id);
    if (index < 0) return;
    setState(() {
      _todos[index] = todo.copyWith(
        createdAt: DateTime.now(),
        clearCompletedAt: true,
      );
    });
    await _savePanelData();
  }

  Future<void> _dropTodo(
    TodoEntry dragged,
    DateTime day,
    bool completed, {
    TodoEntry? before,
    TodoEntry? after,
  }) async {
    if (!_todos.any((todo) => todo.id == dragged.id)) return;
    final targetDay = _startOfDay(day);
    final targetItems =
        _todos
            .where(
              (todo) =>
                  (todo.completedAt != null) == completed &&
                  _isSameDay(todo.createdAt, targetDay) &&
                  todo.id != dragged.id,
            )
            .toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    var insertIndex = targetItems.length;
    if (before != null) {
      final index = targetItems.indexWhere((todo) => todo.id == before.id);
      if (index >= 0) {
        insertIndex = index;
      }
    } else if (after != null) {
      final index = targetItems.indexWhere((todo) => todo.id == after.id);
      if (index >= 0) insertIndex = index + 1;
    }
    final reordered = List<TodoEntry>.of(targetItems)
      ..insert(
        insertIndex,
        dragged.copyWith(
          completedAt: completed
              ? (dragged.completedAt ?? DateTime.now())
              : null,
          clearCompletedAt: !completed,
        ),
      );
    final updates = <int, TodoEntry>{};
    for (var i = 0; i < reordered.length; i++) {
      updates[reordered[i].id] = reordered[i].copyWith(
        createdAt: targetDay.add(Duration(hours: 12, minutes: i)),
      );
    }
    setState(() {
      for (var i = 0; i < _todos.length; i++) {
        _todos[i] = updates[_todos[i].id] ?? _todos[i];
      }
    });
    await _savePanelData();
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
        _todos[index] = _todos[index].copyWith(title: value);
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
      items: [
        if (todo.completedAt == null)
          const PopupMenuItem(value: 'edit', height: 36, child: Text('编辑')),
        const PopupMenuItem(value: 'delete', height: 36, child: Text('删除')),
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
      bubbleVisibleByDefault: _bubbleVisibleByDefault,
      autoUpdate: _autoUpdate,
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

  Future<void> _setBubbleVisibleByDefault(bool value) async {
    setState(() => _bubbleVisibleByDefault = value);
    await _savePanelData();
  }

  Future<void> _setAutoUpdate(bool value) async {
    setState(() => _autoUpdate = value);
    await _savePanelData();
  }

  Future<void> _checkForUpdateManually() async {
    if (_checkingForUpdate) return;
    setState(() => _checkingForUpdate = true);
    final update = await _UpdateService.check(ignoreSameVersionMarker: true);
    if (!mounted) return;
    setState(() => _checkingForUpdate = false);
    if (update == null) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('软件更新'),
          content: const Text('当前版本 v$_remielleVersion 已是最新版本。'),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('确定'),
            ),
          ],
        ),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('发现新版本 v${update.version}'),
        content: const Text('是否立即下载并安装更新？安装完成后软件将自动重启。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('暂不更新'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('立即更新'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final progress = ValueNotifier<double>(0);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: Text('正在更新至 v${update.version}'),
          content: ValueListenableBuilder<double>(
            valueListenable: progress,
            builder: (context, value, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('下载中 ${(value * 100).round()}%'),
                const SizedBox(height: 12),
                LinearProgressIndicator(value: value),
              ],
            ),
          ),
        ),
      ),
    );
    try {
      final archive = await _UpdateService.download(
        update,
        (value) => progress.value = value.clamp(0, 1),
      );
      if (_UpdateService._isSameVersion(update.version)) {
        await _UpdateService.markSameVersionUpdate();
      }
      await _UpdateService.launchUpdater(archive);
      progress.dispose();
      exit(0);
    } catch (error) {
      progress.dispose();
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('更新失败'),
          content: Text('无法完成更新：$error'),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('确定'),
            ),
          ],
        ),
      );
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
    final latest = await _PanelDataStore.load();
    if (mounted) {
      setState(() {
        _todos
          ..clear()
          ..addAll(latest.todos);
      });
    }
    await _savePanelData();
    if (!_isFlutterTest) {
      await _sendPetEvent('panelClosed');
      await windowManager.destroy();
      exit(0);
    }
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
          child: switch (_section) {
            _PanelSection.todo => _buildTodoPage(),
            _PanelSection.settings => _buildSettingsPage(),
            _PanelSection.help => _buildHelpPage(),
          },
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
          const _PageHeader(title: '今日待办', subtitle: '记录今天需要完成的事项'),
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
          const SizedBox(height: 20),
          Expanded(child: _buildTodoArchiveList()),
        ],
      ),
    ),
  );

  Widget _buildTodoArchiveList() {
    final today = _startOfDay(DateTime.now());
    final groups = <DateTime, List<TodoEntry>>{};
    for (final todo in _todos.where((todo) => todo.completedAt == null)) {
      final day = _startOfDay(todo.createdAt);
      (groups[day] ??= <TodoEntry>[]).add(todo);
    }
    groups.putIfAbsent(today, () => <TodoEntry>[]);
    final days = groups.keys.toList()..sort((a, b) => b.compareTo(a));
    final children = <Widget>[];
    for (var i = 0; i < days.length; i++) {
      final day = days[i];
      final todos = groups[day]!
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      children.add(
        _buildTodoDropHeader(
          _todoDayLabel(day, today),
          todos.length,
          day: day,
          completed: false,
        ),
      );
      if (todos.isEmpty) {
        children.add(const _TodoEmptyState('今天还没有待办事项'));
      } else {
        children.addAll(
          _withDividers(
            todos.map(
              (todo) =>
                  _buildTodoRow(todo, completed: todo.completedAt != null),
            ),
          ),
        );
      }
      if (i < days.length - 1) children.add(const SizedBox(height: 24));
    }
    final completedTodos =
        _todos.where((todo) => todo.completedAt != null).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final completed = completedTodos.length;
    children
      ..add(const SizedBox(height: 24))
      ..add(_buildTodoSectionHeader('已完成', completed));
    if (completed > 0) {
      final completedGroups = <DateTime, List<TodoEntry>>{};
      for (final todo in completedTodos) {
        final day = _startOfDay(todo.createdAt);
        (completedGroups[day] ??= <TodoEntry>[]).add(todo);
      }
      final completedDays = completedGroups.keys.toList()
        ..sort((a, b) => b.compareTo(a));
      for (final day in completedDays) {
        final todos = completedGroups[day]!
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
        children
          ..add(_buildArchiveDayHeader(_formatTodoDate(day)))
          ..addAll(
            _withDividers(
              todos.map((todo) => _buildTodoRow(todo, completed: true)),
            ),
          );
      }
    }
    if (completed == 0) {
      children.add(
        DragTarget<TodoEntry>(
          onAcceptWithDetails: (details) =>
              _dropTodo(details.data, today, true),
          builder: (context, candidates, rejected) => SizedBox(
            height: 16,
            width: double.infinity,
            child: candidates.isEmpty
                ? null
                : const ColoredBox(color: Color(0x220067c0)),
          ),
        ),
      );
      children.add(const _TodoEmptyState('完成的 Todo 会自动归档到这里'));
    }
    return ListView(padding: EdgeInsets.zero, children: children);
  }

  // ignore: unused_element
  Widget _buildTodoList() {
    final now = DateTime.now();
    final todayTodos =
        _todos
            .where(
              (todo) =>
                  todo.completedAt == null && _isSameDay(todo.createdAt, now),
            )
            .toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final completedTodos =
        _todos.where((todo) => todo.completedAt != null).toList()
          ..sort((a, b) => b.completedAt!.compareTo(a.completedAt!));

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        _buildTodoSectionHeader('当天加入', todayTodos.length),
        if (todayTodos.isEmpty)
          const _TodoEmptyState('今天还没有待办事项')
        else
          ..._withDividers(todayTodos.map((todo) => _buildTodoRow(todo))),
        const SizedBox(height: 24),
        _buildTodoSectionHeader('已完成', completedTodos.length),
        if (completedTodos.isEmpty)
          const _TodoEmptyState('完成的 Todo 会自动归档到这里')
        else
          ..._withDividers(
            completedTodos.map((todo) => _buildTodoRow(todo, completed: true)),
          ),
      ],
    );
  }

  Widget _buildTodoSectionHeader(String title, int count) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 8),
          Text(
            '$count',
            style: const TextStyle(color: Color(0xff666666), fontSize: 12),
          ),
        ],
      ),
      const SizedBox(height: 8),
      const Divider(height: 1, color: Color(0xffcfcfcf)),
    ],
  );

  Widget _buildTodoDropHeader(
    String title,
    int count, {
    required DateTime day,
    required bool completed,
  }) => DragTarget<TodoEntry>(
    onAcceptWithDetails: (details) => _dropTodo(details.data, day, completed),
    builder: (context, candidates, rejected) =>
        _buildTodoSectionHeader(title, count),
  );

  List<Widget> _withDividers(Iterable<Widget> rows) {
    final result = <Widget>[];
    for (final row in rows) {
      if (result.isNotEmpty) {
        result.add(const Divider(height: 1, color: Color(0xffdedede)));
      }
      result.add(row);
    }
    return result;
  }

  Widget _buildArchiveDayHeader(String label) => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 6),
    child: Text(
      label,
      style: const TextStyle(
        color: Color(0xff666666),
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _buildTodoRow(TodoEntry todo, {bool completed = false}) => Column(
    children: [
      DragTarget<TodoEntry>(
        onWillAcceptWithDetails: (details) => details.data.id != todo.id,
        onAcceptWithDetails: (details) => _dropTodo(
          details.data,
          _startOfDay(todo.createdAt),
          completed,
          before: todo,
        ),
        builder: (context, candidates, rejected) => SizedBox(
          height: 10,
          width: double.infinity,
          child: candidates.isEmpty
              ? null
              : const ColoredBox(color: Color(0x220067c0)),
        ),
      ),
      LongPressDraggable<TodoEntry>(
        data: todo,
        delay: const Duration(milliseconds: 180),
        feedback: Material(
          color: Colors.transparent,
          child: _todoDragFeedback(todo, completed),
        ),
        childWhenDragging: Opacity(
          opacity: 0.35,
          child: _buildTodoRowBody(todo, completed: completed),
        ),
        child: DragTarget<TodoEntry>(
          onWillAcceptWithDetails: (details) => details.data.id != todo.id,
          onAcceptWithDetails: (details) => _dropTodo(
            details.data,
            _startOfDay(todo.createdAt),
            completed,
            before: todo,
          ),
          builder: (context, candidates, rejected) =>
              _buildTodoRowBody(todo, completed: completed),
        ),
      ),
      DragTarget<TodoEntry>(
        onWillAcceptWithDetails: (details) => details.data.id != todo.id,
        onAcceptWithDetails: (details) => _dropTodo(
          details.data,
          _startOfDay(todo.createdAt),
          completed,
          after: todo,
        ),
        builder: (context, candidates, rejected) => SizedBox(
          height: 10,
          width: double.infinity,
          child: candidates.isEmpty
              ? null
              : const ColoredBox(color: Color(0x220067c0)),
        ),
      ),
    ],
  );

  Widget _buildTodoRowBody(TodoEntry todo, {required bool completed}) =>
      MouseRegion(
        key: ValueKey('todo-row-${todo.id}'),
        cursor: SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hoveredTodoId = todo.id),
        onExit: (_) {
          if (_hoveredTodoId == todo.id) setState(() => _hoveredTodoId = null);
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
            constraints: const BoxConstraints(minHeight: 52),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Checkbox(
                  key: ValueKey('todo-checkbox-${todo.id}'),
                  value: completed,
                  onChanged: (_) =>
                      completed ? _restoreTodo(todo) : _completeTodo(todo),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (!completed && _editingTodoId == todo.id)
                          TextField(
                            key: ValueKey('edit-todo-input-${todo.id}'),
                            controller: _editController,
                            focusNode: _editFocusNode,
                            style: const TextStyle(fontSize: 14),
                            decoration: const InputDecoration(
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                            ),
                            textInputAction: TextInputAction.done,
                            minLines: 1,
                            maxLines: null,
                            onSubmitted: (_) => _finishEditing(),
                          )
                        else
                          GestureDetector(
                            key: ValueKey('todo-title-${todo.id}'),
                            behavior: HitTestBehavior.opaque,
                            onTap: completed ? null : () => _startEditing(todo),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                todo.title,
                                softWrap: true,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: completed
                                      ? const Color(0xff666666)
                                      : const Color(0xff1a1a1a),
                                  decoration: completed
                                      ? TextDecoration.lineThrough
                                      : TextDecoration.none,
                                ),
                              ),
                            ),
                          ),
                        Text(
                          _formatTodoCreatedDate(todo.createdAt),
                          key: ValueKey('todo-created-date-${todo.id}'),
                          style: const TextStyle(
                            color: Color(0xff888888),
                            fontSize: 10,
                          ),
                        ),
                      ],
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

  Widget _todoDragFeedback(TodoEntry todo, bool completed) => Container(
    width: 420,
    height: 52,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    color: const Color(0xffe9e9e9),
    alignment: Alignment.centerLeft,
    child: Text(
      todo.title,
      style: TextStyle(
        fontSize: 14,
        color: completed ? const Color(0xff777777) : const Color(0xff1a1a1a),
      ),
    ),
  );

  Widget _buildSettingsPage() => Padding(
    padding: const EdgeInsets.fromLTRB(36, 30, 36, 28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _PageHeader(title: '设置', subtitle: '系统设置'),
        const SizedBox(height: 28),
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
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
                title: '自动更新',
                subtitle: '发现新版本后自动下载并安装，不再询问',
                control: Switch(
                  key: const ValueKey('auto-update-switch'),
                  value: _autoUpdate,
                  onChanged: _setAutoUpdate,
                ),
              ),
              _SettingRow(
                title: '软件更新',
                subtitle: '当前版本 v$_remielleVersion，手动检查 GitHub 最新版本',
                control: OutlinedButton.icon(
                  key: const ValueKey('check-update-button'),
                  onPressed: _checkingForUpdate
                      ? null
                      : _checkForUpdateManually,
                  icon: _checkingForUpdate
                      ? const SizedBox.square(
                          dimension: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 16),
                  label: const Text('检查更新'),
                ),
              ),
              _SettingRow(
                title: '启动时显示待办气泡',
                subtitle: '桌宠启动时默认显示 Todo 气泡',
                control: Switch(
                  key: const ValueKey('bubble-default-switch'),
                  value: _bubbleVisibleByDefault,
                  onChanged: _setBubbleVisibleByDefault,
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
        ),
      ],
    ),
  );

  Future<void> _openGitHubRepository() async {
    const url = 'https://github.com/KawaiTsui/Remielle';
    try {
      if (!Platform.isWindows) return;
      await Process.start('explorer.exe', [
        url,
      ], mode: ProcessStartMode.detached);
    } on ProcessException {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法打开 GitHub 仓库。')));
    }
  }

  Widget _buildHelpPage() => Padding(
    key: const ValueKey('help-page'),
    padding: const EdgeInsets.fromLTRB(36, 30, 36, 28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _PageHeader(title: '使用说明', subtitle: 'Remielle 操作指南'),
        const SizedBox(height: 24),
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              const _HelpSection(
                icon: Icons.touch_app_outlined,
                title: '桌宠操作',
                items: [
                  '按住桌宠并拖动，可以移动桌宠窗口。',
                  '按住 Ctrl 后在桌宠上长按鼠标左键并上下拖动，可以在 50% 至 200% 之间等比缩放。',
                  '右键桌宠可打开菜单，使用控制面板、鼠标穿透、置顶、恢复 100% 大小和退出功能。',
                ],
              ),
              const _HelpSection(
                icon: Icons.chat_bubble_outline,
                title: '气泡窗口',
                items: [
                  '在底部输入内容后按 Enter、点击加号或点击气泡空白处，即可添加 Todo。',
                  '点击圆形勾选框可切换完成状态；已完成的 Todo 会自动排列到底部。',
                  '长按 Todo 并拖到目标条目的上方或下方，可以调整排序。',
                  '点击 Todo 文字可以编辑；右键 Todo 可以打开更多操作。',
                  '拖动气泡窗口上边缘或上方两角可以调整高度；位置和大小会在退出时保存。',
                ],
              ),
              const _HelpSection(
                icon: Icons.view_list_outlined,
                title: '控制面板',
                items: [
                  'Todo 页可添加、编辑、完成、恢复或删除事项，长内容会自动换行。',
                  '长按并拖动 Todo，可以调整顺序，也可以跨日期或在未完成与已完成区域之间移动。',
                  '设置页可管理开机启动、默认显示气泡、退出行为和删除确认。',
                ],
              ),
              const Divider(height: 32, color: Color(0xffd6d6d6)),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('github-repository-link'),
                  onPressed: _openGitHubRepository,
                  icon: const Icon(Icons.open_in_new, size: 17),
                  label: const Text('GitHub：KawaiTsui/Remielle'),
                ),
              ),
            ],
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
            const SizedBox(height: 4),
            _NavigationItem(
              key: const ValueKey('help-tab'),
              icon: Icons.help_outline,
              label: '使用说明',
              selected: selected == _PanelSection.help,
              onTap: () => onSelected(_PanelSection.help),
            ),
          ],
        ),
      ),
    ),
  );
}

class _HelpSection extends StatelessWidget {
  const _HelpSection({
    required this.icon,
    required this.title,
    required this.items,
  });

  final IconData icon;
  final String title;
  final List<String> items;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 22),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 20, color: const Color(0xff0067c0)),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              for (final item in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 7),
                        child: SizedBox.square(
                          dimension: 4,
                          child: ColoredBox(color: Color(0xff737373)),
                        ),
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          item,
                          style: const TextStyle(
                            height: 1.45,
                            fontSize: 13,
                            color: Color(0xff4f4f4f),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
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
  const TodoEntry({
    required this.id,
    required this.title,
    required this.createdAt,
    this.completedAt,
  });

  final int id;
  final String title;
  final DateTime createdAt;
  final DateTime? completedAt;

  TodoEntry copyWith({
    String? title,
    DateTime? createdAt,
    DateTime? completedAt,
    bool clearCompletedAt = false,
  }) => TodoEntry(
    id: id,
    title: title ?? this.title,
    createdAt: createdAt ?? this.createdAt,
    completedAt: clearCompletedAt ? null : completedAt ?? this.completedAt,
  );

  factory TodoEntry.fromJson(Map<String, dynamic> json) {
    final createdAt = DateTime.tryParse(json['createdAt'] as String? ?? '');
    final completedAt = DateTime.tryParse(json['completedAt'] as String? ?? '');
    return TodoEntry(
      id: json['id'] as int,
      title: json['title'] as String,
      createdAt: createdAt ?? DateTime.now(),
      completedAt: completedAt,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'createdAt': createdAt.toIso8601String(),
    'completedAt': completedAt?.toIso8601String(),
  };
}

bool _isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

DateTime _startOfDay(DateTime value) =>
    DateTime(value.year, value.month, value.day);

String _todoDayLabel(DateTime day, DateTime today) {
  final difference = today.difference(day).inDays;
  if (difference == 0) return '当天加入';
  if (difference == 1) return '昨日待办';
  return '${day.year}/${day.month}/${day.day}';
}

String _formatTodoCreatedDate(DateTime value) {
  return _formatTodoDate(value);
}

String _formatTodoDate(DateTime value) {
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  return '${value.year}/$month/$day';
}

class _TodoEmptyState extends StatelessWidget {
  const _TodoEmptyState(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 18, bottom: 4),
    child: Text(
      message,
      style: const TextStyle(color: Color(0xff666666), fontSize: 13),
    ),
  );
}

class _PanelData {
  const _PanelData({
    required this.todos,
    required this.launchAtStartup,
    required this.exitTrayOnPetExit,
    required this.skipTodoDeleteConfirmation,
    required this.bubbleVisibleByDefault,
    required this.autoUpdate,
  });

  const _PanelData.defaults()
    : todos = const [],
      launchAtStartup = false,
      exitTrayOnPetExit = true,
      skipTodoDeleteConfirmation = false,
      bubbleVisibleByDefault = true,
      autoUpdate = false;

  final List<TodoEntry> todos;
  final bool launchAtStartup;
  final bool exitTrayOnPetExit;
  final bool skipTodoDeleteConfirmation;
  final bool bubbleVisibleByDefault;
  final bool autoUpdate;
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
      final cutoff = _startOfDay(
        DateTime.now(),
      ).subtract(const Duration(days: 6));
      final todos = todosJson
          .map((item) => TodoEntry.fromJson(item as Map<String, dynamic>))
          .where((todo) => !_startOfDay(todo.createdAt).isBefore(cutoff))
          .toList();
      final data = _PanelData(
        todos: todos,
        launchAtStartup: json['launchAtStartup'] as bool? ?? false,
        exitTrayOnPetExit:
            json['exitTrayOnPetExit'] as bool? ??
            json['exitTrayOnClose'] as bool? ??
            true,
        skipTodoDeleteConfirmation:
            json['skipTodoDeleteConfirmation'] as bool? ?? false,
        bubbleVisibleByDefault: json['bubbleVisibleByDefault'] as bool? ?? true,
        autoUpdate: json['autoUpdate'] as bool? ?? false,
      );
      if (todos.length != todosJson.length) await save(data);
      return data;
    } catch (_) {
      return const _PanelData.defaults();
    }
  }

  static Future<void> save(_PanelData data) async {
    if (_isFlutterTest) return;
    final cutoff = _startOfDay(
      DateTime.now(),
    ).subtract(const Duration(days: 6));
    final todos = data.todos
        .where((todo) => !_startOfDay(todo.createdAt).isBefore(cutoff))
        .toList(growable: false);
    await _file.parent.create(recursive: true);
    await _file.writeAsString(
      jsonEncode({
        'todos': todos.map((todo) => todo.toJson()).toList(),
        'launchAtStartup': data.launchAtStartup,
        'exitTrayOnPetExit': data.exitTrayOnPetExit,
        'skipTodoDeleteConfirmation': data.skipTodoDeleteConfirmation,
        'bubbleVisibleByDefault': data.bubbleVisibleByDefault,
        'autoUpdate': data.autoUpdate,
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
