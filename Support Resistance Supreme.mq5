//+------------------------------------------------------------------+
//|                              Support Resistance Supreme.mq5      |
//|        Validated M15 structure break + M5 retest continuation    |
//+------------------------------------------------------------------+
#property copyright "Keyaka Neil"
#property version   "1.01"
#property strict
#property description "M15 support/resistance breakout and M5 structural retest EA"

#include <Trade/Trade.mqh>

#define DIR_NONE   0
#define DIR_LONG   1
#define DIR_SHORT -1

#define STATE_SCANNING   0
#define STATE_BREAKOUT   1
#define STATE_PULLBACK   2
#define STATE_VALIDATION 3
#define STATE_EXECUTION  4

input group "=== OPERATION ==="
// New input name in v1.01 intentionally discards the old persisted
// signal-only value on existing charts. Live execution is now the default.
input bool   InpExecuteLiveTrades       = true;    // True = send real market orders
input bool   InpApplyChartTheme         = true;    // Enforce clean DarkSlateGray canvas
input bool   InpShowDashboard           = true;
input bool   InpEnableAlerts            = true;
input bool   InpEnablePushNotifications = false;
input ulong  InpMagicNumber             = 7202026;

input group "=== M15 SUPPORT / RESISTANCE ==="
input int    InpM15Lookback             = 80;
input int    InpM15SwingStrength        = 2;
input int    InpMinimumLevelTouches     = 2;
input int    InpBarsBetweenTouches      = 3;
input int    InpReactionMeasurementBars = 4;
input double InpZoneWidthATR            = 0.15;

input group "=== BREAKOUT DISPLACEMENT ==="
input int    InpBreakBufferPoints       = 10;
input double InpBreakBufferATR          = 0.05;
input double InpMinimumBreakBodyATR     = 0.60;
input double InpMinimumBreakRangeATR    = 0.90;
input double InpBreakVolumeFactor       = 1.20;
input int    InpMinimumBreakScore       = 2;       // 0..3

input group "=== M5 STRUCTURE / RETEST ==="
input int    InpM5SwingStrength         = 2;
input int    InpM5StructureLookback     = 240;
input int    InpSetupExpiryM5Bars       = 12;
input double InpRetestApproachATR       = 0.35;
input double InpRetestTouchATR          = 0.12;
input double InpMaximumRetestBodyATR    = 0.60;
input double InpDecelerationFactor      = 0.85;
input double InpRetestWickBodyRatio     = 1.00;
input int    InpMinimumDirectionalScore = 7;       // Absolute threshold, 1..10

input group "=== RISK / EXECUTION ==="
input bool   InpUseRiskPercent          = true;
input double InpRiskPercent             = 1.00;
input double InpFixedLot                = 0.20;
input bool   InpAllowMinLotOverRisk     = false;
input double InpStopATRBuffer           = 0.25;
input double InpRiskReward              = 2.00;
input int    InpMaximumSpreadPoints     = 100;
input int    InpSlippagePoints          = 20;
input bool   InpOnePositionPerSymbol    = true;

input group "=== MOMENTUM DECAY ==="
input int    InpATRPeriod               = 14;
input int    InpGraceBars               = 3;
input double InpMinimumATRPerBar        = 0.25;

input group "=== DASHBOARD POSITION ==="
input int    InpDashboardX              = 14;
input int    InpDashboardY              = 24;

struct SLevel
  {
   bool   found;
   bool   support;
   double center;
   double low;
   double high;
   int    touches;
   int    quality;
   double average_reaction_atr;
   double distance;
  };

CTrade   g_trade;
int      g_atr_m5_handle  = INVALID_HANDLE;
int      g_atr_m15_handle = INVALID_HANDLE;
string   g_prefix;

int      g_current_state  = STATE_SCANNING;
int      g_trade_direction = DIR_NONE;

double   g_locked_prev_lh = 0.0;
double   g_locked_prev_hl = 0.0;
double   g_locked_prev_ll = 0.0;
double   g_locked_prev_hh = 0.0;

double   g_setup_level    = 0.0;
double   g_zone_low       = 0.0;
double   g_zone_high      = 0.0;
datetime g_breakout_time  = 0;
int      g_setup_age_m5   = 0;
bool     g_retest_touched = false;

int      g_level_score    = 0;
int      g_break_score    = 0;
int      g_retest_score   = 0;
int      g_setup_score    = 0;
int      g_directional_score = 0;

double   g_entry_price    = 0.0;
datetime g_entry_time     = 0;
datetime g_entry_bar_time = 0;
double   g_stop_price     = 0.0;
double   g_target_price   = 0.0;
double   g_momentum_decay_factor = 0.0;
ulong    g_position_ticket = 0;
bool     g_virtual_execution = false;

datetime g_last_m5_open   = 0;
datetime g_last_m15_open  = 0;
datetime g_last_alert_time = 0;
string   g_structure_status = "WAITING FOR ALIGNED M5 STRUCTURE";
string   g_status_message   = "Scanning M15 support and resistance";

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpM15Lookback < 20 ||
      InpM15SwingStrength < 1 ||
      InpM5SwingStrength < 1 ||
      InpMinimumLevelTouches < 1 ||
      InpATRPeriod < 2 ||
      InpMinimumBreakScore < 0 || InpMinimumBreakScore > 3 ||
      InpMinimumDirectionalScore < 1 || InpMinimumDirectionalScore > 10 ||
      InpSetupExpiryM5Bars < 1 ||
      InpGraceBars < 1 ||
      InpMinimumATRPerBar <= 0.0 ||
      InpRiskReward <= 0.0 ||
      InpRiskPercent <= 0.0)
      return INIT_PARAMETERS_INCORRECT;

   g_prefix = "SRS_" + IntegerToString((int)ChartID()) + "_";

   g_atr_m5_handle  = iATR(_Symbol, PERIOD_M5, InpATRPeriod);
   g_atr_m15_handle = iATR(_Symbol, PERIOD_M15, InpATRPeriod);
   if(g_atr_m5_handle == INVALID_HANDLE || g_atr_m15_handle == INVALID_HANDLE)
      return INIT_FAILED;

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetAsyncMode(false);

   ApplyChartTheme();
   CreateDashboard();

   g_last_m5_open  = iTime(_Symbol, PERIOD_M5, 0);
   g_last_m15_open = iTime(_Symbol, PERIOD_M15, 0);

   if(!RecoverOpenPosition())
     {
      UpdateScanningZones();
      ScanForM15Breakout();
     }

   UpdateDashboard();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_atr_m5_handle != INVALID_HANDLE)
      IndicatorRelease(g_atr_m5_handle);
   if(g_atr_m15_handle != INVALID_HANDLE)
      IndicatorRelease(g_atr_m15_handle);
   ObjectsDeleteAll(0, g_prefix);
   Comment("");
  }

