// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
part of 'provider_profile.dart';

class ProviderProfileAdapter extends TypeAdapter<ProviderProfile> {
  @override
  final int typeId = 0;

  @override
  ProviderProfile read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return ProviderProfile(
      id: fields[0] as String,
      name: fields[1] as String,
      baseUrl: fields[2] as String,
      modelId: fields[3] as String,
      hasApiKey: fields[4] as bool? ?? false,
    );
  }

  @override
  void write(BinaryWriter writer, ProviderProfile obj) {
    writer
      ..writeByte(5)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.baseUrl)
      ..writeByte(3)
      ..write(obj.modelId)
      ..writeByte(4)
      ..write(obj.hasApiKey);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProviderProfileAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
