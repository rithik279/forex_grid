"""
Export top optimization passes as single-test .set files into OneDrive Queue.
Generates lot-size variations for each candidate.
"""
import os

QUEUE = r'C:\Users\manmi\OneDrive\RD_MT5_Sharing\Queue'
os.makedirs(QUEUE, exist_ok=True)

BASE = {
    'AllowNewSequence': 'true',
    'ATRPeriod': '14',
    'DelayTradeSequence': '3',
    'LiveDelay': '0',
    'LotMultiplierFirstTradeAfterLD': '1.0',
    'CombineLiveDelayTrades': 'true',
    'ReverseSequenceDirection': 'false',
    'StopLoss': '0.0',
    'TakeProfit': '50.0',
    'LockProfitMinTrades': '0',
    'LockProfitCheckMode': '0',
    'TrailingCheckMode': '0',
    'AllowSamePairDirectionTrades': 'false',
    'UseCompounding': 'false',
    'InitialAccountBalanceThreshold': '100000.0',
    'RiskPercentForCompounding': '1.0',
    'RiskInPips': '100.0',
    'MaxLotSizeForCompounding': '10.0',
    'RiskPercent': '0.0',
    'LotSizeExponent': '1.2',
    'MaxLotSize': '1.0',
    'CloseForWeekend': 'true',
    'DayToClose': '5',
    'TimeToClose': '21:00',
    'DayToRestart': '1',
    'TimeToRestart': '01:00',
    'TradeCustomTimes': 'false',
    'TradingSessionMonday': '00:00-23:59',
    'TradingSessionTuesday': '00:00-23:59',
    'TradingSessionWednesday': '00:00-23:59',
    'TradingSessionThursday': '00:00-23:59',
    'TradingSessionFriday': '00:00-21:00',
    'ActionAtEndOfSession': '0',
    'MaxRunningLoss': '5000.0',
    'RestartEAAfterLoss': '0',
    'RestartNextDayAt': '01:00',
    'RestartAfterHours': '3.0',
    'DailyProfitTarget': '1000.0',
    'UltimateTargetBalance': '0.0',
    'GlobalEquityStopType': '0',
    'GlobalEquityStopValue': '0.0',
    'ResetGlobalEquityStop': 'false',
    'MinSecondsBetweenTrades': '0',
    'UseHighImpactNews': 'true',
    'NewsTradesAction': '0',
    'CloseMinutesBeforeNews': '60',
    'PauseMinutesAfterNews': '60',
    'EMATrendRule': '0',
    'ADXTrendRule': '0',
    'LogLevel': '1',
    'UseRandomEntryDelay': 'false',
    'RandomSeed': '42',
    'LicenseKey': '',
}

# EURUSD Pass 2622 — convergence winner, EMA M2 only, 267 trades, DD 0.94%
p2622 = {
    'TradeDirection': '1', 'MagicNumber': '2001', 'TradeComment': 'Triton_EUR_2622',
    'PipStep': '20', 'PipStepExponent': '2.0', 'MaxPipStep': '31', 'MaxOrdersPerDirection': '27',
    'LockProfit': '10', 'TrailingStop': '15',
    'UseRSI': 'false', 'RSITimeframe': '10', 'RSIPeriod': '15', 'RSIOverboughtLevel': '90',
    'UseEMA': 'true', 'EMATimeframe': '2', 'EMAFast': '5', 'EMAMid': '10', 'EMASlow': '90',
    'DoubleCheckEMAFirstRealTrade': 'false',
    'UseADX': 'false', 'ADXTimeframe': '5', 'ADXPeriod': '30', 'ADXThreshold': '45',
    'DoubleCheckADXFirstRealTrade': 'false',
    'UseBollinger': 'false', 'BBMode': '0', 'BBTimeframe': '15', 'BBPeriod': '109', 'BBDeviation': '2.5',
}

