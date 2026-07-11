//+------------------------------------------------------------------+
//|                        ScalpingMagicIndicator.mq5                |
//|              Professional Scalping Indicator for Deriv MT5       |
//|         Supports all Synthetic / Volatility / Boom / Crash       |
//+------------------------------------------------------------------+
#property copyright   "Scalping Magic Indicator"
#property version     "1.00"
#property indicator_chart_window
#property indicator_buffers 8
#property indicator_plots   4

// --- Plot: Buy Arrow
#property indicator_label1  "Buy Signal"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrLime
#property indicator_style1  STYLE_SOLID
#property indicator_width1  3

// --- Plot: Sell Arrow
#property indicator_label2  "Sell Signal"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrRed
#property indicator_style2  STYLE_SOLID
#property indicator_width2  3

// --- Plot: Potential Buy (forming)
#property indicator_label3  "Potential Buy"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrYellow
#property indicator_style3  STYLE_SOLID
#property indicator_width3  1

// --- Plot: Potential Sell (forming)
#property indicator_label4  "Potential Sell"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrOrange
#property indicator_style4  STYLE_SOLID
#property indicator_width4  1

//--- Indicator Buffers
double BuyBuffer[];
double SellBuffer[];
double PotentialBuyBuffer[];
double PotentialSellBuffer[];
double EntryBuffer[];
double SLBuffer[];
double TP1Buffer[];
double TP2Buffer[];

//+------------------------------------------------------------------+
//|  E N U M S                                                        |
//+------------------------------------------------------------------+
enum ENUM_TRADING_MODE
  {
   MODE_QUICK     = 0,  // Quick Scalp
   MODE_STANDARD  = 1,  // Standard Scalp
   MODE_PRECISION = 2   // Precision Scalp
  };

//+------------------------------------------------------------------+
//|  I N P U T S                                                      |
//+------------------------------------------------------------------+
input group "=== GENERAL SETTINGS ==="
input bool   EnableCleanChartMode   = true;    // Clean Chart Mode (BG/Grid/Volume)
input bool   EnableDashboard        = true;    // Show Dashboard
input ENUM_TRADING_MODE TradingMode = MODE_STANDARD; // Scalping Mode

input group "=== SIGNAL FILTERS ==="
input int    MinimumSignalScore     = 70;      // Minimum Signal Score (0-100)
input bool   UseHTFBias             = true;    // Use Higher Timeframe Bias
input bool   UseSupportResistance   = true;    // Use Support/Resistance Zones
input bool   UseRetestConfirmation  = true;    // Use Retest Confirmation
input bool   UseFakeoutFilter       = true;    // Use Fakeout Filter
input bool   UseMomentumFilter      = true;    // Use Momentum Filter
input bool   UseSpreadFilter        = true;    // Use Spread Filter

input group "=== RISK MANAGEMENT ==="
input double TP1_RiskReward         = 1.0;     // TP1 Risk:Reward
input double TP2_RiskReward         = 2.0;     // TP2 Risk:Reward
input double TP3_RiskReward         = 3.0;     // TP3 Risk:Reward
input bool   UseBreakevenLogic      = true;    // Use Breakeven Logic
input double BreakevenTrigger       = 0.5;     // Breakeven Trigger (% toward TP1)
input bool   UseExitWarnings        = true;    // Use Exit Warnings

input group "=== ZONE SETTINGS ==="
input int    ZoneLookbackBars       = 200;     // Zone Lookback Bars
input int    SwingLookbackBars      = 20;      // Swing Lookback Bars
input int    MinimumZoneTouches     = 2;       // Minimum Zone Touches
input double ZoneWidthMultiplier    = 0.5;     // Zone Width (ATR multiplier)

input group "=== SPREAD / VOLATILITY ==="
input double MaxSpreadAllowed       = 50.0;    // Max Spread (points)

input group "=== ALERTS ==="
input bool   EnableAlerts           = true;    // Enable Popup Alerts
input bool   EnablePushNotifications= false;   // Enable Push Notifications
input bool   EnableEmailAlerts      = false;   // Enable Email Alerts
input bool   EnableSoundAlerts      = true;    // Enable Sound Alerts
input string AlertSound             = "alert.wav"; // Alert Sound File

input group "=== DISPLAY POSITION ==="
input int    DashboardX             = 15;      // Dashboard X Position
input int    DashboardY             = 30;      // Dashboard Y Position

//+------------------------------------------------------------------+
//|  G L O B A L  V A R I A B L E S                                   |
//+------------------------------------------------------------------+
// Chart handles for HTF
int    g_htf1_tf, g_htf2_tf;          // higher timeframe periods
string g_prefix = "SMI_";             // object prefix

// Confirmed signal tracking (anti-repaint)
datetime g_last_buy_time  = 0;
datetime g_last_sell_time = 0;
int      g_last_score     = 0;
string   g_last_action    = "NO TRADE";
double   g_last_entry     = 0;
double   g_last_sl        = 0;
double   g_last_tp1       = 0;
double   g_last_tp2       = 0;
double   g_last_tp3       = 0;
double   g_last_be        = 0;
string   g_last_momentum  = "Neutral";
string   g_last_market    = "Unknown";
string   g_htf_bias       = "Neutral";
string   g_ltf_bias       = "Neutral";
string   g_fakeout_risk   = "Low";

// State flags
bool   g_in_buy_trade  = false;
bool   g_in_sell_trade = false;
double g_trade_entry   = 0;
double g_trade_sl      = 0;
double g_trade_tp1     = 0;

