//+------------------------------------------------------------------+
//|                                          SR_Retest_System.mq5    |
//|   Mechanical M15 Structure / M5 Execution Support & Resistance  |
//|   Retest System for high-volatility / synthetic index symbols   |
//|   (Volatility, Boom, Crash, Step, Jump).                        |
//|                                                                  |
//|   Fully rule-based finite state machine:                        |
//|     0 SCANNING -> 1 BREAKOUT -> 2 PULLBACK -> 3 VALIDATION       |
//|     -> 4 EXECUTION -> (structural invalidation / decay exit)    |
//|     -> back to 0                                                 |
//|                                                                  |
//|   NOTE ON SCOPE: This is built as an EXPERT ADVISOR, not a pure |
//|   indicator, because Phase 4/5 of the spec require live trade   |
//|   execution and an emergency market-exit command. An indicator  |
//|   cannot send orders. If you actually want a passive drawing-   |
//|   only indicator version (zones + dashboard, no order sending), |
//|   say so and I will strip Phase 4/5 order calls out.            |
//+------------------------------------------------------------------+
#property copyright "Money Pree"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//====================================================================
// INPUTS
//====================================================================
input group "=== Zone Detection (M15 structure) ==="
input int    InpSwingLookback      = 3;      // bars each side to confirm an M15 swing point
input int    InpZoneScanBars       = 300;    // how many M15 bars back to scan for zones
input double InpZoneMinPercent     = 0.001;  // zone width floor = 0.1% of price
input double InpZoneMaxPercent     = 0.003;  // zone width ceiling = 0.3% of price (near round numbers)
input double InpRoundStep          = 100.0;  // psychological round-number step (adjust per symbol digits)
input int    InpZonesAbove         = 3;      // number of resistance zones to keep above price
input int    InpZonesBelow         = 3;      // number of support zones to keep below price
input int    InpFibLookback        = 50;     // M15 bars used to find the major structural leg

input group "=== Confluence / EMA ==="
input int    InpEMA_Fast           = 20;     // M15 EMA fast period
input int    InpEMA_Slow           = 50;     // M15 EMA slow period
input int    InpMinConfluence      = 2;      // minimum confluence factors required to validate a zone

input group "=== Scoring Engine ==="
input double InpScoreThreshold     = 7.0;    // minimum |directional score| to allow State3 -> State4

input group "=== Momentum Decay Loop (State 4) ==="
input int    InpATR_Period         = 14;     // ATR period (M5)
input int    InpGraceBars          = 3;      // bars before velocity is checked
input double InpMinATRPerBar       = 0.25;   // minimum acceptable ATR-normalized velocity

input group "=== Trade Execution ==="
input bool   InpEnableTrading      = true;   // false = build zones/state machine/dashboard only, no orders
input double InpLotSize            = 0.10;
input int    InpMagicNumber        = 552024;
input int    InpSlippagePoints     = 50;

input group "=== Visuals ==="
input bool   InpForceCanvas        = true;   // enforce black-ground/pure candle color/no-grid canvas
input bool   InpDrawZones          = true;

//====================================================================
// STATE MACHINE TYPES
//====================================================================
enum ENUM_SETUP_STATE
  {
   STATE_SCANNING   = 0,
   STATE_BREAKOUT   = 1,
   STATE_PULLBACK   = 2,
   STATE_VALIDATION = 3,
   STATE_EXECUTION  = 4
  };

struct SRZone
  {
   double high;
   double low;
   double mid;
   int    type;        // +1 = Resistance, -1 = Support
   int    confluence;  // number of confluence factors that validated this zone
   int    barShift;    // M15 bar shift the zone's swing point formed at (for scoring lookups)
  };

//====================================================================
// GLOBALS
//====================================================================
CTrade         trade;

SRZone         g_zones[];

ENUM_SETUP_STATE g_state          = STATE_SCANNING;
int              g_tradeDirection = 0;      // +1 long, -1 short, 0 none
double           g_setupScore     = 0.0;    // last computed DIRECTIONAL score (-10..+10)

double           g_lockedLH       = 0.0;    // locked previous Lower High (short invalidation ref)
double           g_lockedHL       = 0.0;    // locked previous Higher Low  (long invalidation ref)

