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

enum _PanelSection { todo, allTasks, settings, help }

enum _TodoView { today, planned }

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
  _TodoView _todoView = _TodoView.today;
  int _nextTodoId = 1;
  bool _launchAtStartup = false;
  bool _exitTrayOnPetExit = true;
  bool _skipTodoDeleteConfirmation = false;
  bool _bubbleVisibleByDefault = true;
  bool _autoUpdate = false;
  TodoRecurrence _newTodoRecurrence = TodoRecurrence.none;
  int? _newTodoReminderOffsetMinutes;
  DateTime? _newTodoReminderAt;
  DateTime _newTodoDueAt = _defaultTodoDueDate(DateTime.now(), TodoRecurrence.none);
  bool _checkingForUpdate = false;
  bool _updatingStartup = false;
  bool _closing = false;
  bool _inputSessionActive = false;
  int? _hoveredTodoId;
  int? _editingTodoId;
  int? _addingSubtaskTodoId;
  String _pendingSubtaskTitle = '';
  final Set<int> _expandedSubtaskTodoIds = <int>{};
  final Set<DateTime> _expandedArchiveDays = <DateTime>{};
  final Set<DateTime> _expandedPlannedDays = <DateTime>{};
  StreamSubscription<FileSystemEvent>? _todoFileWatcher;
  Timer? _todoRefreshDebounce;
  Timer? _midnightArchiveRefreshTimer;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _todoFocusNode.addListener(_onInputFocusChanged);
    _todoController.addListener(_onTodoInputChanged);
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
    _todoController.removeListener(_onTodoInputChanged);
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
        unawaited(_refreshTodosFromDisk());
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

  void _onTodoInputChanged() {
    if (mounted) setState(() {});
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
        TodoEntry(
          id: _nextTodoId++,
          title: value,
          createdAt: DateTime.now(),
          dueAt: _newTodoDueAt,
          recurrence: _newTodoRecurrence,
          reminderEnabled: _newTodoReminderOffsetMinutes != null,
          reminderOffsetMinutes: _newTodoReminderOffsetMinutes,
          reminderAt: _newTodoReminderAt,
          recurrenceSeriesId: _newTodoRecurrence == TodoRecurrence.none
              ? null
              : _nextTodoId.toString(),
        ),
      );
      _todoController.clear();
      _newTodoRecurrence = TodoRecurrence.none;
      _newTodoReminderOffsetMinutes = null;
      _newTodoReminderAt = null;
      _newTodoDueAt = _defaultTodoDueDate(DateTime.now(), TodoRecurrence.none);
    });
    _savePanelData();
  }

  Future<void> _pickNewTodoDueDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _newTodoDueAt,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) {
      final pickedTime = await showTimePicker(
        context: context,
        initialTime: const TimeOfDay(hour: 23, minute: 59),
      );
      if (pickedTime == null) return;
      setState(() => _newTodoDueAt = DateTime(
            picked.year,
            picked.month,
            picked.day,
            pickedTime.hour,
            pickedTime.minute,
            59,
          ));
    }
  }

  Future<void> _setReminderPreset({
    TodoEntry? todo,
    required String value,
  }) async {
    final now = DateTime.now();
    DateTime? at;
    if (value == 'later') {
      at = DateTime(now.year, now.month, now.day, now.hour + 3);
    }
    if (value == 'tomorrow') {
      final d = now.add(const Duration(days: 1));
      at = DateTime(d.year, d.month, d.day, 9);
    }
    if (value == 'nextWeek') {
      final d = now.add(Duration(days: 8 - now.weekday));
      at = DateTime(d.year, d.month, d.day, 9);
    }
    if (value == 'custom') {
      final date = await showDatePicker(
        context: context,
        initialDate: now,
        firstDate: now,
        lastDate: DateTime(2100),
      );
      if (date == null || !mounted) return;
      await Future<void>.delayed(Duration.zero);
      if (!mounted) return;
      final time = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(now),
      );
      if (time == null || !mounted) return;
      at = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    }
    if (at == null) return;
    if (todo == null) {
      setState(() {
        _newTodoReminderAt = at;
        _newTodoReminderOffsetMinutes = 0;
      });
    } else {
      final index = _todos.indexWhere((item) => item.id == todo.id);
      if (index < 0) return;
      setState(
        () => _todos[index] = _todos[index].copyWith(
          reminderEnabled: true,
          reminderOffsetMinutes: 0,
          reminderAt: at,
          clearRemindedAt: true,
        ),
      );
      await _savePanelData();
    }
  }

  String _laterReminderLabel() {
    final now = DateTime.now();
    final hour = now.hour + 3;
    return '${(hour % 24).toString().padLeft(2, '0')}:00';
  }

  Future<void> _completeTodo(TodoEntry todo) async {
    if (_editingTodoId == todo.id) _cancelEditing();
    final index = _todos.indexWhere((item) => item.id == todo.id);
    if (index < 0) return;
    final completedAt = DateTime.now();
    setState(() {
      final completedTodo = todo.copyWith(
        completedAt: completedAt,
        recurrenceSeriesId: todo.recurrence == TodoRecurrence.none
            ? null
            : todo.recurrenceSeriesId ?? todo.id.toString(),
        recurrenceNextEligibleAt: nextRecurringEligibleAt(todo, completedAt),
        subtasks: todo.subtasks
            .map((subtask) => subtask.copyWith(isCompleted: true))
            .toList(),
      );
      _todos[index] = completedTodo;
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
      final restoredIndex = _todos.indexWhere((item) => item.id == todo.id);
      if (restoredIndex >= 0) {
        _todos[restoredIndex] = _todos[restoredIndex].copyWith(
          clearCompletedAt: true,
          clearGeneratedNextTodoId: true,
        );
      }
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
                  _isSameDay(todo.dueAt ?? todo.createdAt, targetDay) &&
                  todo.id != dragged.id,
            )
            .toList()
          ..sort((a, b) => todoSortAt(a).compareTo(todoSortAt(b)));
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
          dueAt: targetDay,
          completedAt: completed
              ? (dragged.completedAt ?? DateTime.now())
              : null,
          clearCompletedAt: !completed,
        ),
      );
    final updates = <int, TodoEntry>{};
    for (var i = 0; i < reordered.length; i++) {
      updates[reordered[i].id] = reordered[i].copyWith(
        sortOrder: targetDay.add(Duration(hours: 12, minutes: i)),
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
        _todos[index] = _todos[index].copyWith(
          title: value,
          nextTodoUserModified: _todos[index].generatedFromTodoId != null,
        );
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

  Future<void> _setTodoRecurrence(
    TodoEntry todo,
    TodoRecurrence recurrence,
  ) async {
    final index = _todos.indexWhere((item) => item.id == todo.id);
    if (index < 0) return;
    setState(() {
      _todos[index] = _todos[index].copyWith(
        recurrence: recurrence,
        dueAt: _defaultTodoDueDate(DateTime.now(), recurrence),
      );
    });
    await _savePanelData();
  }

  void _addSubtask(TodoEntry todo) => setState(() {
    _addingSubtaskTodoId = todo.id;
    _pendingSubtaskTitle = '';
    _expandedSubtaskTodoIds.add(todo.id);
  });

  Future<void> _createSubtask(TodoEntry todo, String title) async {
    final value = title.trim();
    if (mounted) setState(() => _addingSubtaskTodoId = null);
    if (value.isEmpty) return;
    final index = _todos.indexWhere((item) => item.id == todo.id);
    if (index < 0 || todo.completedAt != null) return;
    setState(
      () => _todos[index] = todo.copyWith(
        subtasks: [
          ...todo.subtasks,
          TodoSubtask.create().copyWith(title: value),
        ],
      ),
    );
    await _savePanelData();
  }

  Future<void> _toggleSubtask(TodoEntry todo, TodoSubtask subtask) async {
    final index = _todos.indexWhere((item) => item.id == todo.id);
    if (index < 0 || todo.completedAt != null) return;
    setState(() {
      _todos[index] = todo.copyWith(
        subtasks: todo.subtasks
            .map(
              (item) => item.id == subtask.id
                  ? item.copyWith(isCompleted: !item.isCompleted)
                  : item,
            )
            .toList(),
      );
    });
    await _savePanelData();
  }

  Future<void> _deleteSubtask(TodoEntry todo, TodoSubtask subtask) async {
    final index = _todos.indexWhere((item) => item.id == todo.id);
    if (index < 0) return;
    setState(
      () => _todos[index] = todo.copyWith(
        subtasks: todo.subtasks.where((item) => item.id != subtask.id).toList(),
      ),
    );
    await _savePanelData();
  }

  Future<void> _makeSubtask(TodoEntry dragged, TodoEntry target) async {
    if (dragged.id == target.id || target.completedAt != null) return;
    final draggedIndex = _todos.indexWhere((item) => item.id == dragged.id);
    final targetIndex = _todos.indexWhere((item) => item.id == target.id);
    if (draggedIndex < 0 || targetIndex < 0) return;
    final moved = [TodoSubtask.fromTodo(dragged), ...dragged.subtasks];
    setState(() {
      final latestTarget = _todos[targetIndex];
      _todos[targetIndex] = latestTarget.copyWith(
        subtasks: [...moved, ...latestTarget.subtasks],
      );
      _todos.removeAt(draggedIndex);
      _expandedSubtaskTodoIds.add(target.id);
    });
    await _savePanelData();
  }

  Future<void> _promoteSubtask(
    TodoSubtaskDragData drag,
    TodoEntry target, {
    required bool after,
  }) async {
    final next = List<TodoEntry>.of(_todos);
    if (!promoteTodoSubtask(
      next,
      drag,
      targetTodoId: target.id,
      after: after,
      newTodoId: _nextTodoId++,
      allowSameParent: true,
    )) {
      return;
    }
    setState(() {
      _todos
        ..clear()
        ..addAll(next);
    });
    await _savePanelData();
  }

  Future<void> _moveSubtask(
    TodoSubtaskDragData drag, {
    required int targetParentId,
    String? targetSubtaskId,
    bool after = false,
  }) async {
    final next = List<TodoEntry>.of(_todos);
    if (!moveTodoSubtask(
      next,
      drag,
      targetParentId: targetParentId,
      targetSubtaskId: targetSubtaskId,
      after: after,
    )) {
      return;
    }
    setState(() {
      _todos
        ..clear()
        ..addAll(next);
      _expandedSubtaskTodoIds.add(targetParentId);
    });
    await _savePanelData();
  }

  Future<void> _acceptTodoDrop(
    Object data,
    TodoEntry target, {
    required bool after,
  }) async {
    if (data is TodoSubtaskDragData) {
      await _promoteSubtask(data, target, after: after);
    } else if (data is TodoEntry) {
      await _dropTodo(
        data,
        _startOfDay(target.dueAt ?? target.createdAt),
        target.completedAt != null,
        after: after ? target : null,
        before: after ? null : target,
      );
    }
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
          const PopupMenuItem(
            value: 'recurrence',
            height: 36,
            child: Text('编辑循环'),
          ),
        if (todo.completedAt == null)
          const PopupMenuItem(
            value: 'dueDate',
            height: 36,
            child: Text('编辑截止日期'),
          ),
        if (todo.completedAt == null)
          const PopupMenuItem(
            value: 'reminder',
            height: 36,
            child: Text('编辑提醒'),
          ),
        if (todo.completedAt == null)
          const PopupMenuItem(value: 'edit', height: 36, child: Text('编辑')),
        const PopupMenuItem(value: 'delete', height: 36, child: Text('删除')),
      ],
    );
    if (selected == 'edit' && mounted) await _startEditing(todo);
    if (selected == 'recurrence' && mounted) {
      final value = await showMenu<TodoRecurrence>(
        context: context,
        position: RelativeRect.fromSize(
          Rect.fromLTWH(position.dx, position.dy, 0, 0),
          overlay.size,
        ),
        items: TodoRecurrence.values
            .map(
              (item) => PopupMenuItem(
                value: item,
                child: Text(todoRecurrenceLabel(item)),
              ),
            )
            .toList(),
      );
      if (value != null) await _setTodoRecurrence(todo, value);
    }
    if (selected == 'dueDate' && mounted) {
      final value = await showMenu<String>(
        context: context,
        position: RelativeRect.fromSize(
          Rect.fromLTWH(position.dx, position.dy, 0, 0),
          overlay.size,
        ),
        items: const [
          PopupMenuItem(value: 'today', child: Text('今天')),
          PopupMenuItem(value: 'tomorrow', child: Text('明天')),
          PopupMenuItem(value: 'nextWeek', child: Text('下周')),
          PopupMenuItem(value: 'custom', child: Text('自定义日期')),
        ],
      );
      DateTime? date;
      final now = DateTime.now();
      if (value == 'today') date = now;
      if (value == 'tomorrow') date = now.add(const Duration(days: 1));
      if (value == 'nextWeek') date = now.add(const Duration(days: 7));
      if (value == 'custom') {
        if (!mounted) return;
        date = await showDatePicker(
          context: context,
          initialDate: todo.dueAt ?? todo.createdAt,
          firstDate: DateTime(2000),
          lastDate: DateTime(2100),
        );
        if (date != null && mounted) {
          final pickedTime = await showTimePicker(
            context: context,
            initialTime: const TimeOfDay(hour: 23, minute: 59),
          );
          if (pickedTime != null) {
            date = DateTime(date.year, date.month, date.day,
                pickedTime.hour, pickedTime.minute, 59);
          }
        }
      }
      final index = _todos.indexWhere((item) => item.id == todo.id);
      if (date != null && index >= 0) {
        setState(
          () => _todos[index] = _todos[index].copyWith(
            dueAt: value == 'custom' ? date! : _endOfDay(date!),
            nextTodoUserModified: todo.generatedFromTodoId != null,
          ),
        );
        await _savePanelData();
      }
    }
    if (selected == 'reminder' && mounted) {
      final offset = await showMenu<String>(
        context: context,
        position: RelativeRect.fromSize(
          Rect.fromLTWH(position.dx, position.dy, 0, 0),
          overlay.size,
        ),
        items: [
          PopupMenuItem(
            value: 'later',
            child: Text('今天晚些时候（${_laterReminderLabel()}）'),
          ),
          PopupMenuItem(value: 'tomorrow', child: Text('明天 9:00')),
          PopupMenuItem(value: 'nextWeek', child: Text('下周 9:00')),
          PopupMenuItem(value: 'custom', child: Text('自定义日期和时间')),
        ],
      );
      if (offset != null) await _setReminderPreset(todo: todo, value: offset);
    }
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
        ).showSnackBar(const SnackBar(content: Text('无法更新开机启动设置')));
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
            _PanelSection.allTasks => _buildAllTasksPage(),
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
              _TodoViewButton(
                label: '今日待办',
                selected: _todoView == _TodoView.today,
                onTap: () => setState(() => _todoView = _TodoView.today),
              ),
              _TodoViewButton(
                label: '计划',
                selected: _todoView == _TodoView.planned,
                onTap: () => setState(() => _todoView = _TodoView.planned),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('todo-input'),
                        controller: _todoController,
                        focusNode: _todoFocusNode,
                        style: const TextStyle(fontSize: 14),
                        decoration: InputDecoration(
                          fillColor: Colors.white,
                          hoverColor: Colors.white,
                          constraints: const BoxConstraints(
                            minHeight: 42,
                            maxHeight: 42,
                          ),
                          suffixIcon: _RecurrenceInputButton(
                            visible: _todoController.text.isNotEmpty,
                            value: _newTodoRecurrence,
                            onChanged: (value) => setState(() {
                              _newTodoRecurrence = value;
                              _newTodoDueAt = _bubbleTodoDueDate(
                                DateTime.now(),
                                value,
                              );
                            }),
                          ),
                        ),
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _addTodo(),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('todo-due-date-button'),
                      tooltip: '选择截止日期',
                      onPressed: _pickNewTodoDueDate,
                      icon: const Icon(Icons.calendar_today_outlined, size: 17),
                    ),
                    PopupMenuButton<String>(
                      key: const ValueKey('todo-reminder-button'),
                      tooltip: '提醒',
                      onSelected: (value) => _setReminderPreset(value: value),
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'later',
                          child: Text('今天晚些时候（${_laterReminderLabel()}）'),
                        ),
                        PopupMenuItem(
                          value: 'tomorrow',
                          child: Text('明天 9:00'),
                        ),
                        PopupMenuItem(
                          value: 'nextWeek',
                          child: Text('下周 9:00'),
                        ),
                        PopupMenuItem(value: 'custom', child: Text('自定义日期和时间')),
                      ],
                      icon: Icon(
                        _newTodoReminderOffsetMinutes == null
                            ? Icons.notifications_none_outlined
                            : Icons.notifications_active_outlined,
                        size: 18,
                      ),
                    ),
                  ],
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
    if (_todoView == _TodoView.planned) {
      final planned =
          _todos
              .where(
                (todo) =>
                    todo.completedAt == null &&
                    _startOfDay(todo.dueAt ?? todo.createdAt).isAfter(today),
              )
              .toList()
            ..sort(
              (a, b) =>
                  (a.dueAt ?? a.createdAt).compareTo(b.dueAt ?? b.createdAt),
            );
      return ListView(
        controller: _todoScrollController,
        padding: const EdgeInsets.only(right: 16),
        children: _buildPlannedTodoWidgets(planned),
      );
    }
    final todayTodos = visibleTodayTodos(_todos, today).toList()
      ..sort((a, b) => todoSortAt(a).compareTo(todoSortAt(b)));
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

  List<Widget> _buildPlannedTodoWidgets(List<TodoEntry> planned) {
    final children = <Widget>[_buildTodoSectionHeader('计划')];
    final groups = <DateTime, List<TodoEntry>>{};
    for (final todo in planned) {
      final day = _startOfDay(todo.dueAt ?? todo.createdAt);
      (groups[day] ??= <TodoEntry>[]).add(todo);
    }
    final days = groups.keys.toList()..sort();
    for (final day in days) {
      final todos = groups[day]!
        ..sort((a, b) => todoSortAt(a).compareTo(todoSortAt(b)));
      final expanded = _expandedPlannedDays.contains(day);
      children.add(
        _buildArchiveDayHeader(
          day,
          todos.length,
          completed: false,
          expanded: expanded,
          onExpandedChanged: (value) => setState(() {
            value
                ? _expandedPlannedDays.add(day)
                : _expandedPlannedDays.remove(day);
          }),
        ),
      );
      if (expanded) {
        children.addAll(
          todos.map((todo) => _buildTodoRow(todo, compact: true)),
        );
      }
    }
    if (planned.isEmpty) children.add(const _TodoEmptyState('暂无未来计划'));
    return children;
  }

  Widget _buildAllTasksPage() {
    final today = _startOfDay(DateTime.now());
    final overdue = _todos
        .where(
          (todo) =>
              todo.completedAt == null &&
              (todo.dueAt ?? todo.createdAt).isBefore(today),
        )
        .toList();
    final completed = _groupTodosByCompletedDay(
      _todos.where((todo) => todo.completedAt != null),
    );
    final completedWidgets = <Widget>[];
    _addArchiveGroups(
      completedWidgets,
      completed,
      completed: true,
      expandedDays: _expandedArchiveDays,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 36, 32, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _PageHeader(title: '所有任务', subtitle: ''),
          const SizedBox(height: 28),
          Expanded(
            child: ListView(
              controller: _todoScrollController,
              padding: const EdgeInsets.only(right: 16),
              children: [
                _buildTodoSectionHeader('未完成'),
                if (overdue.isEmpty)
                  const _TodoEmptyState('没有逾期未完成任务')
                else
                  ...overdue.map((todo) => _buildTodoRow(todo, compact: true)),
                const SizedBox(height: 24),
                _buildTodoSectionHeader('已完成'),
                ...completedWidgets,
              ],
            ),
          ),
        ],
      ),
    );
  }

  Map<DateTime, List<TodoEntry>> _groupTodosByCompletedDay(
    Iterable<TodoEntry> todos,
  ) {
    final groups = <DateTime, List<TodoEntry>>{};
    for (final todo in todos) {
      final day = _startOfDay(todo.completedAt ?? todo.createdAt);
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
        ..sort((a, b) => todoSortAt(a).compareTo(todoSortAt(b)));
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
      DragTarget<Object>(
        onWillAcceptWithDetails: (details) =>
            (details.data is TodoEntry &&
                (details.data as TodoEntry).id != todo.id) ||
            details.data is TodoSubtaskDragData,
        onAcceptWithDetails: (details) =>
            _acceptTodoDrop(details.data, todo, after: false),
        builder: (context, candidates, rejected) => SizedBox(
          height: candidates.isEmpty ? (compact ? 8 : 12) : 28,
          width: double.infinity,
          child: candidates.isEmpty
              ? null
              : const DecoratedBox(
                  decoration: BoxDecoration(color: Color(0x220067c0)),
                  child: Center(
                    child: Text(
                      '放到这里成为顶层 Todo',
                      style: TextStyle(fontSize: 11, color: Color(0xff0067c0)),
                    ),
                  ),
                ),
        ),
      ),
      DragTarget<Object>(
        onWillAcceptWithDetails: (details) =>
            !completed &&
            ((details.data is TodoEntry &&
                    (details.data as TodoEntry).id != todo.id) ||
                details.data is TodoSubtaskDragData),
        onAcceptWithDetails: (details) => details.data is TodoSubtaskDragData
            ? _moveSubtask(
                details.data as TodoSubtaskDragData,
                targetParentId: todo.id,
              )
            : _makeSubtask(details.data as TodoEntry, todo),
        builder: (context, candidates, rejected) => Stack(
          children: [
            _buildTodoRowBody(
              todo,
              completed: completed,
              includeSubtasks: false,
              titleDraggable: true,
            ),
            if (candidates.isNotEmpty)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0x220078d4),
                    border: Border.all(
                      color: const Color(0xff0078d4),
                      width: 2,
                    ),
                  ),
                  child: const Center(
                    child: Text(
                      '放到这里成为子项',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xff005a9e),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      if (todo.subtasks.isNotEmpty) _buildControlPanelSubtasks(todo, completed),
      DragTarget<Object>(
        onWillAcceptWithDetails: (details) =>
            (details.data is TodoEntry &&
                (details.data as TodoEntry).id != todo.id) ||
            details.data is TodoSubtaskDragData,
        onAcceptWithDetails: (details) =>
            _acceptTodoDrop(details.data, todo, after: true),
        builder: (context, candidates, rejected) => SizedBox(
          height: candidates.isEmpty ? (compact ? 6 : 12) : 28,
          width: double.infinity,
          child: candidates.isEmpty
              ? null
              : const DecoratedBox(
                  decoration: BoxDecoration(color: Color(0x220067c0)),
                  child: Center(
                    child: Text(
                      '放到这里成为顶层 Todo',
                      style: TextStyle(fontSize: 11, color: Color(0xff0067c0)),
                    ),
                  ),
                ),
        ),
      ),
    ],
  );

  Widget _buildTodoRowBody(
    TodoEntry todo, {
    required bool completed,
    bool includeSubtasks = true,
    bool titleDraggable = false,
  }) => MouseRegion(
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
            if (todo.subtasks.isNotEmpty)
              SizedBox.square(
                dimension: 26,
                child: IconButton(
                  key: ValueKey('toggle-subtasks-${todo.id}'),
                  tooltip: _expandedSubtaskTodoIds.contains(todo.id)
                      ? '收起子项'
                      : '展开子项',
                  padding: EdgeInsets.zero,
                  style: IconButton.styleFrom(
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(1)),
                    ),
                  ),
                  onPressed: () => setState(() {
                    if (!_expandedSubtaskTodoIds.add(todo.id)) {
                      _expandedSubtaskTodoIds.remove(todo.id);
                    }
                  }),
                  icon: Icon(
                    _expandedSubtaskTodoIds.contains(todo.id)
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    size: 18,
                  ),
                ),
              )
            else
              const SizedBox(width: 26),
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
                        decoration: InputDecoration(
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
                      _buildControlPanelTodoTitle(
                        todo,
                        completed,
                        draggable: titleDraggable,
                      ),
                    if (todo.subtasks.isNotEmpty ||
                        todo.recurrence != TodoRecurrence.none ||
                        todo.dueAt != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (todo.subtasks.isNotEmpty)
                              Text(
                                '${todo.subtasks.where((item) => item.isCompleted).length}/${todo.subtasks.length}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Color(0xff6b7280),
                                ),
                              ),
                            if (todo.subtasks.isNotEmpty &&
                                todo.recurrence != TodoRecurrence.none)
                              const SizedBox(width: 8),
                            if (todo.recurrence != TodoRecurrence.none) ...[
                              Text(
                                todoRecurrenceLabel(todo.recurrence),
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Color(0xff6b7280),
                                ),
                              ),
                              const SizedBox(width: 4),
                              _RecurrenceInputButton(
                                visible: true,
                                value: todo.recurrence,
                                onChanged: (value) =>
                                    _setTodoRecurrence(todo, value),
                              ),
                            ],
                            if (todo.dueAt != null &&
                                !_isSameDay(todo.dueAt!, DateTime.now()))
                              Padding(
                                padding: const EdgeInsets.only(left: 8),
                                child: Text(
                                  '截止 ${_formatTodoDate(todo.dueAt!)}',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Color(0xff6b7280),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    if (includeSubtasks &&
                        todo.subtasks.isNotEmpty &&
                        _expandedSubtaskTodoIds.contains(todo.id))
                      _buildControlPanelSubtasks(todo, completed),
                    if (includeSubtasks &&
                        !completed &&
                        _addingSubtaskTodoId == todo.id)
                      _buildControlPanelSubtaskEditor(todo),
                  ],
                ),
              ),
            ),
            if (!completed)
              SizedBox.square(
                dimension: 30,
                child: IconButton(
                  key: ValueKey('add-subtask-${todo.id}'),
                  tooltip: '添加子项',
                  padding: EdgeInsets.zero,
                  style: IconButton.styleFrom(
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(1)),
                    ),
                  ),
                  onPressed: () => _addSubtask(todo),
                  icon: const Icon(Icons.add, size: 17),
                ),
              ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    ),
  );

  Widget _buildControlPanelSubtasks(TodoEntry todo, bool parentCompleted) =>
      Padding(
        padding: const EdgeInsets.only(top: 5, left: 2),
        child: Column(
          children: todo.subtasks
              .map(
                (subtask) => Column(
                  children: [
                    _buildSubtaskDropZone(todo, subtask, after: false),
                    LongPressDraggable<TodoSubtaskDragData>(
                      data: TodoSubtaskDragData(
                        parentId: todo.id,
                        subtaskId: subtask.id,
                      ),
                      delay: const Duration(milliseconds: 180),
                      hapticFeedbackOnStart: false,
                      feedback: Material(
                        color: Colors.transparent,
                        child: Text(subtask.title),
                      ),
                      child: Row(
                        children: [
                          Checkbox(
                            value: subtask.isCompleted,
                            onChanged: parentCompleted
                                ? null
                                : (_) => _toggleSubtask(todo, subtask),
                          ),
                          Expanded(
                            child: Text(
                              subtask.title,
                              style: TextStyle(
                                fontSize: 13,
                                color: parentCompleted
                                    ? const Color(0xff666666)
                                    : const Color(0xff1a1a1a),
                                decoration: parentCompleted
                                    ? TextDecoration.lineThrough
                                    : null,
                              ),
                            ),
                          ),
                          if (!parentCompleted)
                            SizedBox.square(
                              dimension: 26,
                              child: IconButton(
                                tooltip: '删除子项',
                                padding: EdgeInsets.zero,
                                onPressed: () => _deleteSubtask(todo, subtask),
                                icon: const Icon(Icons.remove, size: 14),
                              ),
                            ),
                        ],
                      ),
                    ),
                    _buildSubtaskDropZone(todo, subtask, after: true),
                  ],
                ),
              )
              .toList(),
        ),
      );

  Widget _buildSubtaskDropZone(
    TodoEntry todo,
    TodoSubtask target, {
    required bool after,
  }) => DragTarget<Object>(
    onWillAcceptWithDetails: (details) => details.data is TodoSubtaskDragData,
    onAcceptWithDetails: (details) => _moveSubtask(
      details.data as TodoSubtaskDragData,
      targetParentId: todo.id,
      targetSubtaskId: target.id,
      after: after,
    ),
    builder: (context, candidates, rejected) => SizedBox(
      height: candidates.isEmpty ? 3 : 7,
      width: double.infinity,
      child: candidates.isEmpty
          ? null
          : const ColoredBox(color: Color(0x220067c0)),
    ),
  );

  Widget _buildControlPanelTodoTitle(
    TodoEntry todo,
    bool completed, {
    required bool draggable,
  }) {
    final title = GestureDetector(
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
    );
    if (!draggable) return title;
    return LongPressDraggable<TodoEntry>(
      data: todo,
      delay: const Duration(milliseconds: 180),
      feedback: Material(
        color: Colors.transparent,
        child: _todoDragFeedback(todo, completed),
      ),
      child: title,
    );
  }

  Widget _buildControlPanelSubtaskEditor(TodoEntry todo) => Padding(
    padding: const EdgeInsets.only(top: 5, left: 2),
    child: Row(
      children: [
        const SizedBox(width: 40),
        Expanded(
          child: TextField(
            key: ValueKey('new-subtask-input-${todo.id}'),
            autofocus: true,
            onChanged: (value) => _pendingSubtaskTitle = value,
            onSubmitted: (value) => _createSubtask(todo, value),
            onTapOutside: (_) => _createSubtask(todo, _pendingSubtaskTitle),
            textInputAction: TextInputAction.done,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            ),
          ),
        ),
        const SizedBox(width: 26),
      ],
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
      ).showSnackBar(const SnackBar(content: Text('无法打开 GitHub 仓库')));
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
                  '按住 Ctrl 后在桌宠上长按鼠标左键并上下拖动，可以在 50% 到 200% 之间等比缩放。',
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

