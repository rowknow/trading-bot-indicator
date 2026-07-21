#property copyright "Keyaka Neil"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

input group "SETUP"
input int      InpM15Lookback          = 20;      // Structure lookback candles
input int      InpBreakBufferPoints    = 10;      // Close beyond level (points)
input int      InpRetestTolerancePts   = 40;      // Retest distance (points)
input int      InpSetupExpiryM5Bars    = 12;      // Cancel setup after this many M5 bars
input bool     InpRequireBodyDirection = true;    // Confirmation candle matches direction
input double   InpMaxWickBodyRatio     = 2.0;     // Reject extreme-wick confirmation candles

input group "RISK AND TARGET"
input bool     InpUseRiskPercent       = true;
input double   InpRiskPercent          = 2.0;
input double   InpFixedLot             = 0.20;
input bool     InpAllowMinLotOverRisk  = false;   // False prevents excess risk on small accounts
input int      InpATRPeriod             = 14;
input double   InpSL_ATR_Buffer         = 0.35;
input double   InpRiskReward            = 2.0;
input int      InpMaxSpreadPoints       = 100;

input group "TRADE MANAGEMENT"
input bool     InpOnePositionOnly       = true;
input bool     InpMoveToBreakeven       = true;
input double   InpBreakevenAtR          = 1.0;
input int      InpBreakevenPlusPoints   = 5;
input bool     InpUseTrailingStop       = false;
input double   InpTrailStartR           = 1.5;
input double   InpTrailDistanceR        = 0.75;
input int      InpSlippagePoints        = 20;
input ulong    InpMagicNumber           = 5152026;

enum SetupDirection { SETUP_NONE=0, SETUP_BUY=1, SETUP_SELL=-1 };

CTrade trade;
int atrHandle = INVALID_HANDLE;
datetime lastM15Bar = 0, lastM5Bar = 0;
SetupDirection setupDirection = SETUP_NONE;
double setupLevel = 0.0;
datetime setupTime = 0;
int setupAgeM5 = 0;

int OnInit()
{
   if(InpM15Lookback < 3 || InpRiskReward <= 0 || InpRiskPercent <= 0)
      return INIT_PARAMETERS_INCORRECT;

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   atrHandle = iATR(_Symbol, PERIOD_M5, InpATRPeriod);
   if(atrHandle == INVALID_HANDLE) return INIT_FAILED;

   DrawStatus("Waiting for M15 breakout");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   ObjectDelete(0, "BR_Level");
   Comment("");
}

void OnTick()
{
   ManageOpenPosition();

   datetime m15 = iTime(_Symbol, PERIOD_M15, 0);
   if(m15 != 0 && m15 != lastM15Bar)
   {
      lastM15Bar = m15;
      DetectM15Breakout();
   }

   datetime m5 = iTime(_Symbol, PERIOD_M5, 0);
   if(m5 != 0 && m5 != lastM5Bar)
   {
      lastM5Bar = m5;
      ProcessM5Retest();
   }
}

void DetectM15Breakout()
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int needed = InpM15Lookback + 3;
   if(CopyRates(_Symbol, PERIOD_M15, 0, needed, rates) < needed) return;

   // rates[1] is the newly closed breakout candidate. Build structure from
   // candles before it so the candidate cannot move its own breakout level.
   double resistance = rates[2].high;
   double support = rates[2].low;
   for(int i=3; i<InpM15Lookback+2; i++)
   {
      resistance = MathMax(resistance, rates[i].high);
      support = MathMin(support, rates[i].low);
   }

   double buffer = InpBreakBufferPoints * _Point;
   bool bullBreak = rates[1].close > resistance + buffer && rates[1].close > rates[1].open;
   bool bearBreak = rates[1].close < support - buffer && rates[1].close < rates[1].open;

   if(bullBreak)
      ArmSetup(SETUP_BUY, resistance, rates[1].time);
   else if(bearBreak)
      ArmSetup(SETUP_SELL, support, rates[1].time);
}

