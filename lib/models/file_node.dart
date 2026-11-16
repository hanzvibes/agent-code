class FileNode {
  final String name;
  final String path;
  final bool isDirectory;
  final int depth;
  List<FileNode> children;
  bool isExpanded;

  FileNode({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.depth,
    this.children = const [],
    this.isExpanded = false,
  });
}
