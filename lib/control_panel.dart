part of 'main.dart';

ThemeData _controlPanelTheme() {
  const accent = Color(0xff0078d4);
  const foreground = Color(0xff111827);
  final base = ThemeData(
    useMaterial3: true,
    fontFamily: 'Microsoft YaHei',
    scaffoldBackgroundColor: Colors.white,
    colorScheme: const ColorScheme.light(
      primary: accent,
      onPrimary: Colors.white,
      surface: Colors.white,
      onSurface: foreground,
      outline: Color(0xffe5e7eb),
    ),
  );
  return base.copyWith(
    splashFactory: NoSplash.splashFactory,
    hoverColor: const Color(0xfff3f4f6),
    focusColor: const Color(0xffeff6ff),
    dialogTheme: const DialogThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(side: BorderSide(color: Color(0xffe5e7eb))),
    ),
    textTheme: base.textTheme.apply(
      fontFamily: 'Microsoft YaHei',
      bodyColor: foreground,
      displayColor: foreground,
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
        borderSide: BorderSide(color: Color(0xffe5e7eb)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
        borderSide: BorderSide(color: accent, width: 1.5),
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      side: WidgetStateBorderSide.resolveWith((states) {
        if (states.contains(WidgetState.hovered)) {
          return const BorderSide(color: Color(0xff111111), width: 1);
        }
        if (states.contains(WidgetState.selected)) {
          return const BorderSide(color: Color(0xff0078d4), width: 1.5);
        }
        return const BorderSide(color: Color(0xffd1d5db), width: 1);
      }),
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? const Color(0xff0078d4)
            : Colors.transparent,
      ),
    ),
    switchTheme: const SwitchThemeData(
      overlayColor: WidgetStatePropertyAll(Colors.transparent),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.all(const Color(0xffcbd5e1)),
      thickness: WidgetStateProperty.all(5),
      radius: const Radius.circular(3),
      crossAxisMargin: 0,
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
  final _todoScrollController = ScrollController();
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
  final Set<DateTime> _expandedArchiveDays = <DateTime>{};
  final Set<DateTime> _expandedIncompleteArchiveDays = <DateTime>{};
  StreamSubscription<FileSystemEvent>? _todoFileWatcher;
  Timer? _todoRefreshDebounce;
  Timer? _midnightArchiveRefreshTimer;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _todoFocusNode.addListener(_onInputFocusChanged);
    _editFocusNode.addListener(_onInputFocusChanged);
    _initializePanel();
    _initializeTodoWatcher();
    _scheduleMidnightArchiveRefresh();
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
    _midnightArchiveRefreshTimer?.cancel();
    windowManager.removeListener(this);
    _todoFocusNode.removeListener(_onInputFocusChanged);
    _editFocusNode.removeListener(_onInputFocusChanged);
    _todoFocusNode.dispose();
    _editFocusNode.dispose();
    _todoController.dispose();
    _editController.dispose();
    _todoScrollController.dispose();
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

  void _scheduleMidnightArchiveRefresh() {
    _midnightArchiveRefreshTimer?.cancel();
    _midnightArchiveRefreshTimer = Timer(
      _timeUntilNextMidnight(DateTime.now()),
      () {
        if (mounted) setState(() {});
        _scheduleMidnightArchiveRefresh();
      },
    );
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
    _endInputSession();
    FocusManager.instance.primaryFocus?.unfocus();
    if (value.isEmpty) return;
    setState(() {
      _todos.add(
        TodoEntry(id: _nextTodoId++, title: value, createdAt: DateTime.now()),
      );
      _todoController.clear();
    });
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
    await _sendPetEvent(
      _todayTodosAreCompleted(_todos) ? 'allTodosCompleted' : 'todoDone',
    );
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
        builder: (context) => _DeleteTodoDialog(
          title: todo.title,
          confirmKey: const ValueKey('confirm-delete-todo'),
          accentColor: const Color(0xff0078d4),
          onCancelled: () => Navigator.of(context).pop(false),
          onConfirmed: () => Navigator.of(context).pop(true),
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    if (_editingTodoId == todo.id) _cancelEditing();
    final deletingIncomplete = todo.completedAt == null;
    setState(() => _todos.removeWhere((item) => item.id == todo.id));
    await _savePanelData();
    if (deletingIncomplete && _allTodosAreCompleted(_todos)) {
      await _sendPetEvent('allTodosCompleted');
    }
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
    final update = await _UpdateService.check();
    if (!mounted) return;
    setState(() => _checkingForUpdate = false);
    if (update == null) {
      await showDialog<void>(
        context: context,
        builder: (context) => _UpdateDialog(
          message: '当前版本 v$_remielleVersion 已是最新版本。',
          primaryLabel: '确定',
          onPrimary: () => Navigator.pop(context),
        ),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _UpdateDialog(
        message: '发现新版本 v${update.version}，是否立即下载并更新？',
        primaryLabel: '立即更新',
        secondaryLabel: '暂不更新',
        onPrimary: () => Navigator.pop(context, true),
        onSecondary: () => Navigator.pop(context, false),
      ),
    );
    if (confirmed != true || !mounted) return;

    // The desktop pet owns the single download task and its progress UI.
    try {
      await _UpdateService.requestFromControlPanel(update);
      exit(0);
    } catch (error) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => _UpdateDialog(
          title: '更新失败',
          message: '无法开始更新：$error',
          primaryLabel: '确定',
          onPrimary: () => Navigator.pop(context),
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
        const VerticalDivider(width: 1, thickness: 1, color: Color(0xffe5e7eb)),
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
      padding: const EdgeInsets.fromLTRB(40, 36, 32, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _PageHeader(title: '待办清单', subtitle: ''),
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
                    backgroundColor: const Color(0xff0078d4),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(8)),
                    ),
                  ),
                  onPressed: _addTodo,
                  icon: const Icon(Icons.add, size: 19),
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
    final todayTodos =
        _todos
            .where(
              (todo) =>
                  todo.completedAt == null && _isSameDay(todo.createdAt, today),
            )
            .toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final children = <Widget>[_buildTodoSectionHeader('今日待办')];
    children.add(
      _buildTodoDateDropHeader(
        _formatTodoDate(today),
        todayTodos.length,
        day: today,
        completed: false,
      ),
    );
    if (todayTodos.isEmpty) {
      children.add(const _TodoEmptyState('今天还没有待办事项'));
    } else {
      children.addAll(
        todayTodos.map(
          (todo) => _buildTodoRow(todo, completed: false, compact: true),
        ),
      );
    }

    children
      ..add(const SizedBox(height: 24))
      ..add(_buildTodoSectionHeader('未完成'));
    final incompleteGroups = _groupTodosByCreatedDay(
      _todos.where(
        (todo) =>
            todo.completedAt == null && !_isSameDay(todo.createdAt, today),
      ),
    );
    _addArchiveGroups(
      children,
      incompleteGroups,
      completed: false,
      expandedDays: _expandedIncompleteArchiveDays,
    );
    if (incompleteGroups.isEmpty) {
      children.add(const _TodoEmptyState('没有未完成的历史待办'));
    }

    final completedGroups = _groupTodosByCreatedDay(
      _todos.where((todo) => todo.completedAt != null),
    );
    children
      ..add(const SizedBox(height: 24))
      ..add(_buildTodoSectionHeader('已完成'));
    _addArchiveGroups(
      children,
      completedGroups,
      completed: true,
      expandedDays: _expandedArchiveDays,
    );
    if (completedGroups.isEmpty) {
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
    return Scrollbar(
      controller: _todoScrollController,
      thickness: 5,
      radius: const Radius.circular(3),
      child: ListView(
        controller: _todoScrollController,
        padding: const EdgeInsets.only(right: 16),
        children: children,
      ),
    );
  }

  Map<DateTime, List<TodoEntry>> _groupTodosByCreatedDay(
    Iterable<TodoEntry> todos,
  ) {
    final groups = <DateTime, List<TodoEntry>>{};
    for (final todo in todos) {
      final day = _startOfDay(todo.createdAt);
      (groups[day] ??= <TodoEntry>[]).add(todo);
    }
    return groups;
  }

  void _addArchiveGroups(
    List<Widget> children,
    Map<DateTime, List<TodoEntry>> groups, {
    required bool completed,
    required Set<DateTime> expandedDays,
  }) {
    final days = groups.keys.toList()..sort((a, b) => b.compareTo(a));
    for (final day in days) {
      final todos = groups[day]!
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      final expanded = expandedDays.contains(day);
      children.add(
        _buildArchiveDayHeader(
          day,
          todos.length,
          completed: completed,
          expanded: expanded,
          onExpandedChanged: (value) => setState(() {
            value ? expandedDays.add(day) : expandedDays.remove(day);
          }),
        ),
      );
      if (expanded) {
        children.addAll(
          todos.map(
            (todo) => _buildTodoRow(todo, completed: completed, compact: true),
          ),
        );
      }
    }
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
        _buildTodoSectionHeader('今日待办'),
        if (todayTodos.isEmpty)
          const _TodoEmptyState('今天还没有待办事项')
        else
          ..._withDividers(todayTodos.map((todo) => _buildTodoRow(todo))),
        const SizedBox(height: 24),
        _buildTodoSectionHeader('已完成'),
        if (completedTodos.isEmpty)
          const _TodoEmptyState('完成的 Todo 会自动归档到这里')
        else
          ..._withDividers(
            completedTodos.map((todo) => _buildTodoRow(todo, completed: true)),
          ),
      ],
    );
  }

  Widget _buildTodoSectionHeader(String title) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      const Divider(height: 1, color: Color(0xffcfcfcf)),
    ],
  );

  Widget _buildTodoDateDropHeader(
    String title,
    int count, {
    required DateTime day,
    required bool completed,
  }) => DragTarget<TodoEntry>(
    onAcceptWithDetails: (details) => _dropTodo(details.data, day, completed),
    builder: (context, candidates, rejected) =>
        _buildTodoDateHeader(title, count, highlighted: candidates.isNotEmpty),
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

  Widget _buildTodoDateHeader(
    String label,
    int count, {
    bool highlighted = false,
  }) => Container(
    color: highlighted ? const Color(0x220067c0) : null,
    padding: const EdgeInsets.only(top: 10, bottom: 4),
    child: Row(
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Color(0xff666666),
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '$count',
          style: const TextStyle(color: Color(0xff888888), fontSize: 11),
        ),
      ],
    ),
  );

  Widget _buildArchiveDayHeader(
    DateTime day,
    int count, {
    required bool completed,
    required bool expanded,
    required ValueChanged<bool> onExpandedChanged,
  }) => DragTarget<TodoEntry>(
    onAcceptWithDetails: (details) => _dropTodo(details.data, day, completed),
    builder: (context, candidates, rejected) => InkWell(
      key: ValueKey(
        '${completed ? 'archive' : 'incomplete-archive'}-day-${_formatTodoDate(day)}',
      ),
      onTap: () => onExpandedChanged(!expanded),
      child: Container(
        color: candidates.isEmpty ? null : const Color(0x220067c0),
        padding: const EdgeInsets.only(top: 10, bottom: 5),
        child: Row(
          children: [
            Icon(
              expanded ? Icons.arrow_drop_down : Icons.arrow_right,
              size: 17,
              color: const Color(0xff666666),
            ),
            const SizedBox(width: 2),
            Text(
              _formatTodoDate(day),
              style: const TextStyle(
                color: Color(0xff666666),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '$count',
              style: const TextStyle(color: Color(0xff888888), fontSize: 11),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _buildTodoRow(
    TodoEntry todo, {
    bool completed = false,
    bool compact = false,
  }) => Column(
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
          height: compact ? 2 : 8,
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
          height: compact ? 2 : 8,
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
                ? const Color(0xfff3f4f6)
                : Colors.white,
            constraints: const BoxConstraints(minHeight: 44),
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
                    padding: const EdgeInsets.symmetric(vertical: 4),
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
                                vertical: 2,
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
                    icon: const Icon(Icons.remove, size: 16),
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
    padding: const EdgeInsets.fromLTRB(40, 36, 40, 32),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _PageHeader(title: '设置', subtitle: ''),
        const SizedBox(height: 28),
        Expanded(
          child: ListView.separated(
            padding: EdgeInsets.zero,
            itemCount: 6,
            separatorBuilder: (_, _) => const SizedBox(height: 4),
            itemBuilder: (context, index) => [
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
                title: '启动时显示待办气泡',
                subtitle: '桌宠启动时默认显示待办气泡',
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
                      : const Icon(Icons.refresh, size: 15),
                  label: const Text('检查更新'),
                ),
              ),
            ][index],
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
    padding: const EdgeInsets.fromLTRB(40, 36, 40, 32),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _PageHeader(title: '使用说明', subtitle: ''),
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
                  '点击日期前的三角可展开或收起当天的已完成事项。',
                  '设置页可管理开机启动、默认显示气泡、退出行为和删除确认。',
                ],
              ),
              const Divider(height: 32, color: Color(0xffe5e7eb)),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('github-repository-link'),
                  onPressed: _openGitHubRepository,
                  icon: const _GitHubIcon(
                    key: ValueKey('github-icon'),
                    size: 16,
                  ),
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
      color: const Color(0xfff3f4f6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 32, 0, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'Remielle',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: Color(0xff111827),
                ),
              ),
            ),
            const SizedBox(height: 24),
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
          child: Icon(icon, size: 19, color: const Color(0xff0078d4)),
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
    color: selected ? const Color(0xffeff6ff) : Colors.transparent,
    child: InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 40,
        child: Row(
          children: [
            SizedBox(
              width: 3,
              height: 40,
              child: ColoredBox(
                color: selected ? const Color(0xff0078d4) : Colors.transparent,
              ),
            ),
            const SizedBox(width: 21),
            Icon(
              icon,
              size: 17,
              color: selected
                  ? const Color(0xff0078d4)
                  : const Color(0xff4b5563),
            ),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected
                    ? const Color(0xff0078d4)
                    : const Color(0xff4b5563),
              ),
            ),
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
        style: const TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.w700,
          color: Color(0xff111827),
        ),
      ),
      if (subtitle.isNotEmpty) ...[
        const SizedBox(height: 5),
        Text(
          subtitle,
          style: const TextStyle(fontSize: 13, color: Color(0xff666666)),
        ),
      ],
    ],
  );
}

