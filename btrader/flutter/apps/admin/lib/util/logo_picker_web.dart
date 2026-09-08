import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

import 'logo_picker_types.dart';

/// Web logo picker via a native <input type="file">. No plugin dependency —
/// works in every browser and never silently no-ops the way file_picker's web
/// backend can.
Future<PickedLogo?> pickLogo() async {
  final input = html.FileUploadInputElement()..accept = 'image/*';
  input.click();
  await input.onChange.first;
  final files = input.files;
  if (files == null || files.isEmpty) return null;
  final file = files.first;

  final reader = html.FileReader();
  reader.readAsArrayBuffer(file);
  await reader.onLoadEnd.first;
  final result = reader.result;
  final bytes = result is ByteBuffer ? result.asUint8List() : result as Uint8List;
  return PickedLogo(file.name, bytes);
}