//+------------------------------------------------------------------+
//|  O N   I N I T                                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   // Assign indicator buffers
   SetIndexBuffer(0, BuyBuffer,          INDICATOR_DATA);
   SetIndexBuffer(1, SellBuffer,         INDICATOR_DATA);
   SetIndexBuffer(2, PotentialBuyBuffer, INDICATOR_DATA);
   SetIndexBuffer(3, PotentialSellBuffer,INDICATOR_DATA);
   SetIndexBuffer(4, EntryBuffer,        INDICATOR_CALCULATIONS);
   SetIndexBuffer(5, SLBuffer,           INDICATOR_CALCULATIONS);
   SetIndexBuffer(6, TP1Buffer,          INDICATOR_CALCULATIONS);
   SetIndexBuffer(7, TP2Buffer,          INDICATOR_CALCULATIONS);

   // Arrow codes
   PlotIndexSetInteger(0, PLOT_ARROW, 241); // Up arrow
   PlotIndexSetInteger(1, PLOT_ARROW, 242); // Down arrow
   PlotIndexSetInteger(2, PLOT_ARROW, 221); // Small up
   PlotIndexSetInteger(3, PLOT_ARROW, 222); // Small down

   // Empty values
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, 0.0);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, 0.0);
   PlotIndexSetDouble(2, PLOT_EMPTY_VALUE, 0.0);
   PlotIndexSetDouble(3, PLOT_EMPTY_VALUE, 0.0);

   // Determine HTF based on current timeframe and mode
   SetHTFTimeframes();

   // Apply clean chart mode
   if(EnableCleanChartMode)
      ApplyCleanChart();

   // Short name
   IndicatorSetString(INDICATOR_SHORTNAME, "Scalping Magic [" + ModeToString(TradingMode) + "]");

   // Initialize dashboard
   if(EnableDashboard)
      CreateDashboard();

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//|  O N   D E I N I T                                               |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   // Remove all indicator objects
   ObjectsDeleteAll(0, g_prefix);
   Comment("");
  }

//+------------------------------------------------------------------+
//|  O N   C A L C U L A T E                                         |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   if(rates_total < SwingLookbackBars + 5)
      return(0);

   int start = (prev_calculated <= 1) ? SwingLookbackBars + 2 : prev_calculated - 1;

   // Always recalculate the last 2 confirmed candles + current
   for(int i = start; i < rates_total - 1; i++) // Only confirmed (closed) candles
     {
      BuyBuffer[i]           = 0.0;
      SellBuffer[i]          = 0.0;
      PotentialBuyBuffer[i]  = 0.0;
      PotentialSellBuffer[i] = 0.0;

      if(i < SwingLookbackBars + 2)
         continue;

      // Spread check on confirmed bar
      double bar_spread = (rates_total > 0) ? (double)spread[i] : 0;
      if(UseSpreadFilter && bar_spread > MaxSpreadAllowed)
         continue;

      // Core analysis for this confirmed candle
      AnalyseBar(i, rates_total, time, open, high, low, close, tick_volume, spread,
                 BuyBuffer, SellBuffer, PotentialBuyBuffer, PotentialSellBuffer);
     }

   // --- Current (forming) candle: potential only
   int cur = rates_total - 1;
   PotentialBuyBuffer[cur]  = 0.0;
   PotentialSellBuffer[cur] = 0.0;

   int forming_score = 0;
   bool forming_buy  = false;
   bool forming_sell = false;
   CheckFormingSetup(cur, rates_total, open, high, low, close, tick_volume,
                     forming_buy, forming_sell, forming_score);

   if(forming_buy && forming_score >= MinimumSignalScore - 15)
      PotentialBuyBuffer[cur]  = low[cur] - 2 * _Point * 10;
   if(forming_sell && forming_score >= MinimumSignalScore - 15)
      PotentialSellBuffer[cur] = high[cur] + 2 * _Point * 10;

   // --- Update dashboard and live trade management
   if(EnableDashboard)
      UpdateDashboard(cur, rates_total, open, high, low, close, tick_volume, spread);

   // --- Exit / breakeven management
   if(UseExitWarnings || UseBreakevenLogic)
      ManageTrade(cur, high, low, close);

   return(rates_total);
  }

