import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/pending_panel.dart';

/// Chart trading controls — the one place these live (symbol and timeframe stay in
/// `chartSymbolProvider` / `chartTfProvider`; entry / SL / TP in the chart's
/// `ChartEdit`; the viewport inside `CandleChart`).
class ChartTradeState {
  const ChartTradeState({this.panelVisible = true, this.mode = OrderMode.market, this.volume = 0.10});

  /// The SELL / volume / BUY panel under the header (MT5's one-click panel).
  final bool panelVisible;

  /// Last order mode picked in the order-mode panel.
  final OrderMode mode;

  /// Lot size used by SELL / BUY and seeded into every new order.
  final double volume;

  ChartTradeState copyWith({bool? panelVisible, OrderMode? mode, double? volume}) => ChartTradeState(
        panelVisible: panelVisible ?? this.panelVisible,
        mode: mode ?? this.mode,
        volume: volume ?? this.volume,
      );
}

class ChartTradeController extends StateNotifier<ChartTradeState> {
  ChartTradeController() : super(const ChartTradeState()) {
    _restore();
  }
  static const _kPanel = 'bt_chart_trade_panel';
  static const _kVolume = 'bt_chart_trade_volume';

  Future<void> _restore() async {
    try {
      final p = await SharedPreferences.getInstance();
      final vis = p.getBool(_kPanel);
      final vol = p.getDouble(_kVolume);
      if (!mounted) return;
      state = state.copyWith(panelVisible: vis, volume: vol != null && vol > 0 ? vol : null);
    } catch (_) {/* defaults are fine */}
  }

  Future<void> _save(void Function(SharedPreferences p) w) async {
    try {
      w(await SharedPreferences.getInstance());
    } catch (_) {/* not persisted; state still correct in memory */}
  }

  void togglePanel() => setPanelVisible(!state.panelVisible);

  void setPanelVisible(bool v) {
    if (v == state.panelVisible) return;
    state = state.copyWith(panelVisible: v);
    _save((p) => p.setBool(_kPanel, v));
  }

  void setMode(OrderMode m) => state = state.copyWith(mode: m);

  void setVolume(double v) {
    if (!(v > 0) || v == state.volume) return;
    state = state.copyWith(volume: v);
    _save((p) => p.setDouble(_kVolume, v));
  }
}

final chartTradeProvider = StateNotifierProvider<ChartTradeController, ChartTradeState>((_) => ChartTradeController());