class _UpdateDialog extends StatelessWidget {
  const _UpdateDialog({
    this.title = '软件更新',
    required this.message,
    required this.primaryLabel,
    required this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
  });

  final String title;
  final String message;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    final hasSecondary = secondaryLabel != null && onSecondary != null;
    final primary = FilledButton(
      onPressed: onPrimary,
      style: FilledButton.styleFrom(
        minimumSize: Size(hasSecondary ? 0 : 76, 40),
        backgroundColor: const Color(0xff0078d4),
        foregroundColor: Colors.white,
        shape: const RoundedRectangleBorder(),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      child: Text(primaryLabel),
    );
    return Dialog(
      child: SizedBox(
        width: 340,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: Color(0xff111827),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                message,
                style: const TextStyle(
                  height: 1.5,
                  fontSize: 14,
                  color: Color(0xff4b5563),
                ),
              ),
              SizedBox(height: hasSecondary ? 24 : 20),
              if (hasSecondary)
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: onSecondary,
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(40),
                          foregroundColor: const Color(0xff4b5563),
                          side: const BorderSide(color: Color(0xffe5e7eb)),
                          shape: const RoundedRectangleBorder(),
                          textStyle: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        child: Text(secondaryLabel!),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: primary),
                  ],
                )
              else
                Align(alignment: Alignment.centerRight, child: primary),
            ],
          ),
        ),
      ),
    );
  }
}