//+------------------------------------------------------------------+
//|  A N A L Y S E   C L O S E D   B A R                            |
//+------------------------------------------------------------------+
void AnalyseBar(int i, int rates_total,
                const datetime &time[],
                const double &open[], const double &high[],
                const double &low[],  const double &close[],
                const long &tick_volume[], const int &spread[],
                double &buyBuf[], double &sellBuf[],
                double &potBuyBuf[], double &potSellBuf[])
  {
   // --- Only process once per bar (anti-repaint guard)
   if(time[i] == g_last_buy_time || time[i] == g_last_sell_time)
      return;

   // --- Compute ATR (manual, 14 bars)
   double atr = CalcATR(i, 14, high, low, close);

   // --- Market structure
   bool  htf_bull, htf_bear, ltf_bull, ltf_bear;
   GetHTFBias(i, htf_bull, htf_bear);
   GetLTFBias(i, rates_total, high, low, close, ltf_bull, ltf_bear);

   // --- Detect ranging
   bool ranging = IsRanging(i, rates_total, high, low, close, atr);

   // --- Nearest S/R
   double sup = 0, res = 0;
   if(UseSupportResistance)
      GetNearestZones(i, rates_total, high, low, close, atr, sup, res);

   // --- Fakeout check
   bool fakeout_risk_buy  = false;
   bool fakeout_risk_sell = false;
   if(UseFakeoutFilter)
      CheckFakeout(i, open, high, low, close, atr, fakeout_risk_buy, fakeout_risk_sell);

   // --- Momentum
   int mom = CalcMomentum(i, rates_total, close, open, high, low);
   // mom: +2 strong bull, +1 weak bull, 0 neutral, -1 weak bear, -2 strong bear

   // --- Retest confirmation
   bool retest_buy = false, retest_sell = false;
   if(UseRetestConfirmation)
      CheckRetest(i, open, high, low, close, atr, sup, res, retest_buy, retest_sell);

   // --- Candle quality
   double body     = MathAbs(close[i] - open[i]);
   double candle_range = high[i] - low[i];
   double upper_wick = high[i] - MathMax(open[i], close[i]);
   double lower_wick = MathMin(open[i], close[i]) - low[i];
   bool   strong_bull_candle = (body > candle_range * 0.55) && (close[i] > open[i]);
   bool   strong_bear_candle = (body > candle_range * 0.55) && (close[i] < open[i]);

   // --- BOS detection
   bool bos_bull = IsBullishBOS(i, rates_total, high, low, close);
   bool bos_bear = IsBearishBOS(i, rates_total, high, low, close);

   // === SCORE CALCULATION ===
   int score_buy  = ScoreBuy(htf_bull, ltf_bull, strong_bull_candle, bos_bull,
                              retest_buy, mom, ranging, fakeout_risk_buy,
                              sup, res, close[i], atr, spread[i]);
   int score_sell = ScoreSell(htf_bear, ltf_bear, strong_bear_candle, bos_bear,
                               retest_sell, mom, ranging, fakeout_risk_sell,
                               sup, res, close[i], atr, spread[i]);

   // === SIGNAL DECISION ===
   bool valid_buy  = (score_buy  >= MinimumSignalScore) && !ranging && !fakeout_risk_buy;
   bool valid_sell = (score_sell >= MinimumSignalScore) && !ranging && !fakeout_risk_sell;

   if(valid_buy)
     {
      buyBuf[i] = low[i] - 2 * atr * 0.3;
      g_last_buy_time = time[i];
      g_last_score    = score_buy;
      g_last_action   = "BUY VALID";

      // Compute trade levels
      double sl  = CalcSL(i, true, rates_total, low, high, atr);
      double risk = MathAbs(close[i] - sl);
      double tp1 = close[i] + risk * TP1_RiskReward;
      double tp2 = close[i] + risk * TP2_RiskReward;
      double tp3 = close[i] + risk * TP3_RiskReward;
      double be  = close[i] + risk * BreakevenTrigger;

      g_last_entry = close[i]; g_last_sl = sl;
      g_last_tp1 = tp1; g_last_tp2 = tp2;
      g_last_tp3 = tp3; g_last_be  = be;

      DrawTradeLevels(close[i], sl, tp1, tp2, tp3, be, true, time[i]);
      DrawSignalLabel(i, true, score_buy, htf_bull, ltf_bull, retest_buy, bos_bull, mom, time[i], high, low);

      g_in_buy_trade  = true;
      g_in_sell_trade = false;
      g_trade_entry   = close[i];
      g_trade_sl      = sl;
      g_trade_tp1     = tp1;

      FireAlert(true, close[i], sl, tp1, tp2, be, score_buy, htf_bull, bos_bull, retest_buy, mom);
     }
   else if(valid_sell)
     {
      sellBuf[i] = high[i] + 2 * atr * 0.3;
      g_last_sell_time = time[i];
      g_last_score     = score_sell;
      g_last_action    = "SELL VALID";

      double sl  = CalcSL(i, false, rates_total, low, high, atr);
      double risk = MathAbs(sl - close[i]);
      double tp1 = close[i] - risk * TP1_RiskReward;
      double tp2 = close[i] - risk * TP2_RiskReward;
      double tp3 = close[i] - risk * TP3_RiskReward;
      double be  = close[i] - risk * BreakevenTrigger;

      g_last_entry = close[i]; g_last_sl = sl;
      g_last_tp1 = tp1; g_last_tp2 = tp2;
      g_last_tp3 = tp3; g_last_be  = be;

      DrawTradeLevels(close[i], sl, tp1, tp2, tp3, be, false, time[i]);
      DrawSignalLabel(i, false, score_sell, htf_bear, ltf_bear, retest_sell, bos_bear, mom, time[i], high, low);

      g_in_sell_trade = true;
      g_in_buy_trade  = false;
      g_trade_entry   = close[i];
      g_trade_sl      = sl;
      g_trade_tp1     = tp1;

      FireAlert(false, close[i], sl, tp1, tp2, be, score_sell, htf_bear, bos_bear, retest_sell, mom);
     }

   // --- Update global state strings for dashboard
   g_htf_bias = htf_bull ? "Bullish" : (htf_bear ? "Bearish" : "Neutral");
   g_ltf_bias = ltf_bull ? "Bullish" : (ltf_bear ? "Bearish" : "Neutral");
   g_last_market = ranging ? "Ranging" : ((htf_bull || ltf_bull) ? "Trending Up" : ((htf_bear || ltf_bear) ? "Trending Down" : "Mixed"));
   g_fakeout_risk = (fakeout_risk_buy || fakeout_risk_sell) ? "HIGH" : "Low";
   g_last_momentum = MomToString(mom);

   if(!valid_buy && !valid_sell)
     {
      if(ranging)           g_last_action = "MARKET RANGING";
      else if(fakeout_risk_buy || fakeout_risk_sell) g_last_action = "FAKEOUT RISK";
      else if(score_buy >= MinimumSignalScore - 15 || score_sell >= MinimumSignalScore - 15)
                            g_last_action = "WAIT FOR CONFIRMATION";
      else                  g_last_action = "NO TRADE";
     }
  }

//+------------------------------------------------------------------+
//|  F O R M I N G   S E T U P   C H E C K  (current candle)        |
//+------------------------------------------------------------------+
void CheckFormingSetup(int i, int rates_total,
                        const double &open[], const double &high[],
                        const double &low[], const double &close[],
                        const long &tick_volume[],
                        bool &forming_buy, bool &forming_sell, int &score)
  {
   forming_buy = false; forming_sell = false; score = 0;
   if(i < SwingLookbackBars + 2) return;

   double atr = CalcATR(i, 14, high, low, close);
   bool htf_bull, htf_bear, ltf_bull, ltf_bear;
   GetHTFBias(i, htf_bull, htf_bear);
   GetLTFBias(i, rates_total, high, low, close, ltf_bull, ltf_bear);

   bool ranging = IsRanging(i, rates_total, high, low, close, atr);
   if(ranging) return;

   int mom = CalcMomentum(i, rates_total, close, open, high, low);

   double body = MathAbs(close[i] - open[i]);
   double range = high[i] - low[i];
   bool bull_forming = (close[i] > open[i]) && body > range * 0.4;
   bool bear_forming = (close[i] < open[i]) && body > range * 0.4;

   if(htf_bull && ltf_bull && bull_forming && mom >= 1) { forming_buy = true; score = 55; }
   if(htf_bear && ltf_bear && bear_forming && mom <= -1) { forming_sell = true; score = 55; }
  }

//+------------------------------------------------------------------+
//|  S C O R E   F U N C T I O N S                                   |
//+------------------------------------------------------------------+
int ScoreBuy(bool htf_bull, bool ltf_bull, bool strong_candle, bool bos,
             bool retest, int mom, bool ranging, bool fakeout,
             double sup, double res, double price, double atr, int spread_pts)
  {
   if(ranging || fakeout) return 0;
   int score = 0;
   if(UseHTFBias)         { if(htf_bull) score += 25; else if(!htf_bull) score -= 20; }
   if(ltf_bull)            score += 15;
   if(strong_candle)       score += 10;
   if(bos)                 score += 15;
   if(UseRetestConfirmation && retest) score += 10;
   if(UseMomentumFilter)  { if(mom == 2) score += 15; else if(mom == 1) score += 8; else if(mom <= 0) score -= 5; }
   // S/R proximity
   if(UseSupportResistance && sup > 0 && MathAbs(price - sup) < atr * 1.5) score += 10;
   if(UseSupportResistance && res > 0 && MathAbs(res - price) < atr * 0.5) score -= 15; // too close to resistance
   if(UseSpreadFilter && spread_pts > MaxSpreadAllowed) score -= 20;
   return MathMax(0, MathMin(100, score));
  }

