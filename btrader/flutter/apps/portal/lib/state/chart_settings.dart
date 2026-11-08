import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// MT5 "Line type" choices, mapped one-to-one onto `ChartType` in candle_chart.dart.
enum ChartLineType { bar, candles, line }

/// Chart Settings screen state (Android / iOS apps; the website ignores it). Defaults follow the MT5 reference.
class ChartSettingsState {
  const ChartSettingsState({
    this.lineType = ChartLineType.candles,
    this.periodSeparators = false,
    this.freeChartMovement = true,
    this.tradeOrders = true,
    this.tradePositions = true,
    this.slTpLevels = true,
    this.profitLoss = true,
    this.tradeHistory = false,
    this.tradingPanelAtBottom = false,
  });

  final ChartLineType lineType;
  final bool periodSeparators;
  /// Free chart movement (MT5): ticked = the chart moves both ways (today's behaviour); unticked = Auto-scale, it
  /// moves horizontally only and the price scale always fits the visible bars.
  final bool freeChartMovement;
  final bool tradeOrders;
  final bool tradePositions;
  final bool slTpLevels;
  final bool profitLoss;
  final bool tradeHistory;

  /// Trading panel at the bottom: the SELL / volume / BUY panel sits directly above the bottom navigation (ticked)
  /// or under the toolbar at the top (unticked, the app's layout until now). Whether the panel is shown at all is
  /// still the chart's own Buy / Sell toggle.
  final bool tradingPanelAtBottom;

  ChartSettingsState copyWith({
    ChartLineType? lineType,
    bool? periodSeparators,
    bool? freeChartMovement,
    bool? tradeOrders,
    bool? tradePositions,
    bool? slTpLevels,
    bool? profitLoss,
    bool? tradeHistory,
    bool? tradingPanelAtBottom,
  }) =>
      ChartSettingsState(
        lineType: lineType ?? this.lineType,
        periodSeparators: periodSeparators ?? this.periodSeparators,
        freeChartMovement: freeChartMovement ?? this.freeChartMovement,
        tradeOrders: tradeOrders ?? this.tradeOrders,
        tradePositions: tradePositions ?? this.tradePositions,
        slTpLevels: slTpLevels ?? this.slTpLevels,
        profitLoss: profitLoss ?? this.profitLoss,
        tradeHistory: tradeHistory ?? this.tradeHistory,
        tradingPanelAtBottom: tradingPanelAtBottom ?? this.tradingPanelAtBottom,
      );
}

class ChartSettingsController extends StateNotifier<ChartSettingsState> {
  ChartSettingsController() : super(const ChartSettingsState()) {
    _restore();
  }

  static const _p = 'bt_cs_';
  static const kLineType = '${_p}line_type';
  static const kPeriodSeparators = '${_p}period_separators';
  static const kFreeMovement = '${_p}free_move'; // not the old 'free_movement': that box did nothing and was off
  static const kTradeOrders = '${_p}trade_orders';
  static const kTradePositions = '${_p}trade_positions';
  static const kSlTp = '${_p}sl_tp';
  static const kProfitLoss = '${_p}profit_loss';
  static const kTradeHistory = '${_p}trade_history';
  static const kPanelBottom = '${_p}panel_bottom';

  Future<void> _restore() async {
    try {
      final p = await SharedPreferences.getInstance();
      if (!mounted) return;
      T pick<T extends Enum>(List<T> all, String key, T fallback) {
        final n = p.getString(key);
        return all.firstWhere((e) => e.name == n, orElse: () => fallback);
      }

      final d = state;
      state = ChartSettingsState(
        lineType: pick(ChartLineType.values, kLineType, d.lineType),
        periodSeparators: p.getBool(kPeriodSeparators) ?? d.periodSeparators,
        freeChartMovement: p.getBool(kFreeMovement) ?? d.freeChartMovement,
        tradeOrders: p.getBool(kTradeOrders) ?? d.tradeOrders,
        tradePositions: p.getBool(kTradePositions) ?? d.tradePositions,
        slTpLevels: p.getBool(kSlTp) ?? d.slTpLevels,
        profitLoss: p.getBool(kProfitLoss) ?? d.profitLoss,
        tradeHistory: p.getBool(kTradeHistory) ?? d.tradeHistory,
        tradingPanelAtBottom: p.getBool(kPanelBottom) ?? d.tradingPanelAtBottom,
      );
    } catch (_) {/* defaults are fine */}
  }

  Future<void> _save(void Function(SharedPreferences p) w) async {
    try {
      w(await SharedPreferences.getInstance());
    } catch (_) {/* kept in memory for this session */}
  }

  void setLineType(ChartLineType v) {
    state = state.copyWith(lineType: v);
    _save((p) => p.setString(kLineType, v.name));
  }

  void setPeriodSeparators(bool v) {
    state = state.copyWith(periodSeparators: v);
    _save((p) => p.setBool(kPeriodSeparators, v));
  }

  void setFreeChartMovement(bool v) {
    state = state.copyWith(freeChartMovement: v);
    _save((p) => p.setBool(kFreeMovement, v));
  }

  void setTradeOrders(bool v) {
    state = state.copyWith(tradeOrders: v);
    _save((p) => p.setBool(kTradeOrders, v));
  }

  void setTradePositions(bool v) {
    state = state.copyWith(tradePositions: v);
    _save((p) => p.setBool(kTradePositions, v));
  }

  void setSlTpLevels(bool v) {
    state = state.copyWith(slTpLevels: v);
    _save((p) => p.setBool(kSlTp, v));
  }

  void setProfitLoss(bool v) {
    state = state.copyWith(profitLoss: v);
    _save((p) => p.setBool(kProfitLoss, v));
  }

  void setTradeHistory(bool v) {
    state = state.copyWith(tradeHistory: v);
    _save((p) => p.setBool(kTradeHistory, v));
  }

  void setTradingPanelAtBottom(bool v) {
    state = state.copyWith(tradingPanelAtBottom: v);
    _save((p) => p.setBool(kPanelBottom, v));
  }
}

final chartSettingsProvider =
    StateNotifierProvider<ChartSettingsController, ChartSettingsState>((_) => ChartSettingsController());