class _GitHubIcon extends StatelessWidget {
  const _GitHubIcon({this.size = 16, super.key});

  final double size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: const _GitHubIconPainter());
}

class _GitHubIconPainter extends CustomPainter {
  const _GitHubIconPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(5.99959, 14.6672)
      ..lineTo(5.99959, 12.0003)
      ..cubicTo(5.95292, 11.587, 5.98625, 11.1669, 6.09959, 10.7669)
      ..cubicTo(6.21293, 10.3669, 6.40628, 9.99349, 6.66629, 9.6668)
      ..cubicTo(4.66618, 9.6668, 2.66607, 8.33336, 2.66607, 5.99984)
      ..cubicTo(2.61171, 5.1683, 2.84733, 4.34363, 3.33277, 3.66632)
      ..cubicTo(3.13276, 2.89959, 3.13276, 2.09953, 3.33277, 1.3328)
      ..cubicTo(3.33277, 1.3328, 3.99948, 1.3328, 5.33288, 2.33288)
      ..cubicTo(7.09298, 1.99952, 8.90642, 1.99952, 10.6665, 2.33288)
      ..cubicTo(11.9999, 1.3328, 12.6666, 1.3328, 12.6666, 1.3328)
      ..cubicTo(12.8533, 2.09953, 12.8533, 2.89959, 12.6666, 3.66632)
      ..cubicTo(13.1533, 4.34637, 13.3867, 5.16644, 13.3333, 5.99984)
      ..cubicTo(13.3333, 8.33336, 11.3332, 9.6668, 9.33311, 9.6668)
      ..cubicTo(9.85309, 10.3269, 10.0926, 11.1651, 9.99981, 12.0003)
      ..lineTo(9.99981, 14.6672)
      ..moveTo(5.99959, 12.0003)
      ..cubicTo(2.99275, 13.3338, 2.66621, 10.6669, 1.3328, 10.6669);
    canvas.save();
    canvas.scale(size.width / 16, size.height / 16);
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xff0078d4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..strokeCap = StrokeCap.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
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
    constraints: const BoxConstraints(minHeight: 54),
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Color(0xff111827),
                ),
              ),
              const SizedBox(height: 2),
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