int ScoreSell(bool htf_bear, bool ltf_bear, bool strong_candle, bool bos,
              bool retest, int mom, bool ranging, bool fakeout,
              double sup, double res, double price, double atr, int spread_pts)
  {
   if(ranging || fakeout) return 0;
   int score = 0;
   if(UseHTFBias)          { if(htf_bear) score += 25; else if(!htf_bear) score -= 20; }
   if(ltf_bear)             score += 15;
   if(strong_candle)        score += 10;
   if(bos)                  score += 15;
   if(UseRetestConfirmation && retest) score += 10;
   if(UseMomentumFilter)   { if(mom == -2) score += 15; else if(mom == -1) score += 8; else if(mom >= 0) score -= 5; }
   if(UseSupportResistance && res > 0 && MathAbs(res - price) < atr * 1.5) score += 10;
   if(UseSupportResistance && sup > 0 && MathAbs(price - sup) < atr * 0.5) score -= 15;
   if(UseSpreadFilter && spread_pts > MaxSpreadAllowed) score -= 20;
   return MathMax(0, MathMin(100, score));
  }

//+------------------------------------------------------------------+
//|  H T F   B I A S                                                  |
//+------------------------------------------------------------------+
void GetHTFBias(int bar_idx, bool &is_bull, bool &is_bear)
  {
   is_bull = false; is_bear = false;
   if(!UseHTFBias) return;

   ENUM_TIMEFRAMES htf = (ENUM_TIMEFRAMES)g_htf1_tf;
   double htf_close[], htf_open[], htf_high[], htf_low[];
   if(CopyClose(_Symbol, htf, 0, 20, htf_close) < 10) return;
   if(CopyOpen (_Symbol, htf, 0, 20, htf_open)  < 10) return;
   if(CopyHigh (_Symbol, htf, 0, 20, htf_high)  < 10) return;
   if(CopyLow  (_Symbol, htf, 0, 20, htf_low)   < 10) return;

   // Simple HH/HL or LH/LL over last 10 HTF candles
   double hh = htf_high[ArrayMaximum(htf_high, 0, 10)];
   double ll = htf_low [ArrayMinimum(htf_low,  0, 10)];
   double mid = (hh + ll) / 2.0;
   double cur = htf_close[ArraySize(htf_close)-1];

   // EMA-style bias
   double ema_val = 0;
   for(int k = 0; k < 10; k++) ema_val += htf_close[k];
   ema_val /= 10.0;

   if(cur > ema_val && cur > mid) is_bull = true;
   else if(cur < ema_val && cur < mid) is_bear = true;
  }

//+------------------------------------------------------------------+
//|  L T F   B I A S (current timeframe structure)                   |
//+------------------------------------------------------------------+
void GetLTFBias(int i, int total,
                const double &high[], const double &low[], const double &close[],
                bool &is_bull, bool &is_bear)
  {
   is_bull = false; is_bear = false;
   int lb = MathMin(SwingLookbackBars, i - 2);
   if(lb < 5) return;

   // Find recent swing high and low
   double recent_high = high[ArrayMaximum(high, i - lb, lb)];
   double recent_low  = low [ArrayMinimum(low,  i - lb, lb)];
   double price = close[i];
   double mid = (recent_high + recent_low) / 2.0;

   // EMA 20
   double ema = 0;
   int cnt = MathMin(20, lb);
   for(int k = i - cnt; k <= i; k++) ema += close[k];
   ema /= (cnt + 1);

   if(price > ema && price > mid) is_bull = true;
   else if(price < ema && price < mid) is_bear = true;
  }

//+------------------------------------------------------------------+
//|  R A N G I N G   D E T E C T I O N                               |
//+------------------------------------------------------------------+
bool IsRanging(int i, int total,
               const double &high[], const double &low[], const double &close[],
               double atr)
  {
   int lb = MathMin(SwingLookbackBars, i - 2);
   if(lb < 6) return false;

   double range_high = high[ArrayMaximum(high, i - lb, lb)];
   double range_low  = low [ArrayMinimum(low,  i - lb, lb)];
   double range_size = range_high - range_low;

   // Ranging if total range is small relative to ATR
   if(range_size < atr * 3.0) return true;

   // Count how many times price has crossed the midpoint (choppiness)
   double mid = (range_high + range_low) / 2.0;
   int crosses = 0;
   for(int k = i - lb + 1; k <= i; k++)
     {
      if((close[k] > mid && close[k-1] < mid) ||
         (close[k] < mid && close[k-1] > mid))
         crosses++;
     }
   if(crosses >= 4) return true;

   return false;
  }

//+------------------------------------------------------------------+
//|  N E A R E S T   Z O N E S                                       |
//+------------------------------------------------------------------+
void GetNearestZones(int i, int total,
                     const double &high[], const double &low[], const double &close[],
                     double atr,
                     double &support_out, double &resistance_out)
  {
   support_out = 0; resistance_out = 0;
   if(i < ZoneLookbackBars + 2) return;

   double price = close[i];
   double best_sup = 0, best_res = 0;
   double best_sup_dist = 1e10, best_res_dist = 1e10;

   int lb = MathMin(ZoneLookbackBars, i - 2);
   double zone_width = atr * ZoneWidthMultiplier;

   for(int k = i - lb; k < i - 2; k++)
     {
      // Swing low = potential support
      if(IsSwingLow(k, low, 3))
        {
         double level = low[k];
         if(level < price && price - level < best_sup_dist)
           { best_sup = level; best_sup_dist = price - level; }
        }
      // Swing high = potential resistance
      if(IsSwingHigh(k, high, 3))
        {
         double level = high[k];
         if(level > price && level - price < best_res_dist)
           { best_res = level; best_res_dist = level - price; }
        }
     }

   support_out    = best_sup;
   resistance_out = best_res;

   // Draw the zones
   if(UseSupportResistance)
     {
      if(best_sup > 0)
         DrawZone(best_sup - zone_width, best_sup + zone_width, clrDarkGreen, "SUP_" + IntegerToString(i));
      if(best_res > 0)
         DrawZone(best_res - zone_width, best_res + zone_width, clrFireBrick, "RES_" + IntegerToString(i));
     }
  }