void ArmSetup(SetupDirection direction, double level, datetime signalTime)
{
   setupDirection = direction;
   setupLevel = NormalizeDouble(level, _Digits);
   setupTime = signalTime;
   setupAgeM5 = 0;

   ObjectDelete(0, "BR_Level");
   ObjectCreate(0, "BR_Level", OBJ_HLINE, 0, 0, setupLevel);
   ObjectSetInteger(0, "BR_Level", OBJPROP_COLOR,
                    direction == SETUP_BUY ? clrLimeGreen : clrTomato);
   ObjectSetInteger(0, "BR_Level", OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, "BR_Level", OBJPROP_WIDTH, 2);
   DrawStatus(direction == SETUP_BUY ? "BUY breakout: waiting for M5 retest" :
                                      "SELL breakout: waiting for M5 retest");
}

void ProcessM5Retest()
{
   if(setupDirection == SETUP_NONE) return;
   setupAgeM5++;
   if(setupAgeM5 > InpSetupExpiryM5Bars)
   {
      CancelSetup("Setup expired");
      return;
   }

   if(InpOnePositionOnly && HasOurPosition()) return;

   MqlRates bar[];
   ArraySetAsSeries(bar, true);
   if(CopyRates(_Symbol, PERIOD_M5, 0, 3, bar) < 3) return;

   double tolerance = InpRetestTolerancePts * _Point;
   double body = MathAbs(bar[1].close - bar[1].open);
   if(body < _Point) return;
   double upperWick = bar[1].high - MathMax(bar[1].open, bar[1].close);
   double lowerWick = MathMin(bar[1].open, bar[1].close) - bar[1].low;
   bool wickOK = MathMax(upperWick, lowerWick) / body <= InpMaxWickBodyRatio;

   // Invalidate if the confirmation candle closes decisively through the level.
   if(setupDirection == SETUP_BUY && bar[1].close < setupLevel - tolerance)
   {
      CancelSetup("BUY retest failed");
      return;
   }
   if(setupDirection == SETUP_SELL && bar[1].close > setupLevel + tolerance)
   {
      CancelSetup("SELL retest failed");
      return;
   }

   bool buyRetest = setupDirection == SETUP_BUY &&
                    bar[1].low <= setupLevel + tolerance &&
                    bar[1].high >= setupLevel - tolerance &&
                    bar[1].close > setupLevel && wickOK;
   bool sellRetest = setupDirection == SETUP_SELL &&
                     bar[1].high >= setupLevel - tolerance &&
                     bar[1].low <= setupLevel + tolerance &&
                     bar[1].close < setupLevel && wickOK;

   if(InpRequireBodyDirection)
   {
      buyRetest = buyRetest && bar[1].close > bar[1].open;
      sellRetest = sellRetest && bar[1].close < bar[1].open;
   }

   if(!buyRetest && !sellRetest) return;
   if(CurrentSpreadPoints() > InpMaxSpreadPoints)
   {
      DrawStatus("Retest confirmed; spread too high");
      return;
   }

   PlaceTrade(buyRetest ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, bar[1]);
}

void PlaceTrade(ENUM_ORDER_TYPE orderType, const MqlRates &confirmBar)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   double atr = GetATR();
   if(atr <= 0) return;

   double entry = orderType == ORDER_TYPE_BUY ? tick.ask : tick.bid;
   double atrBuffer = atr * InpSL_ATR_Buffer;
   double sl = orderType == ORDER_TYPE_BUY ? confirmBar.low - atrBuffer
                                           : confirmBar.high + atrBuffer;
   sl = EnforceMinimumStop(orderType, entry, sl);
   double riskDistance = MathAbs(entry - sl);
   if(riskDistance <= 0) return;
   double tp = orderType == ORDER_TYPE_BUY ? entry + riskDistance * InpRiskReward
                                           : entry - riskDistance * InpRiskReward;

   double lots = InpUseRiskPercent ? CalculateRiskLot(riskDistance) : NormalizeLots(InpFixedLot);
   if(lots <= 0)
   {
      DrawStatus("Lot calculation failed");
      return;
   }

   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);
   string comment = "M15Break_M5Retest";
   bool placed = orderType == ORDER_TYPE_BUY
                 ? trade.Buy(lots, _Symbol, 0.0, sl, tp, comment)
                 : trade.Sell(lots, _Symbol, 0.0, sl, tp, comment);

   if(placed)
   {
      CancelSetup("Trade placed");
      DrawStatus(StringFormat("%s %.2f lots | SL %.*f | TP %.*f",
                 orderType == ORDER_TYPE_BUY ? "BUY" : "SELL", lots,
                 _Digits, sl, _Digits, tp));
   }
   else
      DrawStatus("Order failed: " + trade.ResultRetcodeDescription());
}