class _TodoViewButton extends StatelessWidget {
  const _TodoViewButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 6),
    child: TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: selected
            ? const Color(0xff0078d4)
            : const Color(0xff4b5563),
        backgroundColor: selected
            ? const Color(0xffeff6ff)
            : Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(4)),
        ),
      ),
      child: RichText(
        text: TextSpan(text: label, style: DefaultTextStyle.of(context).style),
      ),
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
              key: const ValueKey('all-tasks-tab'),
              icon: Icons.list_alt_outlined,
              /*
              label: '所有任务',
              */
              label: '所有任务',
              selected: selected == _PanelSection.allTasks,
              onTap: () => onSelected(_PanelSection.allTasks),
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

enum TodoRecurrence { none, daily, weekly, monthly }

TodoEntry? nextRecurringTodo(
  TodoEntry todo,
  Iterable<TodoEntry> todos, [
  DateTime? completedAt,
]) {
  if (todo.recurrence == TodoRecurrence.none) {
    return null;
  }
  final nextId =
      todos.fold<int>(0, (maxId, item) => item.id > maxId ? item.id : maxId) +
      1;
  final completed = completedAt ?? todo.completedAt ?? DateTime.now();
  final nextDate = _nextRecurringDueDate(completed, todo.recurrence);
  final seriesId = todo.recurrenceSeriesId ?? todo.id.toString();
  final alreadyGenerated = todos.any(
    (item) =>
        item.id != todo.id &&
        item.recurrenceSeriesId == seriesId &&
        item.completedAt == null &&
        item.dueAt != null &&
        _isSameDay(item.dueAt!, nextDate),
  );
  if (alreadyGenerated) return null;
  return TodoEntry(
    id: nextId,
    title: todo.title,
    createdAt: nextDate,
    recurrence: todo.recurrence,
    dueAt: _defaultTodoDueDate(nextDate, todo.recurrence),
    recurrenceSeriesId: seriesId,
    generatedFromTodoId: todo.id,
    generatedByCompletion: true,
    subtasks: todo.subtasks
        .map((subtask) => subtask.copyWith(isCompleted: false))
        .toList(),
  );
}