//+------------------------------------------------------------------+
//|  F A K E O U T   F I L T E R                                     |
//+------------------------------------------------------------------+
void CheckFakeout(int i,
                  const double &open[], const double &high[],
                  const double &low[],  const double &close[],
                  double atr,
                  bool &fakeout_buy, bool &fakeout_sell)
  {
   fakeout_buy = false; fakeout_sell = false;
   double body  = MathAbs(close[i] - open[i]);
   double range = high[i] - low[i];
   if(range < 0.0001) return;

   double upper_wick = high[i] - MathMax(open[i], close[i]);
   double lower_wick = MathMin(open[i], close[i]) - low[i];
   double body_ratio = body / range;

   // Wick larger than body → fakeout risk
   if(body_ratio < 0.35) { fakeout_buy = true; fakeout_sell = true; return; }

   // Candle closes near middle
   if(body_ratio < 0.45) { fakeout_buy = true; fakeout_sell = true; return; }

   // For bull candle: large upper wick = fakeout buy risk
   if(close[i] > open[i] && upper_wick > body * 0.8) fakeout_buy = true;
   // For bear candle: large lower wick = fakeout sell risk
   if(close[i] < open[i] && lower_wick > body * 0.8) fakeout_sell = true;
  }

//+------------------------------------------------------------------+
//|  M O M E N T U M   C A L C                                       |
//+------------------------------------------------------------------+
int CalcMomentum(int i, int total,
                 const double &close[], const double &open[],
                 const double &high[],  const double &low[])
  {
   // +2 strong bull, +1 weak bull, 0 neutral, -1 weak bear, -2 strong bear
   if(i < 5) return 0;

   // 1. Consecutive direction
   int bull_streak = 0, bear_streak = 0;
   for(int k = i; k >= i - 3 && k >= 1; k--)
     {
      if(close[k] > open[k]) bull_streak++;
      else                   bear_streak++;
     }

   // 2. EMA distance
   double ema14 = 0;
   int cnt = MathMin(14, i);
   for(int k = i - cnt + 1; k <= i; k++) ema14 += close[k];
   ema14 /= cnt;
   double ema_dist = close[i] - ema14;
   double atr = CalcATR(i, 14, high, low, close);

   // 3. Combine
   int score = 0;
   if(bull_streak >= 3) score += 2;
   else if(bull_streak == 2) score += 1;
   if(bear_streak >= 3) score -= 2;
   else if(bear_streak == 2) score -= 1;
   if(ema_dist >  atr * 0.5) score += 1;
   if(ema_dist < -atr * 0.5) score -= 1;

   return MathMax(-2, MathMin(2, score));
  }

//+------------------------------------------------------------------+
//|  R E T E S T   C H E C K                                         |
//+------------------------------------------------------------------+
void CheckRetest(int i,
                 const double &open[], const double &high[],
                 const double &low[],  const double &close[],
                 double atr, double sup, double res,
                 bool &retest_buy, bool &retest_sell)
  {
   retest_buy = false; retest_sell = false;
   double tol = atr * 0.6;

   // Retest buy: candle low touched support and close is above
   if(sup > 0 && low[i] <= sup + tol && close[i] > sup)
      retest_buy = true;
   // Retest sell: candle high touched resistance and close is below
   if(res > 0 && high[i] >= res - tol && close[i] < res)
      retest_sell = true;
  }

//+------------------------------------------------------------------+
//|  B R E A K   O F   S T R U C T U R E                             |
//+------------------------------------------------------------------+
bool IsBullishBOS(int i, int total, const double &high[], const double &low[], const double &close[])
  {
   int lb = MathMin(SwingLookbackBars, i - 2);
   if(lb < 5) return false;
   // BOS: close above recent swing high
   for(int k = i - 2; k >= i - lb; k--)
     {
      if(IsSwingHigh(k, high, 3))
        {
         if(close[i] > high[k]) return true;
         break;
        }
     }
   return false;
  }

