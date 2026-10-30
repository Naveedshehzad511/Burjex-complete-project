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

/// App Store guideline 3.2.2(viii): the iPhone / iPad app has no deposit or withdrawal at all - no Deposit / Withdraw
/// buttons or menu entries, no wallet or internal transfer, no IB payout, no payout bank details, and their routes lead
/// Home. Clients fund and withdraw on the website. Balances, pending withdrawals and history stay visible.
///
/// Built into the iOS app on purpose, never switched from the server: a feature that could be turned on after review
/// is a hidden feature (guideline 2.5.19). Android and the website are unchanged.
const bool kNoFundingOnIos = true;

bool get hideFunding => kNoFundingOnIos && !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

/// Routes that move money in or out; on the iPhone / iPad app they lead Home ([hideFunding]).
const kFundingRoutes = {'/deposit', '/withdraw', '/wallet', '/transfer', '/ib/withdraw'};

/// Where [location] leads instead on this platform: Home for a funding route on the iPhone / iPad app, else null.
String? fundingRedirect(String location) => hideFunding && kFundingRoutes.contains(location) ? '/home' : null;