# EURUSD Pass 642 — triple filter W1 EMA + M1 ADX + M3 BB, 68 trades, DD 0.73%
p642 = {
    'TradeDirection': '1', 'MagicNumber': '2002', 'TradeComment': 'Triton_EUR_642',
    'PipStep': '120', 'PipStepExponent': '4.5', 'MaxPipStep': '11', 'MaxOrdersPerDirection': '6',
    'LockProfit': '31', 'TrailingStop': '13',
    'UseRSI': 'false', 'RSITimeframe': '6', 'RSIPeriod': '75', 'RSIOverboughtLevel': '55',
    'UseEMA': 'true', 'EMATimeframe': '16390', 'EMAFast': '5', 'EMAMid': '8', 'EMASlow': '70',
    'DoubleCheckEMAFirstRealTrade': 'false',
    'UseADX': 'true', 'ADXTimeframe': '0', 'ADXPeriod': '40', 'ADXThreshold': '40',
    'DoubleCheckADXFirstRealTrade': 'true',
    'UseBollinger': 'true', 'BBMode': '0', 'BBTimeframe': '3', 'BBPeriod': '53', 'BBDeviation': '4.4',
}

# EURUSD Pass 1024 — EMA H2 + ADX M30 + BB H6, 109 trades, DD 1.60%
p1024 = {
    'TradeDirection': '1', 'MagicNumber': '2003', 'TradeComment': 'Triton_EUR_1024',
    'PipStep': '30', 'PipStepExponent': '4.5', 'MaxPipStep': '11', 'MaxOrdersPerDirection': '16',
    'LockProfit': '13', 'TrailingStop': '11',
    'UseRSI': 'false', 'RSITimeframe': '20', 'RSIPeriod': '50', 'RSIOverboughtLevel': '80',
    'UseEMA': 'true', 'EMATimeframe': '16386', 'EMAFast': '8', 'EMAMid': '14', 'EMASlow': '100',
    'DoubleCheckEMAFirstRealTrade': 'true',
    'UseADX': 'true', 'ADXTimeframe': '30', 'ADXPeriod': '20', 'ADXThreshold': '40',
    'DoubleCheckADXFirstRealTrade': 'true',
    'UseBollinger': 'true', 'BBMode': '0', 'BBTimeframe': '16390', 'BBPeriod': '117', 'BBDeviation': '2.9',
}

# XAUUSD Pass 4256 — RSI M2 only, 115 trades, DD 0.34%, PF 870
p4256 = {
    'TradeDirection': '2', 'MagicNumber': '3001', 'TradeComment': 'Triton_XAU_4256',
    'PipStep': '110', 'PipStepExponent': '1.5', 'MaxPipStep': '1', 'MaxOrdersPerDirection': '10',
    'LockProfit': '19', 'TrailingStop': '21',
    'UseRSI': 'true', 'RSITimeframe': '2', 'RSIPeriod': '60', 'RSIOverboughtLevel': '69',
    'UseEMA': 'false', 'EMATimeframe': '6', 'EMAFast': '3', 'EMAMid': '8', 'EMASlow': '50',
    'DoubleCheckEMAFirstRealTrade': 'true',
    'UseADX': 'false', 'ADXTimeframe': '2', 'ADXPeriod': '55', 'ADXThreshold': '30',
    'DoubleCheckADXFirstRealTrade': 'true',
    'UseBollinger': 'false', 'BBMode': '1', 'BBTimeframe': '30', 'BBPeriod': '75', 'BBDeviation': '0.7',
}

CANDIDATES = [
    ('EURUSD_p2622', p2622, [0.1, 0.3, 0.5]),
    ('EURUSD_p642',  p642,  [0.1, 0.3, 0.5]),
    ('EURUSD_p1024', p1024, [0.1, 0.3]),
    ('XAUUSD_p4256', p4256, [0.1, 0.3, 0.5]),
]

def write_set(filename, base_params, specific_params, lot, desc):
    params = {**base_params, **specific_params}
    params['LotSize'] = str(lot)
    params['StrategyDescription'] = desc
    path = os.path.join(QUEUE, filename)
    with open(path, 'w') as f:
        f.write(f'; Triton Single Test — {desc}\n')
        f.write(f'; LotSize={lot}\n;\n')
        for k, v in params.items():
            f.write(f'{k}={v}\n')
    print(f'  Written: {filename}')

print(f'Exporting to Queue: {QUEUE}\n')
total = 0
for name, params, lots in CANDIDATES:
    for lot in lots:
        fname = f'{name}_lot{lot}.set'
        desc = f'{name} lot{lot}'
        write_set(fname, BASE, params, lot, desc)
        total += 1

print(f'\nDone. {total} files queued.')
print('\nNOTE: EURUSD files need Symbol=EURUSD.s in remote_config.json')
print('      XAUUSD files need Symbol=XAUUSD.s in remote_config.json')
print('      Process each batch separately, update config between batches.')