bool IsBearishBOS(int i, int total, const double &high[], const double &low[], const double &close[])
  {
   int lb = MathMin(SwingLookbackBars, i - 2);
   if(lb < 5) return false;
   for(int k = i - 2; k >= i - lb; k--)
     {
      if(IsSwingLow(k, low, 3))
        {
         if(close[i] < low[k]) return true;
         break;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//|  S W I N G   D E T E C T I O N                                   |
//+------------------------------------------------------------------+
bool IsSwingHigh(int i, const double &high[], int wings)
  {
   for(int w = 1; w <= wings; w++)
     {
      if(i - w < 0 || i + w >= ArraySize(high)) return false;
      if(high[i] <= high[i - w] || high[i] <= high[i + w]) return false;
     }
   return true;
  }

bool IsSwingLow(int i, const double &low[], int wings)
  {
   for(int w = 1; w <= wings; w++)
     {
      if(i - w < 0 || i + w >= ArraySize(low)) return false;
      if(low[i] >= low[i - w] || low[i] >= low[i + w]) return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//|  A T R                                                            |
//+------------------------------------------------------------------+
double CalcATR(int i, int period, const double &high[], const double &low[], const double &close[])
  {
   if(i < period + 1) return (high[i] - low[i]);
   double sum = 0;
   for(int k = i - period + 1; k <= i; k++)
     {
      double tr = MathMax(high[k] - low[k],
                  MathMax(MathAbs(high[k] - close[k-1]),
                          MathAbs(low[k]  - close[k-1])));
      sum += tr;
     }
   return sum / period;
  }

//+------------------------------------------------------------------+
//|  S T O P   L O S S   C A L C                                     |
//+------------------------------------------------------------------+
double CalcSL(int i, bool is_buy, int total,
              const double &low[], const double &high[], double atr)
  {
   if(is_buy)
     {
      // Find nearest swing low
      int lb = MathMin(SwingLookbackBars, i - 2);
      double sl_level = low[i];
      for(int k = i - 1; k >= i - lb; k--)
        {
         if(IsSwingLow(k, low, 2))
           { sl_level = low[k]; break; }
        }
      return MathMin(sl_level, low[i]) - atr * 0.3;
     }
   else
     {
      int lb = MathMin(SwingLookbackBars, i - 2);
      double sl_level = high[i];
      for(int k = i - 1; k >= i - lb; k--)
        {
         if(IsSwingHigh(k, high, 2))
           { sl_level = high[k]; break; }
        }
      return MathMax(sl_level, high[i]) + atr * 0.3;
     }
  }

//+------------------------------------------------------------------+
//|  M A N A G E   T R A D E   (live bar)                            |
//+------------------------------------------------------------------+
void ManageTrade(int i, const double &high[], const double &low[], const double &close[])
  {
   if(!g_in_buy_trade && !g_in_sell_trade) return;

   double price = close[i];

   if(g_in_buy_trade)
     {
      if(UseBreakevenLogic)
        {
         double prog = (price - g_trade_entry) / (g_trade_tp1 - g_trade_entry);
         if(prog >= BreakevenTrigger)
            DashboardLine("Action", "MOVE TO BREAKEVEN", clrYellow);
        }
      if(UseExitWarnings)
        {
         // Close back inside zone or momentum reversal
         if(price < g_trade_entry - (g_trade_tp1 - g_trade_entry) * 0.1)
           { g_last_action = "EXIT NOW"; DashboardLine("Action", "EXIT NOW", clrRed); }
         else if(price >= g_trade_tp1)
           { g_last_action = "SECURE PROFIT"; DashboardLine("Action", "SECURE PROFIT / TRAIL", clrLime); }
        }
     }

   if(g_in_sell_trade)
     {
      if(UseBreakevenLogic)
        {
         double prog = (g_trade_entry - price) / (g_trade_entry - g_trade_tp1);
         if(prog >= BreakevenTrigger)
            DashboardLine("Action", "MOVE TO BREAKEVEN", clrYellow);
        }
      if(UseExitWarnings)
        {
         if(price > g_trade_entry + (g_trade_entry - g_trade_tp1) * 0.1)
           { g_last_action = "EXIT NOW"; DashboardLine("Action", "EXIT NOW", clrRed); }
         else if(price <= g_trade_tp1)
           { g_last_action = "SECURE PROFIT"; DashboardLine("Action", "SECURE PROFIT / TRAIL", clrLime); }
        }
     }
  }

//+------------------------------------------------------------------+
//|  H T F   T I M E F R A M E   S E L E C T I O N                  |
//+------------------------------------------------------------------+
void SetHTFTimeframes()
  {
   int tf = (int)Period();
   switch(TradingMode)
     {
      case MODE_QUICK:
         g_htf1_tf = (tf <= PERIOD_M5)  ? PERIOD_M15 : PERIOD_H1;
         g_htf2_tf = (tf <= PERIOD_M5)  ? PERIOD_H1  : PERIOD_H4;
         break;
      case MODE_STANDARD:
         g_htf1_tf = (tf <= PERIOD_M15) ? PERIOD_M30 : PERIOD_H1;
         g_htf2_tf = (tf <= PERIOD_M15) ? PERIOD_H1  : PERIOD_H4;
         break;
      case MODE_PRECISION:
         g_htf1_tf = PERIOD_H1;
         g_htf2_tf = PERIOD_H4;
         break;
     }
  }

//+------------------------------------------------------------------+
//|  C L E A N   C H A R T                                           |
//+------------------------------------------------------------------+
void ApplyCleanChart()
  {
   ChartSetInteger(0, CHART_COLOR_BACKGROUND, C'30,40,50');
   ChartSetInteger(0, CHART_COLOR_CANDLE_BULL, clrLime);
   ChartSetInteger(0, CHART_COLOR_CANDLE_BEAR, clrRed);
   ChartSetInteger(0, CHART_COLOR_CHART_UP,    clrLime);
   ChartSetInteger(0, CHART_COLOR_CHART_DOWN,  clrRed);
   ChartSetInteger(0, CHART_COLOR_CHART_LINE,  clrLime);
   ChartSetInteger(0, CHART_COLOR_GRID,        C'30,40,50');  // hidden
   ChartSetInteger(0, CHART_SHOW_GRID,         false);
   ChartSetInteger(0, CHART_SHOW_VOLUMES,      (long)CHART_VOLUME_HIDE);
   ChartSetInteger(0, CHART_COLOR_FOREGROUND,  clrWhiteSmoke);
   // Bid/ask line colours are not settable via ChartSetInteger in all MQL5 builds — skipped
  }

//+------------------------------------------------------------------+
//|  D A S H B O A R D   C R E A T I O N                            |
//+------------------------------------------------------------------+
void CreateDashboard()
  {
   // Background rectangle
   string bg = g_prefix + "DashBG";
   ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, bg, OBJPROP_XDISTANCE,    DashboardX);
   ObjectSetInteger(0, bg, OBJPROP_YDISTANCE,    DashboardY);
   ObjectSetInteger(0, bg, OBJPROP_XSIZE,        260);
   ObjectSetInteger(0, bg, OBJPROP_YSIZE,        480);
   ObjectSetInteger(0, bg, OBJPROP_BGCOLOR,      C'15,22,35');
   ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE,  BORDER_FLAT);
   ObjectSetInteger(0, bg, OBJPROP_COLOR,        C'60,80,100');
   ObjectSetInteger(0, bg, OBJPROP_WIDTH,        1);
   ObjectSetInteger(0, bg, OBJPROP_BACK,         false);
   ObjectSetInteger(0, bg, OBJPROP_SELECTABLE,   false);
   ObjectSetInteger(0, bg, OBJPROP_CORNER,       CORNER_LEFT_UPPER);
  }

//+------------------------------------------------------------------+
//|  U P D A T E   D A S H B O A R D                                 |
//+------------------------------------------------------------------+
void UpdateDashboard(int i, int total,
                     const double &open[], const double &high[],
                     const double &low[],  const double &close[],
                     const long &tick_vol[], const int &spread[])
  {
   if(!EnableDashboard) return;

   color action_color = clrWhiteSmoke;
   if(g_last_action == "BUY VALID")                action_color = clrLime;
   else if(g_last_action == "SELL VALID")           action_color = clrRed;
   else if(g_last_action == "EXIT NOW")             action_color = clrOrangeRed;
   else if(g_last_action == "SECURE PROFIT")        action_color = clrGold;
   else if(g_last_action == "MOVE TO BREAKEVEN")    action_color = clrYellow;
   else if(g_last_action == "MARKET RANGING")       action_color = clrGray;
   else if(g_last_action == "FAKEOUT RISK")         action_color = clrOrange;
   else if(g_last_action == "WAIT FOR CONFIRMATION")action_color = clrCornflowerBlue;

   string sym = _Symbol;
   string tf  = TFToString((ENUM_TIMEFRAMES)Period());
   string mode = ModeToString(TradingMode);
   string spread_str = (i < total) ? DoubleToString(spread[i], 0) + " pts" : "-";

   double score_frac = (g_last_score > 0) ? g_last_score : 0;

   int y = DashboardY + 8;
   int x = DashboardX + 8;
   int step = 22;

   DashLine("T",   "━━ SCALPING MAGIC INDICATOR ━━",     x, y, clrDodgerBlue,  9); y += step;
   DashLine("Sy",  "Symbol  : " + sym,                    x, y, clrWhiteSmoke,  8); y += step - 4;
   DashLine("TF",  "TF      : " + tf,                     x, y, clrWhiteSmoke,  8); y += step - 4;
   DashLine("MD",  "Mode    : " + mode,                   x, y, clrCyan,        8); y += step - 4;
   DashLine("SP",  "Spread  : " + spread_str,             x, y, clrWhiteSmoke,  8); y += step;
   DashLine("HB",  "HTF Bias: " + g_htf_bias,            x, y, BiasColor(g_htf_bias), 8); y += step - 4;
   DashLine("LB",  "LTF Bias: " + g_ltf_bias,            x, y, BiasColor(g_ltf_bias), 8); y += step - 4;
   DashLine("MK",  "Market  : " + g_last_market,         x, y, clrWhiteSmoke,  8); y += step;
   DashLine("SC",  "Score   : " + IntegerToString(g_last_score) + "/100",
                                                           x, y, ScoreColor(g_last_score), 9); y += step - 4;
   DashLine("MOM", "Momentum: " + g_last_momentum,        x, y, MomColor(g_last_momentum), 8); y += step - 4;
   DashLine("FK",  "Fakeout : " + g_fakeout_risk,         x, y, (g_fakeout_risk=="HIGH"?clrOrangeRed:clrLimeGreen), 8); y += step;
   DashLine("EN",  "Entry   : " + (g_last_entry>0 ? DoubleToString(g_last_entry,_Digits):"---"), x, y, clrWhite, 8); y += step - 4;
   DashLine("SL",  "SL      : " + (g_last_sl>0    ? DoubleToString(g_last_sl,   _Digits):"---"), x, y, clrRed,   8); y += step - 4;
   DashLine("T1",  "TP1     : " + (g_last_tp1>0   ? DoubleToString(g_last_tp1,  _Digits):"---"), x, y, clrLime,  8); y += step - 4;
   DashLine("T2",  "TP2     : " + (g_last_tp2>0   ? DoubleToString(g_last_tp2,  _Digits):"---"), x, y, clrLimeGreen,8); y += step - 4;
   DashLine("T3",  "TP3     : " + (g_last_tp3>0   ? DoubleToString(g_last_tp3,  _Digits):"---"), x, y, clrGreenYellow,8); y += step - 4;
   DashLine("BE",  "BE      : " + (g_last_be>0    ? DoubleToString(g_last_be,   _Digits):"---"), x, y, clrYellow,8); y += step;
   DashLine("Action", "► " + g_last_action, x, y, action_color, 10);
  }

//+------------------------------------------------------------------+
//|  D A S H B O A R D   H E L P E R S                              |
//+------------------------------------------------------------------+
void DashLine(string key, string text, int x, int y, color clr, int font_size)
  {
   string name = g_prefix + "D_" + key;
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_BACK,       false);
      ObjectSetString (0, name, OBJPROP_FONT,       "Consolas");
     }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,  font_size);
   ObjectSetInteger(0, name, OBJPROP_COLOR,     clr);
   ObjectSetString (0, name, OBJPROP_TEXT,      text);
  }