const _longOverdueRecurrenceThreshold = Duration(days: 365);

DateTime? nextRecurringEligibleAt(TodoEntry todo, DateTime completedAt) {
  if (todo.recurrence == TodoRecurrence.none) {
    return null;
  }
  final today = _startOfDay(completedAt);
  final dueAt = todo.dueAt ?? _defaultTodoDueDate(completedAt, todo.recurrence);
  if (completedAt.isAfter(dueAt) || dueAt.isBefore(today.subtract(_longOverdueRecurrenceThreshold))) {
    return null;
  }
  return _nextRecurringDueDate(completedAt, todo.recurrence);
}

DateTime _nextRecurringDueDate(DateTime date, TodoRecurrence recurrence) =>
    switch (recurrence) {
      TodoRecurrence.daily => date.add(const Duration(days: 1)),
      TodoRecurrence.weekly => DateTime(date.year, date.month, date.day + (8 - date.weekday)),
      TodoRecurrence.monthly => DateTime(date.year, date.month + 1, 1),
      TodoRecurrence.none => date,
    };

List<TodoEntry> materializeDueRecurringTodos(
  Iterable<TodoEntry> source,
  DateTime now,
) {
  final today = _startOfDay(now);
  final todos = List<TodoEntry>.of(source);
  var nextId =
      todos.fold<int>(
        0,
        (maximum, todo) => maximum > todo.id ? maximum : todo.id,
      ) +
      1;
  final seriesIdsWithOpenTodo = todos
      .where(
        (todo) => todo.completedAt == null && todo.recurrenceSeriesId != null,
      )
      .map((todo) => todo.recurrenceSeriesId!)
      .toSet();
  final latestBySeries = <String, TodoEntry>{};
  for (final todo in todos) {
    final seriesId = todo.recurrenceSeriesId;
    if (seriesId == null ||
        todo.completedAt == null ||
        todo.recurrenceNextEligibleAt == null) {
      continue;
    }
    final existing = latestBySeries[seriesId];
    if (existing == null || todo.completedAt!.isAfter(existing.completedAt!)) {
      latestBySeries[seriesId] = todo;
    }
  }
  for (final entry in latestBySeries.entries) {
    final template = entry.value;
    if (seriesIdsWithOpenTodo.contains(entry.key) ||
        template.recurrenceNextEligibleAt!.isAfter(today)) {
      continue;
    }
    todos.add(
      TodoEntry(
        id: nextId++,
        title: template.title,
        createdAt: today,
        dueAt: _defaultTodoDueDate(today, template.recurrence),
        recurrence: template.recurrence,
        recurrenceSeriesId: entry.key,
        subtasks: template.subtasks
            .map((subtask) => subtask.copyWith(isCompleted: false))
            .toList(),
      ),
    );
  }
  return todos;
}

