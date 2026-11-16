class EditorHistory {
  static const int maxSteps = 100;
  final List<String> _past = [];
  final List<String> _future = [];
  String _current = '';

  void init(String initialText) {
    _past.clear();
    _future.clear();
    _current = initialText;
  }

  void push(String newText) {
    if (newText == _current) return;
    _past.add(_current);
    if (_past.length > maxSteps) _past.removeAt(0);
    _future.clear();
    _current = newText;
  }

  String? undo() {
    if (_past.isEmpty) return null;
    _future.add(_current);
    _current = _past.removeLast();
    return _current;
  }

  String? redo() {
    if (_future.isEmpty) return null;
    _past.add(_current);
    if (_past.length > maxSteps) _past.removeAt(0);
    _current = _future.removeLast();
    return _current;
  }

  bool get canUndo => _past.isNotEmpty;
  bool get canRedo => _future.isNotEmpty;
  String get current => _current;
}