bool _todayTodosAreCompleted(Iterable<TodoEntry> todos, [DateTime? now]) {
  final today = now ?? DateTime.now();
  final todayTodos = todos.where((todo) => _isSameDay(todo.createdAt, today));
  return todayTodos.isNotEmpty &&
      todayTodos.every((todo) => todo.completedAt != null);
}

bool _allTodosAreCompleted(Iterable<TodoEntry> todos) {
  final remainingTodos = todos.toList(growable: false);
  return remainingTodos.isNotEmpty &&
      remainingTodos.every((todo) => todo.completedAt != null);
}

Duration _timeUntilNextMidnight(DateTime now) {
  final nextMidnight = DateTime(now.year, now.month, now.day + 1);
  return nextMidnight.difference(now);
}

DateTime _startOfDay(DateTime value) =>
    DateTime(value.year, value.month, value.day);

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

class _DeleteTodoDialog extends StatelessWidget {
  const _DeleteTodoDialog({
    required this.title,
    required this.onCancelled,
    required this.onConfirmed,
    this.confirmKey,
    this.accentColor = const Color(0xffffb6c1),
  });

  final String title;
  final Key? confirmKey;
  final Color accentColor;
  final VoidCallback onCancelled;
  final VoidCallback onConfirmed;

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: Colors.white,
    surfaceTintColor: Colors.transparent,
    insetPadding: const EdgeInsets.symmetric(horizontal: 40),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(12)),
    ),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '删除 Todo',
              style: TextStyle(
                fontFamily: 'Microsoft YaHei',
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Color(0xff4a4a4a),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              '确定要删除“$title”吗？',
              style: const TextStyle(
                fontFamily: 'Microsoft YaHei',
                fontSize: 13,
                height: 1.4,
                color: Color(0xff4a4a4a),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: onCancelled,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: accentColor,
                      minimumSize: const Size.fromHeight(40),
                      side: BorderSide(color: accentColor, width: 1),
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.all(Radius.circular(8)),
                      ),
                      textStyle: const TextStyle(
                        fontFamily: 'Microsoft YaHei',
                        fontSize: 13,
                      ),
                    ),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    key: confirmKey,
                    onPressed: onConfirmed,
                    style: FilledButton.styleFrom(
                      backgroundColor: accentColor,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(40),
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.all(Radius.circular(8)),
                      ),
                      textStyle: const TextStyle(
                        fontFamily: 'Microsoft YaHei',
                        fontSize: 13,
                      ),
                    ),
                    child: const Text('删除'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
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