String todoRecurrenceLabel(TodoRecurrence value) => switch (value) {
  /*
  TodoRecurrence.none => '不循环',
  */
  TodoRecurrence.none => '不循环',
  TodoRecurrence.daily => '每天',
  TodoRecurrence.weekly => '每周',
  TodoRecurrence.monthly => '每月',
};

class TodoEntry {
  const TodoEntry({
    required this.id,
    required this.title,
    required this.createdAt,
    this.sortOrder,
    this.completedAt,
    this.recurrence = TodoRecurrence.none,
    this.subtasks = const [],
    this.dueAt,
    this.recurrenceSeriesId,
    this.recurrenceNextEligibleAt,
    this.generatedFromTodoId,
    this.generatedNextTodoId,
    this.generatedByCompletion = false,
    this.nextTodoUserModified = false,
    this.reminderEnabled = false,
    this.reminderOffsetMinutes,
    this.remindedAt,
    this.reminderAt,
  });

  final int id;
  final String title;
  final DateTime createdAt;
  final DateTime? sortOrder;
  final DateTime? completedAt;
  final TodoRecurrence recurrence;
  final List<TodoSubtask> subtasks;
  final DateTime? dueAt;
  final String? recurrenceSeriesId;
  final DateTime? recurrenceNextEligibleAt;
  final int? generatedFromTodoId;
  final int? generatedNextTodoId;
  final bool generatedByCompletion;
  final bool nextTodoUserModified;
  final bool reminderEnabled;
  final int? reminderOffsetMinutes;
  final DateTime? remindedAt;
  final DateTime? reminderAt;

