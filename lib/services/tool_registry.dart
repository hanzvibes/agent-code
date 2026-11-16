/// Single definition of every workspace tool (Batch 2 — desain §3, D10).
///
/// The tool list is defined once here and used both for the system
/// prompt (what the model may call) and for dispatch in
/// [WorkspaceToolService]. The engine's own tools (`finish_task`,
/// `update_todo`) live in [AgentEngine.agentToolDefinitions] and are
/// not workspace tools, so they stay out of this registry.
///
/// Write tools record a checkpoint before mutating anything, so every
/// agent change can be undone per step or for the whole task
/// (see [CheckpointStore]).
class ToolRegistry {
  /// Read-only workspace tools (unchanged from before Batch 2).
  static const List<Map<String, dynamic>> readToolDefinitions = [
    {
      'type': 'function',
      'function': {
        'name': 'list_project_files',
        'description':
            'Lists relative file paths in the workspace (skipping ignored folders).',
        'parameters': {
          'type': 'object',
          'properties': {},
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'read_project_file',
        'description':
            'Reads a workspace-relative file, capped to 512 KB and truncated to 16 KB.',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'Workspace-relative path to read.',
            },
          },
          'required': ['path'],
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'search_project',
        'description':
            'Searches for text in workspace files and file paths, returning line numbers and previews.',
        'parameters': {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description': 'Search string to find in workspace.',
            },
          },
          'required': ['query'],
          'additionalProperties': false,
        },
      },
    },
  ];

  /// Write tools (Batch 2 — desain D2). Every call is checkpointed
  /// before it writes, so it can be undone from the change history.
  static const List<Map<String, dynamic>> writeToolDefinitions = [
    {
      'type': 'function',
      'function': {
        'name': 'write_file',
        'description':
            'Writes (creates or overwrites) a workspace-relative text file, up to 512 KB. The previous content is saved automatically so the change can be undone. Binary content is rejected.',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'Workspace-relative path to write.',
            },
            'content': {
              'type': 'string',
              'description': 'Full new text content of the file.',
            },
          },
          'required': ['path', 'content'],
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'edit_file',
        'description':
            'Replaces one exact piece of text in a workspace-relative file. oldText must match exactly once: if it matches zero times or more than once, the call fails and nothing is written — include more surrounding context to make it unique instead of guessing.',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'Workspace-relative path to edit.',
            },
            'oldText': {
              'type': 'string',
              'description':
                  'Exact text to replace (must occur exactly once in the file).',
            },
            'newText': {
              'type': 'string',
              'description': 'Replacement text.',
            },
          },
          'required': ['path', 'oldText', 'newText'],
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'create_file',
        'description':
            'Creates a new workspace-relative text file, up to 512 KB. Fails if the file already exists — use edit_file or write_file for existing files.',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'Workspace-relative path to create.',
            },
            'content': {
              'type': 'string',
              'description': 'Initial text content of the file.',
            },
          },
          'required': ['path', 'content'],
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'delete_file',
        'description':
            'Deletes a workspace-relative file by moving it to the .codeharness-trash folder inside the project, keeping its relative path. The file is only permanently removed when the task finishes, and it can be restored from the change history until then.',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'Workspace-relative path to delete.',
            },
          },
          'required': ['path'],
          'additionalProperties': false,
        },
      },
    },
  ];

  /// Detection tools (Batch 3 — desain D4). `detect_project` is pure
  /// file-system work; `probe_toolchain` runs `<tool> --version` on
  /// the runtime, so it needs the runtime opt-in like
  /// `run_project_command`.
  static const List<Map<String, dynamic>> detectionToolDefinitions = [
    {
      'type': 'function',
      'function': {
        'name': 'detect_project',
        'description':
            'Detects the kind of project in the open workspace from marker files at the root (pubspec.yaml = Flutter/Dart, package.json = Node, requirements.txt/pyproject.toml = Python, build.gradle = Gradle/Android, go.mod = Go, Cargo.toml = Rust, composer.json = PHP, none = generic). Returns the type and the marker files found. Call this first when starting work in an unfamiliar project.',
        'parameters': {
          'type': 'object',
          'properties': {},
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'probe_toolchain',
        'description':
            'Checks which tools are available on the runtime and their versions, by running "<tool> --version" for each. Without a "tools" argument it probes the tools relevant to the detected project kind plus git and rg. Returns one entry per tool: tool, available, version, backend (bundled). Needs the runtime enabled.',
        'parameters': {
          'type': 'object',
          'properties': {
            'tools': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'Optional tool names to probe (for example ["node", "npm"]). Defaults to the tools relevant to the project kind.',
            },
          },
          'additionalProperties': false,
        },
      },
    },
  ];

  /// All workspace tools (read + write + detection) in one list for
  /// the prompt.
  static List<Map<String, dynamic>> get allToolDefinitions => [
    ...readToolDefinitions,
    ...writeToolDefinitions,
    ...detectionToolDefinitions,
  ];

  static const Set<String> writeToolNames = {
    'write_file',
    'edit_file',
    'create_file',
    'delete_file',
  };

  static bool isWriteTool(String name) => writeToolNames.contains(name);

  static Set<String> get allToolNames => {
    for (final def in allToolDefinitions)
      (def['function'] as Map<String, dynamic>)['name'] as String,
  };
}