void DashboardLine(string key, string text, color clr)
  {
   string name = g_prefix + "D_" + key;
   if(ObjectFind(0, name) >= 0)
     {
      ObjectSetString (0, name, OBJPROP_TEXT,  "► " + text);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
     }
  }

//+------------------------------------------------------------------+
//|  D R A W   T R A D E   L E V E L S                              |
//+------------------------------------------------------------------+
void DrawTradeLevels(double entry, double sl,
                     double tp1, double tp2, double tp3,
                     double be, bool is_buy, datetime t)
  {
   // Clean up old lines
   ObjectsDeleteAll(0, g_prefix + "LVL_");

   color entry_clr = clrDodgerBlue;
   color sl_clr    = clrRed;
   color tp_clr    = clrLime;
   color be_clr    = clrYellow;

   DrawHLine("LVL_Entry", entry, entry_clr, STYLE_SOLID,  1, "ENTRY " + DoubleToString(entry, _Digits));
   DrawHLine("LVL_SL",    sl,    sl_clr,    STYLE_DASH,   1, "SL "    + DoubleToString(sl,    _Digits));
   DrawHLine("LVL_TP1",   tp1,   tp_clr,    STYLE_SOLID,  1, "TP1 "   + DoubleToString(tp1,   _Digits));
   DrawHLine("LVL_TP2",   tp2,   tp_clr,    STYLE_DOT,    1, "TP2 "   + DoubleToString(tp2,   _Digits));
   DrawHLine("LVL_TP3",   tp3,   clrYellowGreen, STYLE_DOT, 1, "TP3 " + DoubleToString(tp3,   _Digits));
   if(UseBreakevenLogic)
      DrawHLine("LVL_BE",  be,   be_clr,    STYLE_DOT,    1, "BE "    + DoubleToString(be,    _Digits));
  }

void DrawHLine(string key, double price, color clr, ENUM_LINE_STYLE style, int width, string lbl)
  {
   string name = g_prefix + key;
   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR,      clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE,      style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH,      width);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetString (0, name, OBJPROP_TEXT,       lbl);
  }