//+------------------------------------------------------------------+
//| Main event loop                                                  |
//+------------------------------------------------------------------+
void OnTick()
  {
   bool new_m5  = IsNewBar(PERIOD_M5, g_last_m5_open);
   bool new_m15 = IsNewBar(PERIOD_M15, g_last_m15_open);

   if(g_current_state == STATE_EXECUTION)
     {
      if(g_virtual_execution)
         CheckVirtualExit();
      else
        {
         ulong ticket = 0;
         if(!FindOurPosition(ticket))
            ExecuteStateReset("Position closed by stop, target, or user",
                              false, false);
         else
            g_position_ticket = ticket;
        }

      if(g_current_state == STATE_EXECUTION)
         EvaluateMomentumDecay(false);
     }

   // Structural invalidation is evaluated only after a confirmed M5 close.
   if(new_m5)
     {
      if(g_current_state >= STATE_BREAKOUT &&
         g_current_state <= STATE_VALIDATION)
         ProcessConfirmedM5Bar();

      if(g_current_state == STATE_EXECUTION)
         EvaluateMomentumDecay(true);
     }

   // M5 processing intentionally runs first. If it resets on the same tick
   // that an M15 bar closes, the scanner can immediately process that M15 bar.
   if(new_m15 && g_current_state == STATE_SCANNING)
     {
      UpdateScanningZones();
      ScanForM15Breakout();
     }

   UpdateDashboard();
  }

//+------------------------------------------------------------------+
//| New bar detector                                                 |
//+------------------------------------------------------------------+
bool IsNewBar(const ENUM_TIMEFRAMES timeframe, datetime &stored_open)
  {
   datetime current_open = iTime(_Symbol, timeframe, 0);
   if(current_open <= 0 || current_open == stored_open)
      return false;
   stored_open = current_open;
   return true;
  }

//+------------------------------------------------------------------+
//| Read one indicator-buffer value                                  |
//+------------------------------------------------------------------+
bool ReadBufferValue(const int handle, const int shift, double &value)
  {
   double data[1];
   if(handle == INVALID_HANDLE || CopyBuffer(handle, 0, shift, 1, data) != 1)
      return false;
   value = data[0];
   return MathIsValidNumber(value);
  }

