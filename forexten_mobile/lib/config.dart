import 'package:btrader_core/btrader_core.dart';

/// Compiled defaults matching live portal.burjexprime.net (tradeplus43).
class PortalConfig {
  PortalConfig._();

  static const crmBase = BtConfig.liveCrmHost;

  static void apply() => BtConfig.useLivePortalHosts();
}