//+------------------------------------------------------------------+
//|  D R A W   Z O N E                                               |
//+------------------------------------------------------------------+
void DrawZone(double low_p, double high_p, color clr, string tag)
  {
   string name = g_prefix + "Z_" + tag;
   if(ObjectFind(0, name) >= 0) return; // already drawn
   datetime t1 = iTime(_Symbol, PERIOD_CURRENT, ZoneLookbackBars);
   datetime t2 = iTime(_Symbol, PERIOD_CURRENT, 0) + PeriodSeconds() * 20;
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, high_p, t2, low_p);
   ObjectSetInteger(0, name, OBJPROP_COLOR,      clr);
   ObjectSetInteger(0, name, OBJPROP_FILL,       true);
   ObjectSetInteger(0, name, OBJPROP_BACK,       true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   color fill = (clr == clrDarkGreen) ? C'0,40,10' : C'40,5,5';
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR,    fill);
   ObjectSetInteger(0, name, OBJPROP_STYLE,      STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_WIDTH,      1);
  }

//+------------------------------------------------------------------+
//|  D R A W   S I G N A L   L A B E L                              |
//+------------------------------------------------------------------+
void DrawSignalLabel(int i, bool is_buy, int score,
                     bool htf_aligned, bool ltf_aligned,
                     bool retest, bool bos, int mom,
                     datetime t,
                     const double &high[], const double &low[])
  {
   string direction = is_buy ? "BUY" : "SELL";
   string name      = g_prefix + "LBL_" + IntegerToString((int)t);
   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);

   string reason = direction + " VALID\n";
   reason += "HTF: " + (htf_aligned ? "Aligned" : "Neutral") + " | ";
   reason += "LTF: " + (ltf_aligned ? "Aligned" : "Neutral") + "\n";
   reason += "BOS: " + (bos ? "YES" : "NO") + " | Retest: " + (retest ? "YES" : "NO") + "\n";
   reason += "Mom: " + MomToString(mom) + " | Score: " + IntegerToString(score);

   double price = is_buy ? (low[i] - CalcATR(i, 14, high, low, high) * 0.8)
                         : (high[i] + CalcATR(i, 14, high, low, high) * 0.8);

   ObjectCreate(0, name, OBJ_TEXT, 0, t, price);
   ObjectSetString (0, name, OBJPROP_TEXT,      reason);
   ObjectSetInteger(0, name, OBJPROP_COLOR,     is_buy ? clrLime : clrRed);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,  7);
   ObjectSetString (0, name, OBJPROP_FONT,      "Consolas");
   ObjectSetInteger(0, name, OBJPROP_ANCHOR,    is_buy ? ANCHOR_TOP : ANCHOR_BOTTOM);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE,false);
  }

//+------------------------------------------------------------------+
//|  A L E R T S                                                     |
//+------------------------------------------------------------------+
void FireAlert(bool is_buy, double entry, double sl,
               double tp1, double tp2, double be,
               int score, bool htf, bool bos, bool retest, int mom)
  {
   if(!EnableAlerts && !EnablePushNotifications &&
      !EnableEmailAlerts && !EnableSoundAlerts) return;

   string dir = is_buy ? "BUY" : "SELL";
   string msg = dir + " SIGNAL — " + _Symbol + " " + TFToString((ENUM_TIMEFRAMES)Period()) + "\n";
   msg += "Entry : " + DoubleToString(entry, _Digits) + "\n";
   msg += "SL    : " + DoubleToString(sl,    _Digits) + "\n";
   msg += "TP1   : " + DoubleToString(tp1,   _Digits) + "\n";
   msg += "TP2   : " + DoubleToString(tp2,   _Digits) + "\n";
   msg += "BE    : " + DoubleToString(be,    _Digits) + "\n";
   msg += "Score : " + IntegerToString(score) + "/100\n";
   msg += "Reason: " + (htf?"HTF Aligned ":"") + (bos?"BOS ":"") +
          (retest?"Retest ":"") + "Mom:" + MomToString(mom);

   if(EnableAlerts)             Alert(msg);
   if(EnablePushNotifications)  SendNotification(msg);
   if(EnableEmailAlerts)        SendMail(dir + " Signal — " + _Symbol, msg);
   if(EnableSoundAlerts)        PlaySound(AlertSound);
  }

//+------------------------------------------------------------------+
//|  U T I L I T Y   S T R I N G S                                  |
//+------------------------------------------------------------------+
string ModeToString(ENUM_TRADING_MODE m)
  {
   if(m == MODE_QUICK)     return "Quick Scalp";
   if(m == MODE_STANDARD)  return "Standard Scalp";
   return "Precision Scalp";
  }

string TFToString(ENUM_TIMEFRAMES tf)
  {
   switch(tf)
     {
      case PERIOD_M1:  return "M1";  case PERIOD_M2:  return "M2";
      case PERIOD_M3:  return "M3";  case PERIOD_M4:  return "M4";
      case PERIOD_M5:  return "M5";  case PERIOD_M6:  return "M6";
      case PERIOD_M10: return "M10"; case PERIOD_M12: return "M12";
      case PERIOD_M15: return "M15"; case PERIOD_M20: return "M20";
      case PERIOD_M30: return "M30"; case PERIOD_H1:  return "H1";
      case PERIOD_H2:  return "H2";  case PERIOD_H3:  return "H3";
      case PERIOD_H4:  return "H4";  case PERIOD_H6:  return "H6";
      case PERIOD_H8:  return "H8";  case PERIOD_H12: return "H12";
      case PERIOD_D1:  return "D1";  case PERIOD_W1:  return "W1";
      case PERIOD_MN1: return "MN";  default:         return "??";
     }
  }

string MomToString(int mom)
  {
   switch(mom)
     {
      case  2: return "Strong Bullish";
      case  1: return "Weak Bullish";
      case  0: return "Neutral";
      case -1: return "Weak Bearish";
      case -2: return "Strong Bearish";
      default: return "Neutral";
     }
  }

color BiasColor(string bias)
  {
   if(bias == "Bullish") return clrLime;
   if(bias == "Bearish") return clrRed;
   return clrGray;
  }

color MomColor(string mom)
  {
   if(StringFind(mom, "Strong Bull") >= 0) return clrLime;
   if(StringFind(mom, "Weak Bull")   >= 0) return clrYellowGreen;
   if(StringFind(mom, "Strong Bear") >= 0) return clrRed;
   if(StringFind(mom, "Weak Bear")   >= 0) return clrOrangeRed;
   return clrGray;
  }

color ScoreColor(int score)
  {
   if(score >= 80) return clrLime;
   if(score >= 65) return clrYellow;
   if(score >= 50) return clrOrange;
   return clrRed;
  }
//+------------------------------------------------------------------+
// END OF SCALPING MAGIC INDICATOR
//+------------------------------------------------------------------+