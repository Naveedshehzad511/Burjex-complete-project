// Platform-dispatched logo picker. On web it uses the browser's native file
// input (reliable, no plugin); on mobile it uses file_picker. The conditional
// import keeps both build targets compiling.
export 'logo_picker_types.dart';

import 'logo_picker_stub.dart' if (dart.library.html) 'logo_picker_web.dart' as impl;
import 'logo_picker_types.dart';

Future<PickedLogo?> pickLogo() => impl.pickLogo();
