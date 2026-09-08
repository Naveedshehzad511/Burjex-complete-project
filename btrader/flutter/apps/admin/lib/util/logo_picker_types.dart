import 'dart:typed_data';

/// A picked logo file: original name + raw bytes, platform-agnostic.
class PickedLogo {
  final String name;
  final Uint8List bytes;
  const PickedLogo(this.name, this.bytes);
}
