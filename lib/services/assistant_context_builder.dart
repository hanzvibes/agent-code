import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../models/context_snapshot.dart';
import 'workspace_service.dart';

class AssistantContextBuildResult {
  final ContextSnapshot snapshot;
  final Map<String, String> promptContents;

  AssistantContextBuildResult({
    required this.snapshot,
    required Map<String, String> promptContents,
  }) : promptContents = Map.unmodifiable(promptContents);
}

/// Builds the exact bounded file context sent to the provider and captures
/// full baselines for safe patch review.
class AssistantContextBuilder {
  static const int maxContextFiles = 8;
  static const int totalBudget = 48000;
  static const int openFileCap = 24000;
  static const int additionalFileCap = 24000;

  Future<AssistantContextBuildResult> build({
    required String workspaceRoot,
    String? openFilePath,
    String? openFileContent,
    Iterable<String> selectedAbsolutePaths = const [],
  }) async {
    final takenAt = DateTime.now();
    final requestedPaths = selectedAbsolutePaths.toList();

    if (workspaceRoot.trim().isEmpty) {
      if (openFilePath != null || requestedPaths.isNotEmpty) {
        throw const FileSystemException(
          'Open a project folder before choosing context files.',
        );
      }
      return AssistantContextBuildResult(
        snapshot: ContextSnapshot(
          workspaceRoot: '',
          openFilePath: '',
          files: const [],
          takenAt: takenAt,
        ),
        promptContents: const {},
      );
    }

    final root = await Directory(workspaceRoot).resolveSymbolicLinks();
    final files = <ContextFile>[];
    final promptContents = <String, String>{};
    String? safeOpenPath;
    String? openRelativePath;
    var remainingBudget = totalBudget;

    if (openFilePath != null) {
      openRelativePath = p.relative(openFilePath, from: root);
      safeOpenPath = await WorkspaceService.resolveSafePath(
        root,
        openRelativePath,
      );
      final source =
          openFileContent ?? await WorkspaceService.readFile(safeOpenPath);
      if (utf8.encode(source).length > WorkspaceService.maxEditableBytes) {
        throw FileSystemException(
          'The open file exceeds the 512 KB context limit.',
          safeOpenPath,
        );
      }
      final sent = source.length > openFileCap
          ? source.substring(0, openFileCap)
          : source;
      remainingBudget -= sent.length;
      promptContents[openRelativePath] = sent;
      files.add(
        ContextFile(
          relativePath: openRelativePath,
          absolutePath: safeOpenPath,
          baseline: source,
          truncated: sent.length < source.length,
        ),
      );
    }

    final extrasByPath = <String, String>{};
    for (final absolutePath in requestedPaths) {
      final relativePath = p.relative(absolutePath, from: root);
      final safePath = await WorkspaceService.resolveSafePath(
        root,
        relativePath,
      );
      if (safeOpenPath != null && p.equals(safePath, safeOpenPath)) continue;
      extrasByPath.putIfAbsent(safePath, () => relativePath);
    }

    final extras = extrasByPath.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final allowedExtras = maxContextFiles - (safeOpenPath == null ? 0 : 1);
    if (extras.length > allowedExtras) {
      throw FileSystemException(
        'Select no more than $maxContextFiles context files total.',
      );
    }

    for (var index = 0; index < extras.length; index++) {
      final entry = extras[index];
      final safePath = entry.key;
      final relativePath = entry.value;
      final baseline = await WorkspaceService.readFile(safePath);
      final filesRemaining = extras.length - index;
      final fairShare = remainingBudget ~/ filesRemaining;
      final cap = math.min(additionalFileCap, fairShare);
      final sent = baseline.length > cap
          ? baseline.substring(0, cap)
          : baseline;
      remainingBudget -= sent.length;
      promptContents[relativePath] = sent;
      files.add(
        ContextFile(
          relativePath: relativePath,
          absolutePath: safePath,
          baseline: baseline,
          truncated: sent.length < baseline.length,
        ),
      );
    }

    return AssistantContextBuildResult(
      snapshot: ContextSnapshot(
        workspaceRoot: root,
        openFilePath: safeOpenPath ?? '',
        files: List.unmodifiable(files),
        takenAt: takenAt,
      ),
      promptContents: promptContents,
    );
  }
}
