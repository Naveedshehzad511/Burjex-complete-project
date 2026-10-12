import 'package:flutter/foundation.dart';

/// Counts the times the app was reset for a different user. The root of the app keys its whole provider tree on
/// this, so a logout throws every provider (open trades, History, the selected account, the socket, caches ...)
/// away and the next login starts from nothing - nothing the previous user had can be on screen for the next one,
/// and no request goes out with an id from the old user and a token from the new one.
///
/// Chart drawings are NOT removed here: they are saved on the device under their trading account, so they come
/// back when that account signs in again and are never shown under another one.
final ValueNotifier<int> appSessionGeneration = ValueNotifier<int>(0);

/// Logout finished clearing the stored sessions: rebuild the app from nothing.
Future<void> resetAppForNewUser() async {
  appSessionGeneration.value++;
}