//+------------------------------------------------------------------+
//| Exact chart environment                                          |
//+------------------------------------------------------------------+
void ApplyChartTheme()
  {
   if(!InpApplyChartTheme)
      return;

   // User-specified solid RGB(30,40,50), with pure green/red candles.
   ChartSetInteger(0, CHART_COLOR_BACKGROUND, C'30,40,50');
   ChartSetInteger(0, CHART_COLOR_FOREGROUND, clrWhite);
   ChartSetInteger(0, CHART_COLOR_GRID, clrNONE);
   ChartSetInteger(0, CHART_COLOR_CANDLE_BULL, clrLime);
   ChartSetInteger(0, CHART_COLOR_CANDLE_BEAR, clrRed);
   ChartSetInteger(0, CHART_COLOR_CHART_UP, clrLime);
   ChartSetInteger(0, CHART_COLOR_CHART_DOWN, clrRed);
   ChartSetInteger(0, CHART_SHOW_GRID, false);
   ChartSetInteger(0, CHART_SHOW_VOLUMES, CHART_VOLUME_HIDE);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Reset one level record                                           |
//+------------------------------------------------------------------+
void ClearLevel(SLevel &level)
  {
   level.found = false;
   level.support = false;
   level.center = 0.0;
   level.low = 0.0;
   level.high = 0.0;
   level.touches = 0;
   level.quality = 0;
   level.average_reaction_atr = 0.0;
   level.distance = DBL_MAX;
  }

//+------------------------------------------------------------------+
//| M15/M5 pivot test for series arrays                              |
//+------------------------------------------------------------------+
bool IsPivot(MqlRates &rates[], const int index, const bool support,
             const int strength)
  {
   int total = ArraySize(rates);
   if(index - strength < 0 || index + strength >= total)
      return false;

   double value = support ? rates[index].low : rates[index].high;
   bool strict_difference = false;

   for(int offset = 1; offset <= strength; offset++)
     {
      if(support)
        {
         if(value > rates[index-offset].low ||
            value > rates[index+offset].low)
            return false;
         if(value < rates[index-offset].low ||
            value < rates[index+offset].low)
            strict_difference = true;
        }
      else
        {
         if(value < rates[index-offset].high ||
            value < rates[index+offset].high)
            return false;
         if(value > rates[index-offset].high ||
            value > rates[index+offset].high)
            strict_difference = true;
        }
     }
   return strict_difference;
  }

//+------------------------------------------------------------------+
//| Level quality: reactions, touch count, and departure sharpness   |
//+------------------------------------------------------------------+
void MeasureLevel(MqlRates &rates[], const bool support,
                  const double price, const double atr,
                  const double half_width, int &touches,
                  double &average_reaction_atr, int &quality)
  {
   touches = 0;
   quality = 0;
   average_reaction_atr = 0.0;

   int total = ArraySize(rates);
   int last_touch = -100000;
   double reaction_sum = 0.0;
   int limit = InpM15Lookback + 1;
   if(limit > total - 1)
      limit = total - 1;

   for(int bar = 2; bar <= limit; bar++)
     {
      double tested_price = support ? rates[bar].low : rates[bar].high;
      bool hit = MathAbs(tested_price - price) <= half_width;
      if(!hit)
         continue;
      if(last_touch >= 0 && bar - last_touch < InpBarsBetweenTouches)
         continue;

      last_touch = bar;
      touches++;

      int newest = bar - InpReactionMeasurementBars;
      if(newest < 2)
         newest = 2;

      double departure = 0.0;
      for(int after = bar - 1; after >= newest; after--)
        {
         if(support)
            departure = MathMax(departure, rates[after].high - price);
         else
            departure = MathMax(departure, price - rates[after].low);
        }
      reaction_sum += MathMax(0.0, departure);
     }

   if(touches > 0 && atr > 0.0)
      average_reaction_atr = reaction_sum / touches / atr;

   if(touches >= 1)
      quality = 1;
   if(touches >= 2 && average_reaction_atr >= 0.50)
      quality = 2;
   if((touches >= 3 && average_reaction_atr >= 0.75) ||
      average_reaction_atr >= 1.25)
      quality = 3;
  }

//+------------------------------------------------------------------+
//| Find the historical level crossed by the newly closed M15 bar    |
//+------------------------------------------------------------------+
bool FindCrossedLevel(MqlRates &rates[], const bool support,
                      const double atr, SLevel &best)
  {
   ClearLevel(best);

   int total = ArraySize(rates);
   double half_width = atr * InpZoneWidthATR;
   double break_buffer = MathMax(InpBreakBufferPoints * _Point,
                                 atr * InpBreakBufferATR);
   int first = 2 + InpM15SwingStrength;
   int last = InpM15Lookback + 1;
   if(last > total - 1 - InpM15SwingStrength)
      last = total - 1 - InpM15SwingStrength;

   for(int bar = first; bar <= last; bar++)
     {
      if(!IsPivot(rates, bar, support, InpM15SwingStrength))
         continue;

      double price = support ? rates[bar].low : rates[bar].high;
      bool crossed;
      if(support)
         crossed = (rates[1].close < price - half_width - break_buffer &&
                    rates[2].close >= price - half_width);
      else
         crossed = (rates[1].close > price + half_width + break_buffer &&
                    rates[2].close <= price + half_width);
      if(!crossed)
         continue;

      int touches = 0;
      int quality = 0;
      double reaction_atr = 0.0;
      MeasureLevel(rates, support, price, atr, half_width,
                   touches, reaction_atr, quality);
      if(touches < InpMinimumLevelTouches)
         continue;

      double distance = MathAbs(rates[1].close - price);
      bool better = !best.found ||
                    quality > best.quality ||
                    (quality == best.quality && distance < best.distance);
      if(!better)
         continue;

      best.found = true;
      best.support = support;
      best.center = price;
      best.low = price - half_width;
      best.high = price + half_width;
      best.touches = touches;
      best.quality = quality;
      best.average_reaction_atr = reaction_atr;
      best.distance = distance;
     }
   return best.found;
  }

//+------------------------------------------------------------------+
//| Find nearest qualified unbroken level for scanning display       |
//+------------------------------------------------------------------+
bool FindPreviewLevel(MqlRates &rates[], const bool support,
                      const double atr, const double current_price,
                      SLevel &best)
  {
   ClearLevel(best);
   int total = ArraySize(rates);
   double half_width = atr * InpZoneWidthATR;
   int first = 2 + InpM15SwingStrength;
   int last = InpM15Lookback + 1;
   if(last > total - 1 - InpM15SwingStrength)
      last = total - 1 - InpM15SwingStrength;

   for(int bar = first; bar <= last; bar++)
     {
      if(!IsPivot(rates, bar, support, InpM15SwingStrength))
         continue;

      double price = support ? rates[bar].low : rates[bar].high;
      if(support && price >= current_price)
         continue;
      if(!support && price <= current_price)
         continue;

      int touches = 0;
      int quality = 0;
      double reaction_atr = 0.0;
      MeasureLevel(rates, support, price, atr, half_width,
                   touches, reaction_atr, quality);
      if(touches < InpMinimumLevelTouches)
         continue;

      double distance = MathAbs(current_price - price);
      bool better = !best.found ||
                    quality > best.quality ||
                    (quality == best.quality && distance < best.distance);
      if(!better)
         continue;

      best.found = true;
      best.support = support;
      best.center = price;
      best.low = price - half_width;
      best.high = price + half_width;
      best.touches = touches;
      best.quality = quality;
      best.average_reaction_atr = reaction_atr;
      best.distance = distance;
     }
   return best.found;
  }

//+------------------------------------------------------------------+
//| Direction-aware M15 displacement score, 0..3                     |
//+------------------------------------------------------------------+
int CalculateBreakScore(MqlRates &rates[], const int direction,
                        const double atr)
  {
   if(atr <= 0.0)
      return 0;

   double body = MathAbs(rates[1].close - rates[1].open);
   double range = rates[1].high - rates[1].low;
   if(range <= 0.0)
      return 0;

   bool body_direction = direction == DIR_LONG
                         ? rates[1].close > rates[1].open
                         : rates[1].close < rates[1].open;
   if(!body_direction)
      return 0;

   int score = 0;
   if(body >= atr * InpMinimumBreakBodyATR)
      score++;

   double close_location = (rates[1].close - rates[1].low) / range;
   bool closed_near_extreme = direction == DIR_LONG
                              ? close_location >= 0.70
                              : close_location <= 0.30;
   if(range >= atr * InpMinimumBreakRangeATR && closed_near_extreme)
      score++;

   double average_volume = 0.0;
   int volume_count = 0;
   int limit = ArraySize(rates) - 1;
   if(limit > 21)
      limit = 21;
   for(int bar = 2; bar <= limit; bar++)
     {
      average_volume += (double)rates[bar].tick_volume;
      volume_count++;
     }
   if(volume_count > 0)
      average_volume /= volume_count;
   if(average_volume > 0.0 &&
      (double)rates[1].tick_volume >= average_volume * InpBreakVolumeFactor)
      score++;

   return score;
  }

//+------------------------------------------------------------------+
//| Scan the latest confirmed M15 candle for an aggressive breakout  |
//+------------------------------------------------------------------+
bool ScanForM15Breakout()
  {
   if(g_current_state != STATE_SCANNING)
      return false;

   double atr = 0.0;
   if(!ReadBufferValue(g_atr_m15_handle, 1, atr) || atr <= 0.0)
      return false;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int required = InpM15Lookback + InpM15SwingStrength + 8;
   if(CopyRates(_Symbol, PERIOD_M15, 0, required, rates) < required)
      return false;

   SLevel resistance;
   SLevel support;
   bool bullish_cross = FindCrossedLevel(rates, false, atr, resistance);
   bool bearish_cross = FindCrossedLevel(rates, true, atr, support);

   int bullish_break_score = bullish_cross
                             ? CalculateBreakScore(rates, DIR_LONG, atr) : 0;
   int bearish_break_score = bearish_cross
                             ? CalculateBreakScore(rates, DIR_SHORT, atr) : 0;

   bool bullish_valid = bullish_cross &&
                        bullish_break_score >= InpMinimumBreakScore;
   bool bearish_valid = bearish_cross &&
                        bearish_break_score >= InpMinimumBreakScore;

   if(!bullish_valid && !bearish_valid)
      return false;

   int direction;
   int displacement_score;
   SLevel selected;
   if(bullish_valid &&
      (!bearish_valid ||
       resistance.quality + bullish_break_score >=
       support.quality + bearish_break_score))
     {
      direction = DIR_LONG;
      displacement_score = bullish_break_score;
      selected = resistance;
     }
   else
     {
      direction = DIR_SHORT;
      displacement_score = bearish_break_score;
      selected = support;
     }

   return ArmBreakout(direction, selected, displacement_score,
                      rates[1].time);
  }

//+------------------------------------------------------------------+
//| Lock the two latest M5 highs/lows that existed before breakout   |
//+------------------------------------------------------------------+
bool LockPreBreakM5Structure(const int direction,
                             const datetime breakout_start)
  {
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int required = InpM5StructureLookback + InpM5SwingStrength * 2 + 10;
   int copied = CopyRates(_Symbol, PERIOD_M5, 0, required, rates);
   if(copied < 30)
      return false;

   double recent_high = 0.0, older_high = 0.0;
   double recent_low = 0.0, older_low = 0.0;
   int high_count = 0, low_count = 0;

   int last = copied - 1 - InpM5SwingStrength;
   for(int bar = InpM5SwingStrength; bar <= last; bar++)
     {
      // The pivot and its newer confirmation bars must all predate the
      // M15 breakout candle. This makes the anchors genuinely pre-break.
      int newest_confirmation = bar - InpM5SwingStrength;
      if(rates[bar].time >= breakout_start ||
         rates[newest_confirmation].time >= breakout_start)
         continue;

      if(high_count < 2 &&
         IsPivot(rates, bar, false, InpM5SwingStrength))
        {
         if(high_count == 0)
            recent_high = rates[bar].high;
         else
            older_high = rates[bar].high;
         high_count++;
        }

      if(low_count < 2 &&
         IsPivot(rates, bar, true, InpM5SwingStrength))
        {
         if(low_count == 0)
            recent_low = rates[bar].low;
         else
            older_low = rates[bar].low;
         low_count++;
        }

      if(high_count >= 2 && low_count >= 2)
         break;
     }

   if(high_count < 2 || low_count < 2)
      return false;

   if(direction == DIR_LONG)
     {
      if(!(recent_high > older_high && recent_low > older_low))
         return false;
      g_locked_prev_hh = recent_high;
      g_locked_prev_hl = recent_low;
      g_locked_prev_lh = 0.0;
      g_locked_prev_ll = 0.0;
     }
   else
     {
      if(!(recent_high < older_high && recent_low < older_low))
         return false;
      g_locked_prev_lh = recent_high;
      g_locked_prev_ll = recent_low;
      g_locked_prev_hh = 0.0;
      g_locked_prev_hl = 0.0;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| State 0 -> State 1                                               |
//+------------------------------------------------------------------+
bool ArmBreakout(const int direction, const SLevel &level,
                 const int displacement_score,
                 const datetime breakout_start)
  {
   if(!LockPreBreakM5Structure(direction, breakout_start))
     {
      g_structure_status = "M5 SEQUENCE NOT ALIGNED";
      g_status_message = direction == DIR_LONG
                         ? "Bull break rejected: no intact HH/HL sequence"
                         : "Bear break rejected: no intact LL/LH sequence";
      return false;
     }

   datetime breakout_close = breakout_start + PeriodSeconds(PERIOD_M15);
   int initial_age = 0;
   if(TimeCurrent() > breakout_close)
      initial_age = (int)((TimeCurrent() - breakout_close) /
                          PeriodSeconds(PERIOD_M5));
   if(initial_age > InpSetupExpiryM5Bars)
      return false;

   g_current_state = STATE_BREAKOUT;
   g_trade_direction = direction;
   g_setup_level = NormalizePrice(level.center);
   g_zone_low = NormalizePrice(level.low);
   g_zone_high = NormalizePrice(level.high);
   g_breakout_time = breakout_start;
   g_setup_age_m5 = initial_age;
   g_retest_touched = false;

   g_level_score = level.quality;
   g_break_score = displacement_score;
   g_retest_score = 0;
   RecalculateDirectionalScore();

   g_structure_status = "VALID - PRE-BREAK SWINGS LOCKED";
   g_status_message = direction == DIR_LONG
                      ? "M15 resistance broken; waiting for M5 pullback"
                      : "M15 support broken; waiting for M5 pullback";

   DrawLockedSetup();
   PrintFormat("Support Resistance Supreme | State 1 | %s break at %.*f | "
               "level=%d break=%d",
               direction == DIR_LONG ? "LONG" : "SHORT",
               _Digits, g_setup_level, g_level_score, g_break_score);
   SendSetupAlert("BREAKOUT", g_status_message);
   return true;
  }

//+------------------------------------------------------------------+
//| Confirmed M5 lifecycle: pullback, validation, execution          |
//+------------------------------------------------------------------+
void ProcessConfirmedM5Bar()
  {
   if(g_current_state < STATE_BREAKOUT ||
      g_current_state > STATE_VALIDATION)
      return;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_M5, 0, 8, rates) < 8)
      return;

   double atr = 0.0;
   if(!ReadBufferValue(g_atr_m5_handle, 1, atr) || atr <= 0.0)
      return;

   g_setup_age_m5++;
   if(g_setup_age_m5 > InpSetupExpiryM5Bars)
     {
      ExecuteStateReset("Setup expired before valid execution",
                        false, false);
      return;
     }

   if(g_current_state == STATE_BREAKOUT)
     {
      double approach = atr * InpRetestApproachATR;
      bool zone_overlap = rates[1].low <= g_zone_high + approach &&
                          rates[1].high >= g_zone_low - approach;
      bool directional_retrace = g_trade_direction == DIR_LONG
                                 ? (rates[1].close < rates[2].close ||
                                    rates[1].low < rates[2].low)
                                 : (rates[1].close > rates[2].close ||
                                    rates[1].high > rates[2].high);

      if(zone_overlap && directional_retrace)
        {
         g_current_state = STATE_PULLBACK;
         g_status_message = "M5 pullback reached the broken M15 level";
         Print("Support Resistance Supreme | State 2 | ",
               g_status_message);
        }
      else
         return;
     }

   // Close-only invalidation. Wicks through the anchor are deliberately
   // accepted as liquidity sweeps.
   bool invalidated = false;
   if((g_current_state == STATE_PULLBACK ||
       g_current_state == STATE_VALIDATION) &&
      g_trade_direction == DIR_SHORT &&
      rates[1].close > g_locked_prev_lh)
      invalidated = true;

   if((g_current_state == STATE_PULLBACK ||
       g_current_state == STATE_VALIDATION) &&
      g_trade_direction == DIR_LONG &&
      rates[1].close < g_locked_prev_hl)
      invalidated = true;

   if(invalidated)
     {
      string reason = g_trade_direction == DIR_LONG
                      ? "M5 body closed below locked Higher Low"
                      : "M5 body closed above locked Lower High";
      ExecuteStateReset(reason, true, false);
      return;
     }

   g_structure_status = "VALID - BODY CLOSE HOLDS";

   double touch_extension = atr * InpRetestTouchATR;
   bool current_touch = rates[1].low <= g_zone_high + touch_extension &&
                        rates[1].high >= g_zone_low - touch_extension;
   if(current_touch)
      g_retest_touched = true;
   if(!g_retest_touched)
      return;

   int current_retest_score = CalculateRetestScore(rates, atr,
                                                   current_touch);
   if(current_retest_score > g_retest_score)
      g_retest_score = current_retest_score;
   RecalculateDirectionalScore();

   bool continuation_close = g_trade_direction == DIR_LONG
                             ? (rates[1].close > rates[1].open &&
                                rates[1].close >= g_setup_level)
                             : (rates[1].close < rates[1].open &&
                                rates[1].close <= g_setup_level);

   bool score_pass = g_trade_direction == DIR_LONG
                     ? g_directional_score >= InpMinimumDirectionalScore
                     : g_directional_score <= -InpMinimumDirectionalScore;

   if(!continuation_close || !score_pass)
     {
      g_status_message = StringFormat("Retest evaluating: score %d, need %s%d",
                                      g_directional_score,
                                      g_trade_direction == DIR_LONG ? "+" : "-",
                                      InpMinimumDirectionalScore);
      return;
     }

   g_current_state = STATE_VALIDATION;
   g_structure_status = "VALID - HH/LL SEQUENCE INTACT";
   g_status_message = "Structure and signed score validated";
   PrintFormat("Support Resistance Supreme | State 3 | directional score %d",
               g_directional_score);

   TryExecuteTrade(rates[1], atr);
  }

//+------------------------------------------------------------------+
//| Retest exhaustion score, 0..4                                    |
//+------------------------------------------------------------------+
int CalculateRetestScore(MqlRates &rates[], const double atr,
                         const bool current_touch)
  {
   int score = 0;
   if(current_touch || g_retest_touched)
      score++;

   double body = MathAbs(rates[1].close - rates[1].open);
   if(body <= atr * InpMaximumRetestBodyATR)
      score++;

   double recent_body = (MathAbs(rates[1].close - rates[1].open) +
                         MathAbs(rates[2].close - rates[2].open)) / 2.0;
   double prior_body = (MathAbs(rates[3].close - rates[3].open) +
                        MathAbs(rates[4].close - rates[4].open)) / 2.0;
   if(prior_body > 0.0 &&
      recent_body <= prior_body * InpDecelerationFactor)
      score++;

   double range = rates[1].high - rates[1].low;
   double upper_wick = rates[1].high -
                       MathMax(rates[1].open, rates[1].close);
   double lower_wick = MathMin(rates[1].open, rates[1].close) -
                       rates[1].low;
   double reference_body = MathMax(body, _Point);
   bool rejection = false;
   if(range > 0.0 && g_trade_direction == DIR_LONG)
      rejection = lower_wick >= reference_body * InpRetestWickBodyRatio &&
                  rates[1].close >= rates[1].low + range * 0.55;
   if(range > 0.0 && g_trade_direction == DIR_SHORT)
      rejection = upper_wick >= reference_body * InpRetestWickBodyRatio &&
                  rates[1].close <= rates[1].low + range * 0.45;
   if(rejection)
      score++;

   return score;
  }

//+------------------------------------------------------------------+
//| Multiply the neutral 0..10 score by direction                    |
//+------------------------------------------------------------------+
void RecalculateDirectionalScore()
  {
   g_setup_score = g_level_score + g_break_score + g_retest_score;
   if(g_setup_score > 10)
      g_setup_score = 10;
   g_directional_score = g_setup_score * g_trade_direction;
  }

//+------------------------------------------------------------------+
//| State 3 -> State 4                                               |
//+------------------------------------------------------------------+
void TryExecuteTrade(const MqlRates &confirmation_bar, const double atr)
  {
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
     {
      g_status_message = "Execution delayed: no current tick";
      return;
     }

   double entry = g_trade_direction == DIR_LONG ? tick.ask : tick.bid;
   double structural_anchor = g_trade_direction == DIR_LONG
                              ? MathMin(g_locked_prev_hl,
                                        MathMin(confirmation_bar.low,
                                                g_zone_low))
                              : MathMax(g_locked_prev_lh,
                                        MathMax(confirmation_bar.high,
                                                g_zone_high));
   double stop = g_trade_direction == DIR_LONG
                 ? structural_anchor - atr * InpStopATRBuffer
                 : structural_anchor + atr * InpStopATRBuffer;
   stop = EnforceMinimumStop(entry, stop, g_trade_direction);
   stop = NormalizePrice(stop);

   double risk_distance = MathAbs(entry - stop);
   if(risk_distance <= 0.0)
     {
      g_status_message = "Execution delayed: invalid stop distance";
      return;
     }

   double target = g_trade_direction == DIR_LONG
                   ? entry + risk_distance * InpRiskReward
                   : entry - risk_distance * InpRiskReward;
   target = NormalizePrice(target);

   if(!InpExecuteLiveTrades)
     {
      BeginExecution(entry, TimeCurrent(), stop, target, 0, true);
      return;
     }

   string trade_block_reason = "";
   if(!LiveTradingReady(trade_block_reason))
     {
      g_status_message = "LIVE BLOCKED: " + trade_block_reason;
      Print("Support Resistance Supreme | ", g_status_message);
      return;
     }

   if(CurrentSpreadPoints() > InpMaximumSpreadPoints)
     {
      g_status_message = "Validated; waiting for acceptable spread";
      return;
     }

   if(InpOnePositionPerSymbol && HasAnyPositionForSymbol())
     {
      g_status_message = "Validated; another position exists on symbol";
      return;
     }

   double lots = InpUseRiskPercent
                 ? CalculateRiskVolume(risk_distance)
                 : NormalizeVolume(InpFixedLot);
   if(lots <= 0.0)
     {
      g_status_message = "Execution blocked: volume would exceed risk limit";
      return;
     }

   bool placed = g_trade_direction == DIR_LONG
                 ? g_trade.Buy(lots, _Symbol, 0.0, stop, target,
                               "Support Resistance Supreme")
                 : g_trade.Sell(lots, _Symbol, 0.0, stop, target,
                                "Support Resistance Supreme");
   if(!placed || !SuccessfulTradeRetcode())
     {
      g_status_message = "Order failed: " +
                         g_trade.ResultRetcodeDescription();
      Print("Support Resistance Supreme | ", g_status_message);
      return;
     }

   ulong ticket = 0;
   double actual_entry = g_trade.ResultPrice();
   datetime actual_time = TimeCurrent();
   if(FindOurPosition(ticket))
     {
      actual_entry = PositionGetDouble(POSITION_PRICE_OPEN);
      actual_time = (datetime)PositionGetInteger(POSITION_TIME);
     }
   if(actual_entry <= 0.0)
      actual_entry = entry;

   BeginExecution(actual_entry, actual_time, stop, target, ticket, false);
  }

//+------------------------------------------------------------------+
//| Lock entry telemetry at execution                                |
//+------------------------------------------------------------------+
void BeginExecution(const double entry, const datetime entry_time,
                    const double stop, const double target,
                    const ulong ticket, const bool virtual_execution)
  {
   g_current_state = STATE_EXECUTION;
   g_entry_price = NormalizePrice(entry);
   g_entry_time = entry_time;
   g_entry_bar_time = iTime(_Symbol, PERIOD_M5, 0);
   if(g_entry_bar_time <= 0)
      g_entry_bar_time = entry_time;
   g_stop_price = stop;
   g_target_price = target;
   g_position_ticket = ticket;
   g_virtual_execution = virtual_execution;
   g_momentum_decay_factor = 0.0;
   g_structure_status = "VALID - EXECUTING";
   g_status_message = virtual_execution
                      ? "State 4 signal active (virtual tracking)"
                      : "State 4 live position active";

   DrawExecutionObjects();
   PrintFormat("Support Resistance Supreme | State 4 | %s | entry=%.*f | "
               "time=%s | SL=%.*f | TP=%.*f | score=%d",
               virtual_execution ? "SIGNAL" : "LIVE",
               _Digits, g_entry_price,
               TimeToString(g_entry_time, TIME_DATE|TIME_SECONDS),
               _Digits, g_stop_price, _Digits, g_target_price,
               g_directional_score);
   SendSetupAlert("EXECUTION", g_status_message);
  }

//+------------------------------------------------------------------+
//| ATR-normalized real-time velocity and scratch exit               |
//+------------------------------------------------------------------+
void EvaluateMomentumDecay(const bool confirmed_m5_close)
  {
   if(g_current_state != STATE_EXECUTION ||
      g_entry_price <= 0.0 ||
      g_entry_bar_time <= 0)
      return;

   int elapsed_bars = iBarShift(_Symbol, PERIOD_M5,
                                g_entry_bar_time, false);
   if(elapsed_bars < 0)
      elapsed_bars = (int)((TimeCurrent() - g_entry_time) /
                           PeriodSeconds(PERIOD_M5));
   if(elapsed_bars < 0)
      elapsed_bars = 0;

   if(elapsed_bars < InpGraceBars)
     {
      g_momentum_decay_factor = 0.0;
      return;
     }

   double atr = 0.0;
   if(!ReadBufferValue(g_atr_m5_handle, 0, atr) || atr <= 0.0)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;
   double current_price = g_trade_direction == DIR_LONG ? tick.bid : tick.ask;
   double price_distance = (current_price - g_entry_price) *
                           g_trade_direction;
   double distance_in_atr = price_distance / atr;
   double velocity = distance_in_atr / elapsed_bars;
   g_momentum_decay_factor = velocity / InpMinimumATRPerBar;

   bool in_drawdown = price_distance < 0.0;
   bool stagnant_on_close = confirmed_m5_close &&
                            velocity < InpMinimumATRPerBar;

   if(in_drawdown || stagnant_on_close)
     {
      string reason = in_drawdown
                      ? "Momentum decay: price reversed past entry"
                      : "Momentum decay: velocity below minimum at M5 close";
      ExecuteMarketScratchExit(reason);
     }
  }

//+------------------------------------------------------------------+
//| Close only this EA's live position, then flush volatile state     |
//+------------------------------------------------------------------+
void ExecuteMarketScratchExit(const string reason)
  {
   if(g_current_state != STATE_EXECUTION)
      return;

   if(!g_virtual_execution)
     {
      ulong ticket = 0;
      if(FindOurPosition(ticket))
        {
         if(!g_trade.PositionClose(ticket))
           {
            g_status_message = "Scratch exit failed: " +
                               g_trade.ResultRetcodeDescription();
            Print("Support Resistance Supreme | ", g_status_message);
            return;
           }
        }
     }

   Print("Support Resistance Supreme | SCRATCH EXIT | ", reason);
   SendSetupAlert("SCRATCH EXIT", reason);
   ExecuteStateReset(reason, false, true);
  }

//+------------------------------------------------------------------+
//| Virtual stop/target handling in signal-only mode                 |
//+------------------------------------------------------------------+
void CheckVirtualExit()
  {
   if(g_current_state != STATE_EXECUTION || !g_virtual_execution)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;
   double price = g_trade_direction == DIR_LONG ? tick.bid : tick.ask;
   bool stop_hit = g_trade_direction == DIR_LONG
                   ? price <= g_stop_price
                   : price >= g_stop_price;
   bool target_hit = g_trade_direction == DIR_LONG
                     ? price >= g_target_price
                     : price <= g_target_price;
   if(target_hit)
      ExecuteStateReset("Virtual target reached", false, false);
   else if(stop_hit)
      ExecuteStateReset("Virtual structural stop reached", false, false);
  }

//+------------------------------------------------------------------+
//| Master garbage collection / state reset                          |
//+------------------------------------------------------------------+
void ExecuteStateReset(const string reason, const bool invalidated,
                       const bool scratch_exit)
  {
   g_current_state = STATE_SCANNING;
   g_trade_direction = DIR_NONE;

   g_locked_prev_lh = 0.0;
   g_locked_prev_hl = 0.0;
   g_locked_prev_ll = 0.0;
   g_locked_prev_hh = 0.0;

   g_setup_level = 0.0;
   g_zone_low = 0.0;
   g_zone_high = 0.0;
   g_breakout_time = 0;
   g_setup_age_m5 = 0;
   g_retest_touched = false;

   g_level_score = 0;
   g_break_score = 0;
   g_retest_score = 0;
   g_setup_score = 0;
   g_directional_score = 0;

   g_entry_price = 0.0;
   g_entry_time = 0;
   g_entry_bar_time = 0;
   g_stop_price = 0.0;
   g_target_price = 0.0;
   g_momentum_decay_factor = 0.0;
   g_position_ticket = 0;
   g_virtual_execution = false;

   if(invalidated)
      g_structure_status = "[INVALIDATED - RESET]";
   else if(scratch_exit)
      g_structure_status = "[SCRATCH EXIT - RESET]";
   else
      g_structure_status = "[RESET - SCANNING]";
   g_status_message = reason;

   ClearActiveSetupObjects();
   UpdateDashboard();
   ChartRedraw();
   Print("Support Resistance Supreme | State 0 | ", reason);
  }

//+------------------------------------------------------------------+
//| Risk-based volume calculation                                    |
//+------------------------------------------------------------------+
double CalculateRiskVolume(const double stop_distance)
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_money = equity * InpRiskPercent / 100.0;
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tick_value = SymbolInfoDouble(_Symbol,
                                        SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tick_value <= 0.0)
      tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tick_size <= 0.0 || tick_value <= 0.0 ||
      stop_distance <= 0.0)
      return 0.0;

   double loss_per_lot = stop_distance / tick_size * tick_value;
   if(loss_per_lot <= 0.0)
      return 0.0;

   double raw_volume = risk_money / loss_per_lot;
   double minimum_volume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(raw_volume < minimum_volume && !InpAllowMinLotOverRisk)
      return 0.0;
   return NormalizeVolume(raw_volume);
  }

