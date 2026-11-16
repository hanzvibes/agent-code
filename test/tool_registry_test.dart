import 'package:flutter_test/flutter_test.dart';
import 'package:code_harness/services/tool_registry.dart';

void main() {
  test('registry defines the read tools and the four write tools', () {
    final names = ToolRegistry.allToolNames;
    expect(
      names,
      containsAll([
        'list_project_files',
        'read_project_file',
        'search_project',
        'write_file',
        'edit_file',
        'create_file',
        'delete_file',
      ]),
    );
    expect(names.length, 7);
    expect(ToolRegistry.isWriteTool('write_file'), isTrue);
    expect(ToolRegistry.isWriteTool('edit_file'), isTrue);
    expect(ToolRegistry.isWriteTool('create_file'), isTrue);
    expect(ToolRegistry.isWriteTool('delete_file'), isTrue);
    expect(ToolRegistry.isWriteTool('read_project_file'), isFalse);
  });

  test('every definition has a name, description and JSON schema', () {
    for (final def in ToolRegistry.allToolDefinitions) {
      expect(def['type'], 'function');
      final function = def['function'] as Map<String, dynamic>;
      expect(function['name'], isA<String>());
      expect((function['name'] as String).isNotEmpty, isTrue);
      expect(function['description'], isA<String>());
      final params = function['parameters'] as Map<String, dynamic>;
      expect(params['type'], 'object');
      expect(params['properties'], isA<Map>());
    }
  });

  test('write tools require their arguments', () {
    final byName = {
      for (final def in ToolRegistry.writeToolDefinitions)
        (def['function'] as Map<String, dynamic>)['name'] as String:
            (def['function'] as Map<String, dynamic>)['parameters']
                as Map<String, dynamic>,
    };
    expect(byName['write_file']!['required'], ['path', 'content']);
    expect(byName['edit_file']!['required'], ['path', 'oldText', 'newText']);
    expect(byName['create_file']!['required'], ['path', 'content']);
    expect(byName['delete_file']!['required'], ['path']);
  });

  test('registry does not contain the engine-owned tools', () {
    expect(ToolRegistry.allToolNames, isNot(contains('finish_task')));
    expect(ToolRegistry.allToolNames, isNot(contains('update_todo')));
  });
}
