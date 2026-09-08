import {
  requiredMargin,
  positionProfit,
  computeAggregates,
  normalizeVolume,
  slippageBound,
  SymbolCalcSpec,
} from '@btrader/engine-core';

const eurusd: SymbolCalcSpec = {
  digits: 5,
  pipSize: 0.0001,
  contractSize: 100000,
  marginRate: 1,
  quoteCurrency: 'USD',
  baseCurrency: 'EUR',
};

describe('trading calc', () => {
  test('required margin: 1 lot EURUSD @1.10, 1:100 = 1100', () => {
    expect(requiredMargin(1, eurusd, 1.1, 100)).toBeCloseTo(1100, 6);
  });

  test('profit: BUY 1 lot 1.1000→1.1050 = +500', () => {
    expect(positionProfit('BUY', 1, 1.1, 1.105, eurusd)).toBeCloseTo(500, 6);
  });

  test('profit: SELL 1 lot 1.1000→1.1050 = -500', () => {
    expect(positionProfit('SELL', 1, 1.1, 1.105, eurusd)).toBeCloseTo(-500, 6);
  });

  test('aggregates: balance 10000, one +500 floating, margin 1100', () => {
    const agg = computeAggregates(10000, 0, [
      {
        side: 'BUY',
        volume: 1,
        openPrice: 1.1,
        currentPrice: 1.105,
        marginUsed: 1100,
        swap: 0,
        commission: 0,
        spec: eurusd,
      },
    ]);
    expect(agg.floatingPL).toBeCloseTo(500, 6);
    expect(agg.equity).toBeCloseTo(10500, 6);
    expect(agg.margin).toBeCloseTo(1100, 6);
    expect(agg.freeMargin).toBeCloseTo(9400, 6);
    expect(agg.marginLevel).toBeCloseTo((10500 / 1100) * 100, 4);
  });

  test('normalizeVolume clamps + steps', () => {
    expect(normalizeVolume(0.013, 0.01, 100, 0.01)).toBeCloseTo(0.01, 6);
    expect(normalizeVolume(250, 0.01, 100, 0.01)).toBeCloseTo(100, 6);
  });

  test('slippageBound 0 points = exact price', () => {
    expect(slippageBound('BUY', 1.1, 0, 5)).toBeCloseTo(1.1, 8);
  });
});