  TodoEntry copyWith({
    String? title,
    DateTime? createdAt,
    DateTime? sortOrder,
    DateTime? completedAt,
    bool clearCompletedAt = false,
    TodoRecurrence? recurrence,
    List<TodoSubtask>? subtasks,
    DateTime? dueAt,
    String? recurrenceSeriesId,
    DateTime? recurrenceNextEligibleAt,
    int? generatedFromTodoId,
    int? generatedNextTodoId,
    bool? generatedByCompletion,
    bool? nextTodoUserModified,
    bool clearGeneratedNextTodoId = false,
    bool? reminderEnabled,
    int? reminderOffsetMinutes,
    DateTime? remindedAt,
    bool clearRemindedAt = false,
    DateTime? reminderAt,
  }) => TodoEntry(
    id: id,
    title: title ?? this.title,
    createdAt: createdAt ?? this.createdAt,
    sortOrder: sortOrder ?? this.sortOrder,
    completedAt: clearCompletedAt ? null : completedAt ?? this.completedAt,
    recurrence: recurrence ?? this.recurrence,
    subtasks: subtasks ?? this.subtasks,
    dueAt: dueAt ?? this.dueAt,
    recurrenceSeriesId: recurrenceSeriesId ?? this.recurrenceSeriesId,
    recurrenceNextEligibleAt:
        recurrenceNextEligibleAt ?? this.recurrenceNextEligibleAt,
    generatedFromTodoId: generatedFromTodoId ?? this.generatedFromTodoId,
    generatedNextTodoId: clearGeneratedNextTodoId
        ? null
        : generatedNextTodoId ?? this.generatedNextTodoId,
    generatedByCompletion: generatedByCompletion ?? this.generatedByCompletion,
    nextTodoUserModified: nextTodoUserModified ?? this.nextTodoUserModified,
    reminderEnabled: reminderEnabled ?? this.reminderEnabled,
    reminderOffsetMinutes: reminderOffsetMinutes ?? this.reminderOffsetMinutes,
    remindedAt: clearRemindedAt ? null : remindedAt ?? this.remindedAt,
    reminderAt: reminderAt ?? this.reminderAt,
  );