//+------------------------------------------------------------------+
//| Normalize volume to broker constraints                           |
//+------------------------------------------------------------------+
double NormalizeVolume(double volume)
  {
   double minimum = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maximum = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      return 0.0;

   volume = MathFloor(volume / step + 1e-8) * step;
   volume = MathMax(minimum, MathMin(maximum, volume));

   int digits = 0;
   double test_step = step;
   while(digits < 8 &&
         MathAbs(test_step - MathRound(test_step)) > 1e-8)
     {
      test_step *= 10.0;
      digits++;
     }
   return NormalizeDouble(volume, digits);
  }

//+------------------------------------------------------------------+
//| Tick-size price normalization                                    |
//+------------------------------------------------------------------+
double NormalizePrice(const double price)
  {
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_size <= 0.0)
      tick_size = _Point;
   return NormalizeDouble(MathRound(price / tick_size) * tick_size,
                          _Digits);
  }

//+------------------------------------------------------------------+
//| Respect the symbol's minimum stop distance                       |
//+------------------------------------------------------------------+
double EnforceMinimumStop(const double entry, const double proposed_stop,
                          const int direction)
  {
   int stops_level = (int)SymbolInfoInteger(_Symbol,
                                             SYMBOL_TRADE_STOPS_LEVEL);
   double minimum = MathMax(stops_level * _Point, _Point);
   if(direction == DIR_LONG)
      return MathMin(proposed_stop, entry - minimum);
   return MathMax(proposed_stop, entry + minimum);
  }