int              g_brokenZoneIdx  = -1;     // index into g_zones of the zone that was broken
datetime         g_breakoutTime   = 0;      // time of the M15 breakout close

ulong            g_positionTicket = 0;
double           g_entryPrice     = 0.0;
long             g_entryBarIndex  = 0;
long             g_barIndexM5     = 0;      // running counter of closed M5 bars
double           g_currentVelocity= 0.0;

int              g_emaFastHandle  = INVALID_HANDLE;
int              g_emaSlowHandle  = INVALID_HANDLE;
int              g_atrM15Handle   = INVALID_HANDLE;
int              g_atrM5Handle    = INVALID_HANDLE;

datetime         g_lastM15BarTime = 0;
datetime         g_lastM5BarTime  = 0;

#define ZONE_PREFIX "SR_Zone_"
#define DASH_PREFIX "SR_Dash_"

//====================================================================
// INIT / DEINIT
//====================================================================
int OnInit()
  {
   if(InpForceCanvas)
      SetupVisualCanvas();

   g_emaFastHandle = iMA(_Symbol, PERIOD_M15, InpEMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   g_emaSlowHandle = iMA(_Symbol, PERIOD_M15, InpEMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   g_atrM15Handle  = iATR(_Symbol, PERIOD_M15, InpATR_Period);
   g_atrM5Handle   = iATR(_Symbol, PERIOD_M5,  InpATR_Period);

   if(g_emaFastHandle==INVALID_HANDLE || g_emaSlowHandle==INVALID_HANDLE ||
      g_atrM15Handle==INVALID_HANDLE  || g_atrM5Handle==INVALID_HANDLE)
     {
      Print("SR_Retest_System: failed to create one or more indicator handles.");
      return(INIT_FAILED);
     }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

   ExecuteStateReset(false); // initial clean state, do not chain-rescan on init

   BuildZones();
   UpdateDashboard();

   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   IndicatorRelease(g_emaFastHandle);
   IndicatorRelease(g_emaSlowHandle);
   IndicatorRelease(g_atrM15Handle);
   IndicatorRelease(g_atrM5Handle);

   ObjectsDeleteAll(0, ZONE_PREFIX);
   ObjectsDeleteAll(0, DASH_PREFIX);
  }

//====================================================================
// MAIN TICK LOOP
//====================================================================
void OnTick()
  {
   bool newM15 = IsNewBar(PERIOD_M15, g_lastM15BarTime);
   bool newM5  = IsNewBar(PERIOD_M5,  g_lastM5BarTime);

   if(newM15)
     {
      BuildZones();
      if(g_state == STATE_SCANNING)
         CheckForBreakout();
     }

   if(newM5)
     {
      g_barIndexM5++;

      if(g_state == STATE_PULLBACK)
         CheckForPullbackSwing();
      else if(g_state == STATE_VALIDATION)
         EvaluateScoreAndMaybeExecute();

      // Per spec: invalidation is exclusively M5 body-close based, and only applies
      // once a structural reference point is locked (State 3 Validation onward).
      if(g_state == STATE_VALIDATION || g_state == STATE_EXECUTION)
         CheckStructuralInvalidation();
     }

   if(g_state == STATE_EXECUTION)
      ManageActiveTradeDecay();

   UpdateDashboard();
  }

//====================================================================
// NEW BAR HELPER
//====================================================================
bool IsNewBar(ENUM_TIMEFRAMES tf, datetime &lastTime)
  {
   datetime t = iTime(_Symbol, tf, 0);
   if(t != lastTime)
     {
      lastTime = t;
      return(true);
     }
   return(false);
  }

//====================================================================
// PHASE 1: ZONE DETECTION & CONFLUENCE MATRIX
//====================================================================
bool IsSwingHigh(int shift, int lookback)
  {
   double h = iHigh(_Symbol, PERIOD_M15, shift);
   for(int j=1; j<=lookback; j++)
     {
      if(iHigh(_Symbol, PERIOD_M15, shift-j) > h) return(false);
      if(iHigh(_Symbol, PERIOD_M15, shift+j) > h) return(false);
     }
   return(true);
  }

bool IsSwingLow(int shift, int lookback)
  {
   double l = iLow(_Symbol, PERIOD_M15, shift);
   for(int j=1; j<=lookback; j++)
     {
      if(iLow(_Symbol, PERIOD_M15, shift-j) < l) return(false);
      if(iLow(_Symbol, PERIOD_M15, shift+j) < l) return(false);
     }
   return(true);
  }

double ZoneWidthForPrice(double price)
  {
   double minW = price * InpZoneMinPercent;
   double maxW = price * InpZoneMaxPercent;

   double nearestRound = MathRound(price / InpRoundStep) * InpRoundStep;
   if(MathAbs(price - nearestRound) <= maxW)
      return(maxW);   // expand near psychological round numbers

   return(minW);
  }

// Finds the dominant swing leg inside InpFibLookback bars of "shift" and returns
// the 61.8% / 78.6% retracement levels measured off that leg's high.
// Simplification note: always measures retracement down from the leg high, which
// is a deliberate simplification to keep this single-pass and deterministic;
// tighten with directional leg detection if you need strict up-leg/down-leg logic.
bool GetMajorLegFibLevels(int shift, double &fib618, double &fib786)
  {
   int startShift = shift;
   int endShift   = MathMin(shift + InpFibLookback, iBars(_Symbol, PERIOD_M15) - 2);
   if(endShift <= startShift) return(false);

   int hiShift = iHighest(_Symbol, PERIOD_M15, MODE_HIGH, endShift-startShift, startShift);
   int loShift = iLowest(_Symbol,  PERIOD_M15, MODE_LOW,  endShift-startShift, startShift);
   if(hiShift < 0 || loShift < 0) return(false);

   double legHigh = iHigh(_Symbol, PERIOD_M15, hiShift);
   double legLow  = iLow(_Symbol,  PERIOD_M15, loShift);
   double range   = legHigh - legLow;
   if(range <= 0) return(false);

   fib618 = legHigh - range * 0.618;
   fib786 = legHigh - range * 0.786;
   return(true);
  }

int CountConfluence(double price, double width, int shift)
  {
   int count = 0;

   // Factor 1: psychological round number
   double nearestRound = MathRound(price / InpRoundStep) * InpRoundStep;
   if(MathAbs(price - nearestRound) <= width/2.0)
      count++;

   // Factor 2: EMA fast / slow (M15) sitting through the level
   double emaFast[], emaSlow[];
   if(CopyBuffer(g_emaFastHandle, 0, shift, 1, emaFast) > 0)
      if(MathAbs(price - emaFast[0]) <= width/2.0) count++;
   if(CopyBuffer(g_emaSlowHandle, 0, shift, 1, emaSlow) > 0)
      if(MathAbs(price - emaSlow[0]) <= width/2.0) count++;

   // Factor 3: Fibonacci 61.8 / 78.6 of the major structural leg
   double fib618, fib786;
   if(GetMajorLegFibLevels(shift, fib618, fib786))
     {
      if(MathAbs(price - fib618) <= width/2.0) count++;
      if(MathAbs(price - fib786) <= width/2.0) count++;
     }

   return(count);
  }

void TryAddZone(double price, int type, int shift)
  {
   double width = ZoneWidthForPrice(price);
   int    conf  = CountConfluence(price, width, shift);
   if(conf < InpMinConfluence) return;

   int n = ArraySize(g_zones);
   ArrayResize(g_zones, n+1);
   g_zones[n].mid        = price;
   g_zones[n].high       = price + width/2.0;
   g_zones[n].low        = price - width/2.0;
   g_zones[n].type       = type;
   g_zones[n].confluence = conf;
   g_zones[n].barShift   = shift;
  }

// Rebuilds the full zone map, then trims to the nearest N zones above/below price
// so the state machine is only ever comparing against the live "map" (matches the
// earlier strategy: 2-3 major zones above and below current price).
void BuildZones()
  {
   ArrayResize(g_zones, 0);

   int totalBars = MathMin(InpZoneScanBars, iBars(_Symbol, PERIOD_M15) - InpSwingLookback - 2);
   if(totalBars < InpSwingLookback*2 + 5) return;

   for(int shift=InpSwingLookback; shift<totalBars; shift++)
     {
      if(IsSwingHigh(shift, InpSwingLookback))
         TryAddZone(iHigh(_Symbol, PERIOD_M15, shift), 1, shift);
      if(IsSwingLow(shift, InpSwingLookback))
         TryAddZone(iLow(_Symbol, PERIOD_M15, shift), -1, shift);
     }

   TrimZonesToNearest();

   if(InpDrawZones)
      DrawZonesOnChart();
  }

void TrimZonesToNearest()
  {
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   SRZone kept[];

   // simple selection: repeatedly pull the closest resistance / support zones
   int aboveCount = 0, belowCount = 0;
   // sort copy by distance to price using a naive pass since zone counts are small
   int n = ArraySize(g_zones);
   bool used[];
   ArrayResize(used, n);
   ArrayInitialize(used, false);

   while(aboveCount < InpZonesAbove)
     {
      int best = -1; double bestDist = DBL_MAX;
      for(int i=0;i<n;i++)
        {
         if(used[i] || g_zones[i].type != 1 || g_zones[i].mid <= price) continue;
         double d = g_zones[i].mid - price;
         if(d < bestDist) { bestDist = d; best = i; }
        }
      if(best < 0) break;
      used[best] = true;
      int k = ArraySize(kept); ArrayResize(kept, k+1); kept[k] = g_zones[best];
      aboveCount++;
     }

   while(belowCount < InpZonesBelow)
     {
      int best = -1; double bestDist = DBL_MAX;
      for(int i=0;i<n;i++)
        {
         if(used[i] || g_zones[i].type != -1 || g_zones[i].mid >= price) continue;
         double d = price - g_zones[i].mid;
         if(d < bestDist) { bestDist = d; best = i; }
        }
      if(best < 0) break;
      used[best] = true;
      int k = ArraySize(kept); ArrayResize(kept, k+1); kept[k] = g_zones[best];
      belowCount++;
     }

   ArrayFree(g_zones);
   ArrayResize(g_zones, ArraySize(kept));
   for(int i=0;i<ArraySize(kept);i++)
      g_zones[i] = kept[i];
  }

//====================================================================
// PHASE 2/3: STATE MACHINE - BREAKOUT / PULLBACK / VALIDATION
//====================================================================
// STATE_SCANNING -> STATE_BREAKOUT trigger point. Since a clean M15 body-close
// breakout is a single-bar event, we detect it and move straight into
// STATE_PULLBACK (State 1 is logged/instantaneous rather than persisted).
void CheckForBreakout()
  {
   double open1  = iOpen(_Symbol,  PERIOD_M15, 1);
   double close1 = iClose(_Symbol, PERIOD_M15, 1);

   for(int i=0;i<ArraySize(g_zones);i++)
     {
      if(g_zones[i].type == 1 && close1 > g_zones[i].high && open1 < g_zones[i].high)
        {
         StartBreakout(i, 1, close1);
         return;
        }
      if(g_zones[i].type == -1 && close1 < g_zones[i].low && open1 > g_zones[i].low)
        {
         StartBreakout(i, -1, close1);
         return;
        }
     }
  }

void StartBreakout(int zoneIdx, int direction, double breakoutClose)
  {
   g_brokenZoneIdx  = zoneIdx;
   g_tradeDirection = direction;
   g_breakoutTime   = iTime(_Symbol, PERIOD_M15, 1);
   g_state          = STATE_PULLBACK;
   Print("SR_Retest_System: STATE_BREAKOUT -> STATE_PULLBACK, direction=", direction,
         " zone[", zoneIdx, "] mid=", g_zones[zoneIdx].mid);
  }

// Watches M5 bars since the breakout for the first confirmed swing pivot in the
// retracement direction (Higher Low for longs, Lower High for shorts). Once
// confirmed, locks it as the structural invalidation reference and advances to
// STATE_VALIDATION.
void CheckForPullbackSwing()
  {
   // need at least 3 M5 bars closed since breakout to confirm a 1-bar-each-side pivot
   int shift = 2; // confirmed pivot bar (1 bar of confirmation either side)
   if(iTime(_Symbol, PERIOD_M5, shift+1) < g_breakoutTime) return; // not enough bars yet

   if(g_tradeDirection == 1)
     {
      // looking for a confirmed local LOW (Higher Low) pivot
      double lo = iLow(_Symbol, PERIOD_M5, shift);
      if(lo < iLow(_Symbol, PERIOD_M5, shift-1) && lo < iLow(_Symbol, PERIOD_M5, shift+1))
        {
         g_lockedHL = lo;
         g_state    = STATE_VALIDATION;
         Print("SR_Retest_System: STATE_PULLBACK -> STATE_VALIDATION, locked HL=", g_lockedHL);
        }
     }
   else if(g_tradeDirection == -1)
     {
      // looking for a confirmed local HIGH (Lower High) pivot
      double hi = iHigh(_Symbol, PERIOD_M5, shift);
      if(hi > iHigh(_Symbol, PERIOD_M5, shift-1) && hi > iHigh(_Symbol, PERIOD_M5, shift+1))
        {
         g_lockedLH = hi;
         g_state    = STATE_VALIDATION;
         Print("SR_Retest_System: STATE_PULLBACK -> STATE_VALIDATION, locked LH=", g_lockedLH);
        }
     }
  }

//====================================================================
// PHASE 3: DIRECTION-AWARE SCORING ENGINE
//====================================================================
double ComputeLevelQuality()
  {
   if(g_brokenZoneIdx < 0 || g_brokenZoneIdx >= ArraySize(g_zones)) return(0.0);
   SRZone z = g_zones[g_brokenZoneIdx];

   double atr[];
   if(CopyBuffer(g_atrM15Handle, 0, z.barShift, 1, atr) <= 0) return(0.0);
   if(atr[0] <= 0) return(0.0);

   double swingRange = iHigh(_Symbol, PERIOD_M15, z.barShift) - iLow(_Symbol, PERIOD_M15, z.barShift);
   double rejRatio = swingRange / atr[0];

   return(MathMin(3.0, rejRatio));
  }

double ComputeBreakDisplacement()
  {
   double atr[];
   if(CopyBuffer(g_atrM15Handle, 0, 1, 1, atr) <= 0) return(0.0);
   if(atr[0] <= 0) return(0.0);

   double body = MathAbs(iClose(_Symbol, PERIOD_M15, 1) - iOpen(_Symbol, PERIOD_M15, 1));
   double ratio = body / atr[0];

   return(MathMin(3.0, ratio));
  }

double ComputeRetestExhaustion()
  {
   // average range of the last 3 closed M5 candles vs the range of the M5 candle
   // that closed right at breakout time (the "initial impulse" candle)
   int breakoutShift = iBarShift(_Symbol, PERIOD_M5, g_breakoutTime, true);
   if(breakoutShift < 0) return(0.0);

   double initialRange = iHigh(_Symbol, PERIOD_M5, breakoutShift) - iLow(_Symbol, PERIOD_M5, breakoutShift);
   if(initialRange <= 0) return(0.0);

   double sumRecent = 0.0;
   int count = 0;
   for(int s=1; s<=3; s++)
     {
      if(s >= breakoutShift) break;
      sumRecent += (iHigh(_Symbol, PERIOD_M5, s) - iLow(_Symbol, PERIOD_M5, s));
      count++;
     }
   if(count == 0) return(0.0);

   double avgRecent = sumRecent / count;
   double exhaustionRatio = 1.0 - (avgRecent / initialRange);
   exhaustionRatio = MathMax(0.0, MathMin(1.0, exhaustionRatio));

   return(exhaustionRatio * 4.0);
  }

// Runs each new M5 bar while in STATE_VALIDATION. Recomputes the full scorecard,
// applies the CRITICAL MATHEMATICAL LAW (total * direction), and advances to
// STATE_EXECUTION if the directional threshold is met.
void EvaluateScoreAndMaybeExecute()
  {
   double total = ComputeLevelQuality() + ComputeBreakDisplacement() + ComputeRetestExhaustion();
   double directional = total * g_tradeDirection;
   g_setupScore = directional;

   bool trigger = (g_tradeDirection == 1  && directional >= InpScoreThreshold) ||
                  (g_tradeDirection == -1 && directional <= -InpScoreThreshold);

   if(trigger)
      ExecuteEntry();
  }

//====================================================================
// TRADE EXECUTION (STATE 4 ENTRY)
//====================================================================
void ExecuteEntry()
  {
   if(!InpEnableTrading)
     {
      // Score/state model still advances even with trading disabled, useful for
      // dry-running the logic before letting it touch a live/demo account.
      g_state = STATE_EXECUTION;
      g_entryPrice    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      g_entryBarIndex = g_barIndexM5;
      return;
     }

   double price = (g_tradeDirection == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                            : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Macro stop loss sits just beyond the locked structural point (the pullback
   // pivot). This is the "macro stop loss" that the velocity decay exit is
   // permitted to bypass per Phase 5.
   double sl = (g_tradeDirection == 1) ? g_lockedHL : g_lockedLH;

   bool ok;
   if(g_tradeDirection == 1)
      ok = trade.Buy(InpLotSize, _Symbol, price, sl, 0.0, "SR_Retest_Long");
   else
      ok = trade.Sell(InpLotSize, _Symbol, price, sl, 0.0, "SR_Retest_Short");

   if(!ok)
     {
      Print("SR_Retest_System: order send failed, retcode=", trade.ResultRetcode());
      ExecuteStateReset(true);
      return;
     }

   if(PositionSelect(_Symbol))
      g_positionTicket = (ulong)PositionGetInteger(POSITION_TICKET);

   g_entryPrice    = price;
   g_entryBarIndex = g_barIndexM5;
   g_state         = STATE_EXECUTION;

   Print("SR_Retest_System: STATE_VALIDATION -> STATE_EXECUTION, score=", g_setupScore,
         " entry=", g_entryPrice, " sl=", sl);
  }

//====================================================================
// PHASE 4: STRUCTURAL INVALIDATION (M5 body close only, wicks ignored)
//====================================================================
void CheckStructuralInvalidation()
  {
   double close1 = iClose(_Symbol, PERIOD_M5, 1);

   bool invalidated = false;
   if(g_tradeDirection == -1 && g_lockedLH > 0 && close1 > g_lockedLH)
      invalidated = true;
   else if(g_tradeDirection == 1 && g_lockedHL > 0 && close1 < g_lockedHL)
      invalidated = true;

   if(invalidated)
     {
      Print("SR_Retest_System: structural invalidation on M5 close=", close1, " -> resetting.");
      if(g_state == STATE_EXECUTION)
         CloseActivePosition();
      ExecuteStateReset(true); // chain-rescan same tick so a new setup isn't missed
     }
  }

//====================================================================
// PHASE 5: ATR-NORMALIZED MOMENTUM DECAY LOOP (runs every tick in State 4)
//====================================================================
void ManageActiveTradeDecay()
  {
   if(g_positionTicket == 0 || !PositionSelectByTicket(g_positionTicket))
     {
      // position closed externally (SL hit, manual close, etc.) -> reset
      ExecuteStateReset(true);
      return;
     }

   long elapsedBars = g_barIndexM5 - g_entryBarIndex;
   if(elapsedBars < InpGraceBars) return;

   double atr[];
   if(CopyBuffer(g_atrM5Handle, 0, 0, 1, atr) <= 0 || atr[0] <= 0) return;

   double currentPrice = (g_tradeDirection == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                                   : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double distanceInATR = ((currentPrice - g_entryPrice) * g_tradeDirection) / atr[0];
   double velocity = distanceInATR / (double)elapsedBars;
   g_currentVelocity = velocity;

   if(velocity < InpMinATRPerBar || distanceInATR < 0)
     {
      Print("SR_Retest_System: momentum decay exit. velocity=", velocity,
            " distanceInATR=", distanceInATR);
      CloseActivePosition();      // market scratch, bypasses the macro SL
      ExecuteStateReset(true);
     }
  }

void CloseActivePosition()
  {
   if(g_positionTicket != 0 && PositionSelectByTicket(g_positionTicket))
      trade.PositionClose(g_positionTicket);
   g_positionTicket = 0;
  }

//====================================================================
// GARBAGE COLLECTION / STATE RESET
//====================================================================
// chainRescan=true re-invokes the scanning check within the same tick so an
// immediate subsequent breakout right after an invalidation isn't missed.
void ExecuteStateReset(bool chainRescan)
  {
   g_state          = STATE_SCANNING;
   g_tradeDirection = 0;
   g_setupScore     = 0.0;
   g_lockedLH       = 0.0;
   g_lockedHL       = 0.0;
   g_brokenZoneIdx  = -1;
   g_breakoutTime   = 0;
   g_positionTicket = 0;
   g_entryPrice     = 0.0;
   g_entryBarIndex  = 0;
   g_currentVelocity= 0.0;

   if(chainRescan)
      CheckForBreakout();
  }

//====================================================================
// VISUAL CANVAS (Section 1 requirements)
//====================================================================
void SetupVisualCanvas()
  {
   ChartSetInteger(0, CHART_COLOR_BACKGROUND, C'30,40,50');
   ChartSetInteger(0, CHART_COLOR_CANDLE_BULL, clrLime);
   ChartSetInteger(0, CHART_COLOR_CANDLE_BEAR, clrRed);
   ChartSetInteger(0, CHART_COLOR_CHART_UP,   clrLime);
   ChartSetInteger(0, CHART_COLOR_CHART_DOWN, clrRed);
   ChartSetInteger(0, CHART_COLOR_CHART_LINE, clrLime);
   ChartSetInteger(0, CHART_MODE, CHART_CANDLES);

   ChartSetInteger(0, CHART_SHOW_GRID, false);
   ChartSetInteger(0, CHART_SHOW_VOLUMES, false);
  }

// Draws each zone in the current zone map as a shaded rectangle from its forming
// bar out to the current time.
void DrawZonesOnChart()
  {
   ObjectsDeleteAll(0, ZONE_PREFIX);
   datetime nowTime = TimeCurrent() + PeriodSeconds(PERIOD_M15) * 10;

   for(int i=0;i<ArraySize(g_zones);i++)
     {
      string name = ZONE_PREFIX + IntegerToString(i);
      datetime t1 = iTime(_Symbol, PERIOD_M15, g_zones[i].barShift);

      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, g_zones[i].high, nowTime, g_zones[i].low);
      ObjectSetInteger(0, name, OBJPROP_COLOR, g_zones[i].type==1 ? clrOrangeRed : clrDeepSkyBlue);
      ObjectSetInteger(0, name, OBJPROP_FILL, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
     }
  }

//====================================================================
// HEADS-UP DASHBOARD
//====================================================================
void SetLabel(string name, string text, int x, int y, color clr, int fontSize)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
     }
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
  }

string StateToString(ENUM_SETUP_STATE s)
  {
   switch(s)
     {
      case STATE_SCANNING:   return("0 SCANNING");
      case STATE_BREAKOUT:   return("1 BREAKOUT");
      case STATE_PULLBACK:   return("2 PULLBACK");
      case STATE_VALIDATION: return("3 VALIDATION");
      case STATE_EXECUTION:  return("4 EXECUTION");
     }
   return("?");
  }

void UpdateDashboard()
  {
   SetLabel(DASH_PREFIX+"Title", "SR RETEST SYSTEM", 20, 20, clrWhite, 10);
   SetLabel(DASH_PREFIX+"State", "State: " + StateToString(g_state), 20, 40, clrWhite, 9);
   SetLabel(DASH_PREFIX+"Score", "Score: " + DoubleToString(g_setupScore, 1) + " / +-" +
            DoubleToString(InpScoreThreshold,1), 20, 58, clrWhite, 9);

   string structStatus = (g_state >= STATE_VALIDATION) ? "Valid" : "N/A";
   color  structColor  = (g_state >= STATE_VALIDATION) ? clrLime : clrSilver;
   SetLabel(DASH_PREFIX+"Struct", "M5 Structure: " + structStatus, 20, 76, structColor, 9);

   double decayFactor = (InpMinATRPerBar > 0) ? g_currentVelocity / InpMinATRPerBar : 0.0;
   color  decayColor   = (decayFactor >= 1.0) ? clrLime : clrRed;
   string decayText    = (g_state == STATE_EXECUTION)
                           ? "Decay Factor: " + DoubleToString(decayFactor, 2)
                           : "Decay Factor: --";
   SetLabel(DASH_PREFIX+"Decay", decayText, 20, 94, decayColor, 9);
  }
//+------------------------------------------------------------------+