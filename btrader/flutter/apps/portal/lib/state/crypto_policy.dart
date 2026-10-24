import 'package:flutter/foundation.dart';

/// App Store guideline 3.1.5(iii): the iPhone / iPad app must not offer or give access to cryptocurrency funding
/// (the Match2Pay gateway, crypto deposits, crypto payouts and the crypto wallet addresses they use) until the
/// provider's licences are on file with Apple. Bank transfer stays everywhere. Android and the website are unchanged.
///
/// This is a visibility rule on the app only: the server, its payment methods and every existing crypto record are
/// untouched. Tests switch it with `debugDefaultTargetPlatformOverride`.
///
/// To offer crypto on iPhone / iPad again, set [kHideCryptoFundingOnIos] to false (one line) and build the iOS app.
const bool kHideCryptoFundingOnIos = true;

bool get hideCryptoFunding => kHideCryptoFundingOnIos && !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