//+------------------------------------------------------------------+
//| Current spread in points                                         |
//+------------------------------------------------------------------+
double CurrentSpreadPoints()
  {
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return DBL_MAX;
   return (tick.ask - tick.bid) / _Point;
  }

//+------------------------------------------------------------------+
//| Find this EA's position and leave it selected                    |
//+------------------------------------------------------------------+
bool FindOurPosition(ulong &ticket)
  {
   ticket = 0;
   for(int index = PositionsTotal() - 1; index >= 0; index--)
     {
      ulong candidate = PositionGetTicket(index);
      if(candidate == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      ticket = candidate;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Any live position on the current symbol                          |
//+------------------------------------------------------------------+
bool HasAnyPositionForSymbol()
  {
   for(int index = PositionsTotal() - 1; index >= 0; index--)
     {
      ulong ticket = PositionGetTicket(index);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Explain every platform-level reason that can prevent execution   |
//+------------------------------------------------------------------+
bool LiveTradingReady(string &reason)
  {
   reason = "";
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
     {
      reason = "terminal is not connected";
      return false;
     }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
     {
      reason = "turn on the MT5 Algo Trading toolbar button";
      return false;
     }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      reason = "enable Allow Algo Trading in this EA's Common tab";
      return false;
     }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
     {
      reason = "the account does not currently permit trading";
      return false;
     }
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
     {
      reason = "the account/server blocks Expert Advisor trading";
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Confirm the server accepted a CTrade market operation            |
//+------------------------------------------------------------------+
bool SuccessfulTradeRetcode()
  {
   uint code = g_trade.ResultRetcode();
   return code == TRADE_RETCODE_DONE ||
          code == TRADE_RETCODE_DONE_PARTIAL ||
          code == TRADE_RETCODE_PLACED;
  }

//+------------------------------------------------------------------+
//| Recover safely if terminal/EA restarts during an open trade      |
//+------------------------------------------------------------------+
bool RecoverOpenPosition()
  {
   if(!InpExecuteLiveTrades)
      return false;

   ulong ticket = 0;
   if(!FindOurPosition(ticket))
      return false;

   ENUM_POSITION_TYPE type =
      (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   g_trade_direction = type == POSITION_TYPE_BUY ? DIR_LONG : DIR_SHORT;
   g_current_state = STATE_EXECUTION;
   g_entry_price = PositionGetDouble(POSITION_PRICE_OPEN);
   g_entry_time = (datetime)PositionGetInteger(POSITION_TIME);
   int shift = iBarShift(_Symbol, PERIOD_M5, g_entry_time, false);
   g_entry_bar_time = shift >= 0
                      ? iTime(_Symbol, PERIOD_M5, shift)
                      : g_entry_time;
   g_stop_price = PositionGetDouble(POSITION_SL);
   g_target_price = PositionGetDouble(POSITION_TP);
   g_position_ticket = ticket;
   g_virtual_execution = false;
   g_structure_status = "RECOVERED LIVE POSITION";
   g_status_message = "State 4 restored after EA initialization";
   return true;
  }

//+------------------------------------------------------------------+
//| Scanning support/resistance display                              |
//+------------------------------------------------------------------+
void UpdateScanningZones()
  {
   if(g_current_state != STATE_SCANNING)
      return;

   double atr = 0.0;
   if(!ReadBufferValue(g_atr_m15_handle, 1, atr) || atr <= 0.0)
      return;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int required = InpM15Lookback + InpM15SwingStrength + 8;
   if(CopyRates(_Symbol, PERIOD_M15, 0, required, rates) < required)
      return;

   double current_price = rates[1].close;
   SLevel support;
   SLevel resistance;
   bool has_support = FindPreviewLevel(rates, true, atr,
                                       current_price, support);
   bool has_resistance = FindPreviewLevel(rates, false, atr,
                                          current_price, resistance);

   if(has_support)
      DrawPriceZone(g_prefix + "SCAN_SUPPORT",
                    support.low, support.high, C'35,85,60');
   else
      ObjectDelete(0, g_prefix + "SCAN_SUPPORT");

   if(has_resistance)
      DrawPriceZone(g_prefix + "SCAN_RESISTANCE",
                    resistance.low, resistance.high, C'105,45,45');
   else
      ObjectDelete(0, g_prefix + "SCAN_RESISTANCE");
  }

//+------------------------------------------------------------------+
//| Draw an M15 zone behind price                                    |
//+------------------------------------------------------------------+
void DrawPriceZone(const string name, const double low,
                   const double high, const color zone_color)
  {
   datetime left = iTime(_Symbol, PERIOD_M15, InpM15Lookback);
   if(left <= 0)
      left = TimeCurrent() -
             InpM15Lookback * PeriodSeconds(PERIOD_M15);
   datetime right = iTime(_Symbol, PERIOD_M15, 0) +
                    20 * PeriodSeconds(PERIOD_M15);

   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE, 0,
                   left, high, right, low);
   else
     {
      ObjectMove(0, name, 0, left, high);
      ObjectMove(0, name, 1, right, low);
     }
   ObjectSetInteger(0, name, OBJPROP_COLOR, zone_color);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
//| Locked setup chart objects                                       |
//+------------------------------------------------------------------+
void DrawLockedSetup()
  {
   ObjectDelete(0, g_prefix + "SCAN_SUPPORT");
   ObjectDelete(0, g_prefix + "SCAN_RESISTANCE");
   DrawPriceZone(g_prefix + "ACTIVE_ZONE", g_zone_low, g_zone_high,
                 g_trade_direction == DIR_LONG
                 ? C'35,105,70' : C'130,45,45');
   DrawHorizontalLine(g_prefix + "BREAK_LEVEL", g_setup_level,
                      clrGold, STYLE_DASH, 2);

   double anchor = g_trade_direction == DIR_LONG
                   ? g_locked_prev_hl : g_locked_prev_lh;
   DrawHorizontalLine(g_prefix + "STRUCTURE_ANCHOR", anchor,
                      clrDeepSkyBlue, STYLE_DOT, 1);
  }

//+------------------------------------------------------------------+
//| Entry, stop, target, and arrow                                   |
//+------------------------------------------------------------------+
void DrawExecutionObjects()
  {
   DrawHorizontalLine(g_prefix + "ENTRY", g_entry_price,
                      clrWhite, STYLE_SOLID, 1);
   DrawHorizontalLine(g_prefix + "STOP", g_stop_price,
                      clrOrangeRed, STYLE_SOLID, 2);
   DrawHorizontalLine(g_prefix + "TARGET", g_target_price,
                      clrLime, STYLE_SOLID, 2);

   string arrow_name = g_prefix + "ENTRY_ARROW_" +
                       IntegerToString((int)g_entry_time);
   if(ObjectFind(0, arrow_name) < 0)
      ObjectCreate(0, arrow_name, OBJ_ARROW, 0,
                   g_entry_time, g_entry_price);
   ObjectSetInteger(0, arrow_name, OBJPROP_ARROWCODE,
                    g_trade_direction == DIR_LONG ? 233 : 234);
   ObjectSetInteger(0, arrow_name, OBJPROP_COLOR,
                    g_trade_direction == DIR_LONG ? clrLime : clrRed);
   ObjectSetInteger(0, arrow_name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, arrow_name, OBJPROP_SELECTABLE, false);
  }

//+------------------------------------------------------------------+
//| Horizontal line helper                                           |
//+------------------------------------------------------------------+
void DrawHorizontalLine(const string name, const double price,
                        const color line_color,
                        const ENUM_LINE_STYLE style,
                        const int width)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   ObjectSetDouble(0, name, OBJPROP_PRICE, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, line_color);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
//| Delete only volatile active-setup objects                        |
//+------------------------------------------------------------------+
void ClearActiveSetupObjects()
  {
   ObjectDelete(0, g_prefix + "ACTIVE_ZONE");
   ObjectDelete(0, g_prefix + "BREAK_LEVEL");
   ObjectDelete(0, g_prefix + "STRUCTURE_ANCHOR");
   ObjectDelete(0, g_prefix + "ENTRY");
   ObjectDelete(0, g_prefix + "STOP");
   ObjectDelete(0, g_prefix + "TARGET");
  }

//+------------------------------------------------------------------+
//| Dashboard object creation                                        |
//+------------------------------------------------------------------+
void CreateDashboard()
  {
   if(!InpShowDashboard)
      return;

   string panel = g_prefix + "DASH_PANEL";
   if(ObjectFind(0, panel) < 0)
      ObjectCreate(0, panel, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panel, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, panel, OBJPROP_XDISTANCE, InpDashboardX);
   ObjectSetInteger(0, panel, OBJPROP_YDISTANCE, InpDashboardY);
   ObjectSetInteger(0, panel, OBJPROP_XSIZE, 395);
   ObjectSetInteger(0, panel, OBJPROP_YSIZE, 282);
   ObjectSetInteger(0, panel, OBJPROP_BGCOLOR, C'18,24,30');
   ObjectSetInteger(0, panel, OBJPROP_BORDER_COLOR, C'80,105,125');
   ObjectSetInteger(0, panel, OBJPROP_BACK, false);
   ObjectSetInteger(0, panel, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panel, OBJPROP_HIDDEN, true);

   for(int row = 0; row < 11; row++)
      SetDashboardRow(row, "", clrWhite);
  }

//+------------------------------------------------------------------+
//| Set one dashboard row                                            |
//+------------------------------------------------------------------+
void SetDashboardRow(const int row, const string text,
                     const color text_color)
  {
   if(!InpShowDashboard)
      return;

   string name = g_prefix + "DASH_ROW_" + IntegerToString(row);
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, InpDashboardX + 12);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE,
                    InpDashboardY + 10 + row * 23);
   ObjectSetInteger(0, name, OBJPROP_COLOR, text_color);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, row == 0 ? 11 : 9);
   ObjectSetString(0, name, OBJPROP_FONT,
                   row == 0 ? "Segoe UI Semibold" : "Consolas");
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
//| Real-time dashboard telemetry                                    |
//+------------------------------------------------------------------+
void UpdateDashboard()
  {
   if(!InpShowDashboard)
      return;

   color state_color = clrSilver;
   if(g_current_state == STATE_BREAKOUT)   state_color = clrGold;
   if(g_current_state == STATE_PULLBACK)   state_color = clrOrange;
   if(g_current_state == STATE_VALIDATION) state_color = clrAqua;
   if(g_current_state == STATE_EXECUTION)  state_color = clrLime;

   color score_color = g_directional_score > 0 ? clrLime :
                       g_directional_score < 0 ? clrTomato : clrSilver;
   string direction = g_trade_direction == DIR_LONG ? "LONG" :
                      g_trade_direction == DIR_SHORT ? "SHORT" : "NONE";

   string anchor = "-";
   if(g_trade_direction == DIR_LONG && g_locked_prev_hl > 0.0)
      anchor = "HL " + DoubleToString(g_locked_prev_hl, _Digits) +
               " | HH " + DoubleToString(g_locked_prev_hh, _Digits);
   if(g_trade_direction == DIR_SHORT && g_locked_prev_lh > 0.0)
      anchor = "LH " + DoubleToString(g_locked_prev_lh, _Digits) +
               " | LL " + DoubleToString(g_locked_prev_ll, _Digits);

   string zone = g_setup_level > 0.0
                 ? DoubleToString(g_zone_low, _Digits) + " .. " +
                   DoubleToString(g_zone_high, _Digits)
                 : "-";

   int elapsed_bars = 0;
   string decay = "INACTIVE";
   color decay_color = clrSilver;
   if(g_current_state == STATE_EXECUTION)
     {
      elapsed_bars = iBarShift(_Symbol, PERIOD_M5,
                               g_entry_bar_time, false);
      if(elapsed_bars < 0)
         elapsed_bars = 0;
      if(elapsed_bars < InpGraceBars)
        {
         decay = StringFormat("GRACE %d/%d BARS",
                              elapsed_bars, InpGraceBars);
         decay_color = clrGold;
        }
      else
        {
         decay = DoubleToString(g_momentum_decay_factor, 2) +
                 "x MIN VELOCITY";
         decay_color = g_momentum_decay_factor >= 1.0
                       ? clrLime : clrTomato;
        }
     }

   string entry = g_entry_price > 0.0
                  ? DoubleToString(g_entry_price, _Digits) + " @ " +
                    TimeToString(g_entry_time, TIME_DATE|TIME_MINUTES)
                  : "-";

   SetDashboardRow(0, "SUPPORT RESISTANCE SUPREME", clrWhite);
   SetDashboardRow(1, StringFormat("STATE: %d - %s",
                                   g_current_state,
                                   StateName(g_current_state)),
                   state_color);
   SetDashboardRow(2, StringFormat("DIRECTION: %-5s  SCORE: %+d / 10",
                                   direction, g_directional_score),
                   score_color);
   SetDashboardRow(3, StringFormat("COMPONENTS: LEVEL %d | BREAK %d | RETEST %d",
                                   g_level_score, g_break_score,
                                   g_retest_score), clrWhiteSmoke);
   SetDashboardRow(4, "M5 SEQUENCE: " + g_structure_status,
                   StringFind(g_structure_status, "INVALIDATED") >= 0
                   ? clrTomato : clrDeepSkyBlue);
   SetDashboardRow(5, "LOCKED ANCHORS: " + anchor, clrWhiteSmoke);
   SetDashboardRow(6, "ACTIVE M15 ZONE: " + zone, clrWhiteSmoke);
   SetDashboardRow(7, "MOMENTUM DECAY: " + decay, decay_color);
   SetDashboardRow(8, "ENTRY: " + entry, clrWhiteSmoke);
   string execution_mode = "SIGNAL ONLY";
   color execution_color = clrGold;
   if(InpExecuteLiveTrades)
     {
      string block_reason = "";
      if(LiveTradingReady(block_reason))
        {
         execution_mode = "LIVE READY";
         execution_color = clrLime;
        }
      else
        {
         execution_mode = "LIVE BLOCKED";
         execution_color = clrTomato;
        }
     }
   SetDashboardRow(9, "MODE: " + execution_mode, execution_color);
   SetDashboardRow(10, "STATUS: " + g_status_message, clrWhite);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| State label                                                      |
//+------------------------------------------------------------------+
string StateName(const int state)
  {
   if(state == STATE_SCANNING)   return "SCANNING";
   if(state == STATE_BREAKOUT)   return "BREAKOUT";
   if(state == STATE_PULLBACK)   return "PULLBACK";
   if(state == STATE_VALIDATION) return "VALIDATION";
   if(state == STATE_EXECUTION)  return "EXECUTION";
   return "UNKNOWN";
  }

//+------------------------------------------------------------------+
//| Alerts with duplicate suppression                                |
//+------------------------------------------------------------------+
void SendSetupAlert(const string event_name, const string details)
  {
   if(!InpEnableAlerts)
      return;

   datetime now = TimeCurrent();
   if(now == g_last_alert_time)
      return;
   g_last_alert_time = now;

   string message = "Support Resistance Supreme | " + _Symbol +
                    " | " + event_name + " | " + details;
   Alert(message);
   if(InpEnablePushNotifications)
      SendNotification(message);
  }