double CalculateRiskLot(double stopDistance)
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * InpRiskPercent / 100.0;
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0) tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0 || stopDistance <= 0) return 0;
   double lossPerLot = (stopDistance / tickSize) * tickValue;
   if(lossPerLot <= 0) return 0;
   double rawLots = riskMoney / lossPerLot;
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   // Some Deriv symbols have a large minimum lot. Do not silently exceed the
   // requested account risk unless the trader explicitly permits it.
   if(rawLots < minLot && !InpAllowMinLotOverRisk) return 0;
   return NormalizeLots(rawLots);
}

double NormalizeLots(double lots)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0) return 0;
   lots = MathFloor(lots / step + 1e-8) * step;
   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;
   int volDigits = 0;
   double testStep = step;
   while(volDigits < 8 && MathAbs(testStep - MathRound(testStep)) > 1e-8)
   {
      testStep *= 10.0;
      volDigits++;
   }
   return NormalizeDouble(lots, volDigits);
}

double EnforceMinimumStop(ENUM_ORDER_TYPE type, double entry, double proposedSL)
{
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minimum = MathMax(stopsLevel * _Point, _Point);
   if(type == ORDER_TYPE_BUY) return MathMin(proposedSL, entry - minimum);
   return MathMax(proposedSL, entry + minimum);
}

void ManageOpenPosition()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      double current = type == POSITION_TYPE_BUY
                       ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                       : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double initialRisk = 0.0;
      if(tp > 0) initialRisk = MathAbs(tp - open) / InpRiskReward;
      else if(sl > 0) initialRisk = MathAbs(open - sl);
      if(initialRisk <= 0) continue;

      double profitDistance = type == POSITION_TYPE_BUY ? current-open : open-current;
      double newSL = sl;

      if(InpMoveToBreakeven && profitDistance >= initialRisk * InpBreakevenAtR)
      {
         double be = type == POSITION_TYPE_BUY ? open + InpBreakevenPlusPoints*_Point
                                                : open - InpBreakevenPlusPoints*_Point;
         if(type == POSITION_TYPE_BUY && (sl == 0 || be > newSL)) newSL = be;
         if(type == POSITION_TYPE_SELL && (sl == 0 || be < newSL)) newSL = be;
      }

      if(InpUseTrailingStop && profitDistance >= initialRisk * InpTrailStartR)
      {
         double trail = type == POSITION_TYPE_BUY ? current - initialRisk*InpTrailDistanceR
                                                   : current + initialRisk*InpTrailDistanceR;
         if(type == POSITION_TYPE_BUY && trail > newSL) newSL = trail;
         if(type == POSITION_TYPE_SELL && (newSL == 0 || trail < newSL)) newSL = trail;
      }

      newSL = NormalizeDouble(newSL, _Digits);
      if(newSL != sl && newSL > 0)
         trade.PositionModify(ticket, newSL, tp);
   }
}

bool HasOurPosition()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) return true;
   }
   return false;
}

double GetATR()
{
   double value[];
   ArraySetAsSeries(value, true);
   if(CopyBuffer(atrHandle, 0, 1, 1, value) != 1) return 0;
   return value[0];
}

double CurrentSpreadPoints()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return DBL_MAX;
   return (tick.ask - tick.bid) / _Point;
}

void CancelSetup(string reason)
{
   setupDirection = SETUP_NONE;
   setupLevel = 0;
   setupTime = 0;
   setupAgeM5 = 0;
   ObjectDelete(0, "BR_Level");
   DrawStatus(reason);
}

void DrawStatus(string message)
{
   string setup = "NONE";
   if(setupDirection == SETUP_BUY) setup = "BUY";
   if(setupDirection == SETUP_SELL) setup = "SELL";
   Comment("M15 BREAK + M5 RETEST EA\n",
           "Status: ", message, "\n",
           "Setup: ", setup,
           setupDirection == SETUP_NONE ? "" : StringFormat(" @ %.*f", _Digits, setupLevel), "\n",
           "Spread: ", DoubleToString(CurrentSpreadPoints(), 1), " points\n",
           "Risk: ", DoubleToString(InpRiskPercent, 2), "% | RR 1:",
           DoubleToString(InpRiskReward, 2));
}