  factory TodoEntry.fromJson(Map<String, dynamic> json) {
    final createdAt = DateTime.tryParse(json['createdAt'] as String? ?? '');
    final sortOrder = DateTime.tryParse(json['sortOrder'] as String? ?? '');
    final dueAt = DateTime.tryParse(json['dueAt'] as String? ?? '');
    final completedAt = DateTime.tryParse(json['completedAt'] as String? ?? '');
    final recurrenceNextEligibleAt = DateTime.tryParse(
      json['recurrenceNextEligibleAt'] as String? ?? '',
    );
    final remindedAt = DateTime.tryParse(json['remindedAt'] as String? ?? '');
    final reminderAt = DateTime.tryParse(json['reminderAt'] as String? ?? '');
    final recurrence = TodoRecurrence.values.firstWhere(
      (value) => value.name == json['recurrence'],
      orElse: () => TodoRecurrence.none,
    );
    return TodoEntry(
      id: json['id'] as int,
      title: json['title'] as String,
      createdAt: createdAt ?? DateTime.now(),
      sortOrder: sortOrder,
      dueAt: dueAt ??
          _defaultTodoDueDate(
            createdAt ?? DateTime.now(),
            recurrence,
          ),
      completedAt: completedAt,
      recurrence: recurrence,
      subtasks: (json['subtasks'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((item) => TodoSubtask.fromJson(Map<String, dynamic>.from(item)))
          .toList(),
      recurrenceSeriesId: json['recurrenceSeriesId'] as String?,
      recurrenceNextEligibleAt: recurrenceNextEligibleAt,
      generatedFromTodoId: json['generatedFromTodoId'] as int?,
      generatedNextTodoId: json['generatedNextTodoId'] as int?,
      generatedByCompletion: json['generatedByCompletion'] as bool? ?? false,
      nextTodoUserModified: json['nextTodoUserModified'] as bool? ?? false,
      reminderEnabled: json['reminderEnabled'] as bool? ?? false,
      reminderOffsetMinutes: json['reminderOffsetMinutes'] as int?,
      remindedAt: remindedAt,
      reminderAt: reminderAt,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'createdAt': createdAt.toIso8601String(),
    'sortOrder': sortOrder?.toIso8601String(),
    'completedAt': completedAt?.toIso8601String(),
    'recurrence': recurrence.name,
    'recurrenceNextEligibleAt': recurrenceNextEligibleAt?.toIso8601String(),
    'subtasks': subtasks.map((subtask) => subtask.toJson()).toList(),
    'dueAt': dueAt?.toIso8601String(),
    'recurrenceSeriesId': recurrenceSeriesId,
    'generatedFromTodoId': generatedFromTodoId,
    'generatedNextTodoId': generatedNextTodoId,
    'generatedByCompletion': generatedByCompletion,
    'nextTodoUserModified': nextTodoUserModified,
    'reminderEnabled': reminderEnabled,
    'reminderOffsetMinutes': reminderOffsetMinutes,
    'remindedAt': remindedAt?.toIso8601String(),
    'reminderAt': reminderAt?.toIso8601String(),
  };
}

class TodoSubtask {
  const TodoSubtask({
    required this.id,
    required this.title,
    this.isCompleted = false,
  });

  factory TodoSubtask.create() => TodoSubtask(
    id: DateTime.now().microsecondsSinceEpoch.toString(),
    title: '',
  );

  factory TodoSubtask.fromTodo(TodoEntry todo) => TodoSubtask(
    id: 'todo-${todo.id}',
    title: todo.title,
    isCompleted: todo.completedAt != null,
  );

  factory TodoSubtask.fromJson(Map<String, dynamic> json) => TodoSubtask(
    id:
        json['id'] as String? ??
        DateTime.now().microsecondsSinceEpoch.toString(),
    title: json['title'] as String? ?? '',
    isCompleted: json['isCompleted'] as bool? ?? false,
  );

  final String id;
  final String title;
  final bool isCompleted;

  TodoSubtask copyWith({String? title, bool? isCompleted}) => TodoSubtask(
    id: id,
    title: title ?? this.title,
    isCompleted: isCompleted ?? this.isCompleted,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'isCompleted': isCompleted,
  };
}

/// Applies one hierarchy drag operation to a todo list.
///
/// The list is mutated only after all ids and target constraints have been
/// validated, so both the settings panel and bubble window share the same
/// no-duplicate/no-self-drop behavior.
bool moveTodoSubtask(
  List<TodoEntry> todos,
  TodoSubtaskDragData drag, {
  required int targetParentId,
  String? targetSubtaskId,
  bool after = false,
}) {
  final sourceIndex = todos.indexWhere((todo) => todo.id == drag.parentId);
  final targetIndex = todos.indexWhere((todo) => todo.id == targetParentId);
  if (sourceIndex < 0 || targetIndex < 0) return false;
  if (targetSubtaskId == drag.subtaskId) return false;
  final source = todos[sourceIndex];
  final target = todos[targetIndex];
  if (target.completedAt != null) return false;
  final subtaskIndex = source.subtasks.indexWhere(
    (subtask) => subtask.id == drag.subtaskId,
  );
  if (subtaskIndex < 0) return false;

  final subtask = source.subtasks[subtaskIndex];
  // Subtask ids are globally unique in normal data. If legacy data already
  // contains the same id in the destination, reject the move so the source
  // item is never silently replaced or appears to disappear.
  if (sourceIndex != targetIndex &&
      target.subtasks.any((item) => item.id == subtask.id)) {
    return false;
  }
  final sourceSubtasks = List<TodoSubtask>.of(source.subtasks)
    ..removeAt(subtaskIndex);
  final targetSubtasks = sourceIndex == targetIndex
      ? sourceSubtasks
      : List<TodoSubtask>.of(target.subtasks);
  var insertionIndex = targetSubtasks.length;
  if (targetSubtaskId != null) {
    final targetSubtaskIndex = targetSubtasks.indexWhere(
      (item) => item.id == targetSubtaskId,
    );
    if (targetSubtaskIndex < 0) return false;
    insertionIndex = targetSubtaskIndex + (after ? 1 : 0);
  }
  targetSubtasks.insert(insertionIndex, subtask);

  final sourceUpdated = source.copyWith(
    subtasks: sourceIndex == targetIndex ? targetSubtasks : sourceSubtasks,
    nextTodoUserModified: source.generatedFromTodoId != null
        ? true
        : source.nextTodoUserModified,
  );
  if (sourceIndex == targetIndex) {
    todos[sourceIndex] = sourceUpdated;
  } else {
    todos[sourceIndex] = sourceUpdated;
    todos[targetIndex] = target.copyWith(
      subtasks: targetSubtasks,
      nextTodoUserModified: target.generatedFromTodoId != null
          ? true
          : target.nextTodoUserModified,
    );
  }
  return true;
}

TodoEntry todoFromSubtask(TodoEntry parent, TodoSubtask subtask, int id) =>
    TodoEntry(
      id: id,
      title: subtask.title.trim(),
      createdAt: parent.createdAt,
      sortOrder: parent.sortOrder,
      completedAt: subtask.isCompleted ? DateTime.now() : null,
      recurrence: parent.recurrence,
      subtasks: const [],
      dueAt: parent.dueAt,
      recurrenceSeriesId: parent.recurrenceSeriesId,
      recurrenceNextEligibleAt: parent.recurrenceNextEligibleAt,
      generatedFromTodoId: parent.generatedFromTodoId,
      generatedNextTodoId: parent.generatedNextTodoId,
      generatedByCompletion: parent.generatedByCompletion,
      nextTodoUserModified:
          parent.nextTodoUserModified || parent.generatedFromTodoId != null,
      reminderEnabled: parent.reminderEnabled,
      reminderOffsetMinutes: parent.reminderOffsetMinutes,
      remindedAt: parent.remindedAt,
      reminderAt: parent.reminderAt,
    );

bool promoteTodoSubtask(
  List<TodoEntry> todos,
  TodoSubtaskDragData drag, {
  required int targetTodoId,
  required bool after,
  required int newTodoId,
  bool allowSameParent = false,
}) {
  final sourceIndex = todos.indexWhere((todo) => todo.id == drag.parentId);
  final targetIndex = todos.indexWhere((todo) => todo.id == targetTodoId);
  if (sourceIndex < 0 ||
      targetIndex < 0 ||
      (!allowSameParent && sourceIndex == targetIndex)) {
    return false;
  }
  final source = todos[sourceIndex];
  final subtask = source.subtasks.cast<TodoSubtask?>().firstWhere(
    (item) => item!.id == drag.subtaskId,
    orElse: () => null,
  );
  if (subtask == null || subtask.title.trim().isEmpty) return false;
  final sourceWithoutSubtask = source.copyWith(
    subtasks: source.subtasks.where((item) => item.id != subtask.id).toList(),
    nextTodoUserModified: source.generatedFromTodoId != null
        ? true
        : source.nextTodoUserModified,
  );
  if (sourceIndex == targetIndex) {
    // A child can be dropped immediately before or after its own parent to
    // become a top-level item. Remove the child first, then insert the new
    // item relative to the parent's original position.
    todos[sourceIndex] = sourceWithoutSubtask;
    todos.insert(
      sourceIndex + (after ? 1 : 0),
      todoFromSubtask(source, subtask, newTodoId),
    );
    return true;
  }
  todos[sourceIndex] = sourceWithoutSubtask;
  todos.insert(
    targetIndex + (after ? 1 : 0),
    todoFromSubtask(source, subtask, newTodoId),
  );
  return true;
}

bool _isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

DateTime todoSortAt(TodoEntry todo) => todo.sortOrder ?? todo.createdAt;

bool _todayTodosAreCompleted(Iterable<TodoEntry> todos, [DateTime? now]) {
  final today = now ?? DateTime.now();
  final todayTodos = todos.where(
    (todo) => _isSameDay(todo.dueAt ?? todo.createdAt, today),
  );
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

DateTime _endOfDay(DateTime value) =>
    DateTime(value.year, value.month, value.day, 23, 59, 59, 999);

DateTime _defaultTodoDueDate(DateTime value, TodoRecurrence recurrence) =>
    switch (recurrence) {
      TodoRecurrence.weekly => _endOfDay(DateTime(value.year, value.month, value.day + (7 - value.weekday))),
      TodoRecurrence.monthly => _endOfDay(DateTime(value.year, value.month + 1, 0)),
      TodoRecurrence.none || TodoRecurrence.daily => _endOfDay(value),
    };

DateTime _bubbleTodoDueDate(DateTime value, TodoRecurrence recurrence) =>
    _defaultTodoDueDate(value, recurrence);

List<TodoEntry> visibleTodayTodos(Iterable<TodoEntry> todos, DateTime today) =>
    todos
        .where(
          (todo) =>
              todo.completedAt == null &&
              _isSameDay(todo.dueAt ?? todo.createdAt, today),
        )
        .toList(growable: false);

List<TodoEntry> visibleBubbleTodayTodos(
  Iterable<TodoEntry> todos,
  DateTime today,
) =>
    todos
        .where((todo) => _isSameDay(todo.dueAt ?? todo.createdAt, today))
        .toList(growable: false);

DateTime reminderTimeFor(TodoEntry todo) {
  final dueAt = _startOfDay(todo.dueAt ?? todo.createdAt);
  return dueAt
      .add(const Duration(hours: 9))
      .subtract(Duration(minutes: todo.reminderOffsetMinutes ?? 0));
}

bool shouldShowReminder(TodoEntry todo, DateTime now) =>
    todo.completedAt == null &&
    todo.reminderEnabled &&
    todo.remindedAt == null &&
    now.isAfter(todo.reminderAt ?? reminderTimeFor(todo));

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
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Color(0xff4a4a4a),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              /*
              '确定要删除“$title”吗？',
              */
              '确定要删除“$title”吗？',
              style: const TextStyle(
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

class _RecurrenceInputButton extends StatefulWidget {
  const _RecurrenceInputButton({
    required this.visible,
    required this.value,
    required this.onChanged,
    this.bubbleStyle = false,
  });
  final bool visible;
  final TodoRecurrence value;
  final ValueChanged<TodoRecurrence> onChanged;
  final bool bubbleStyle;

  @override
  State<_RecurrenceInputButton> createState() => _RecurrenceInputButtonState();
}

class _RecurrenceInputButtonState extends State<_RecurrenceInputButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => widget.visible
      ? Tooltip(
          richMessage: const TextSpan(
            style: TextStyle(
              color: Color(0xff4a4a4a),
              fontSize: 12,
              height: 1.0,
            ),
            children: [
              TextSpan(
                text: '重复',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                ),
              ),
              TextSpan(text: '\n\n设置任务重复周期'),
            ],
          ),
          preferBelow: false,
          decoration: BoxDecoration(
            color: Colors.white,
            border: widget.bubbleStyle
                ? Border.all(color: const Color(0xfffde8ed), width: 1)
                : null,
            borderRadius: BorderRadius.circular(widget.bubbleStyle ? 6 : 3),
            boxShadow: widget.bubbleStyle
                ? null
                : const [
                    BoxShadow(
                      color: Color(0x26000000),
                      blurRadius: 4,
                      offset: Offset(0, 1),
                    ),
                  ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: AnimatedContainer(
              duration: widget.bubbleStyle
                  ? Duration.zero
                  : const Duration(milliseconds: 100),
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: widget.bubbleStyle && _hovered
                    ? const Color(0x33ffffff)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(4),
              ),
              child: PopupMenuButton<TodoRecurrence>(
                tooltip: '',
                splashRadius: 0,
                enableFeedback: false,
                style: ButtonStyle(
                  overlayColor: const WidgetStatePropertyAll(
                    Colors.transparent,
                  ),
                  backgroundColor: const WidgetStatePropertyAll(
                    Colors.transparent,
                  ),
                  shadowColor: const WidgetStatePropertyAll(Colors.transparent),
                ),
                onSelected: widget.onChanged,
                itemBuilder: (_) => TodoRecurrence.values
                    .where((item) => item != TodoRecurrence.none)
                    .map(
                      (item) => PopupMenuItem(
                        value: item,
                        height: 34,
                        child: Text(
                          todoRecurrenceLabel(item),
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xff4a4a4a),
                          ),
                        ),
                      ),
                    )
                    .toList(),
                color: widget.bubbleStyle
                    ? const Color(0xfffffbfc)
                    : Colors.white,
                elevation: widget.bubbleStyle ? 0 : 4,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(
                    widget.bubbleStyle ? 6 : 3,
                  ),
                  side: widget.bubbleStyle
                      ? const BorderSide(color: Color(0xfffde8ed))
                      : BorderSide.none,
                ),
                constraints: const BoxConstraints(minWidth: 120),
                padding: const EdgeInsets.all(3),
                child: const SizedBox(
                  width: 16,
                  height: 16,
                  child: Icon(Icons.sync, color: Color(0xff9ca3af), size: 15),
                ),
              ),
            ),
          ),
        )
      : const SizedBox(width: 0, height: 0);
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
      final today = _startOfDay(DateTime.now());
      final migratedTodos = todosJson
          .map((item) => TodoEntry.fromJson(item as Map<String, dynamic>))
          .toList();
      final carriedOverTodos = migratedTodos;
      final scheduledTodos = materializeDueRecurringTodos(
        carriedOverTodos,
        today,
      );
      final changed = scheduledTodos.length != migratedTodos.length;
      final todos = scheduledTodos;
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
      if (changed || todos.length != todosJson.length) await save(data);
      return data;
    } catch (_) {
      return const _PanelData.defaults();
    }
  }

  static Future<void> save(_PanelData data) async {
    if (_isFlutterTest) return;
    final todos = data.todos;
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
