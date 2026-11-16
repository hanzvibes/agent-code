// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
part of 'app_prefs.dart';

class AppPrefsAdapter extends TypeAdapter<AppPrefs> {
  @override
  final int typeId = 1;

  @override
  AppPrefs read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return AppPrefs(
      activeProfileId: fields[0] as String?,
      lastWorkspacePath: fields[1] as String?,
      isDarkMode: fields[2] as bool? ?? false,
      useSystemTheme: fields[3] as bool? ?? true,
    );
  }

  @override
  void write(BinaryWriter writer, AppPrefs obj) {
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(obj.activeProfileId)
      ..writeByte(1)
      ..write(obj.lastWorkspacePath)
      ..writeByte(2)
      ..write(obj.isDarkMode)
      ..writeByte(3)
      ..write(obj.useSystemTheme);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppPrefsAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
