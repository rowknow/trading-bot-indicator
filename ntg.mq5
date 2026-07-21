//+------------------------------------------------------------------+
//|                                     AO_LWMA_M1_Scalping.mq5       |
//|   Strategy 2D: AO + LWMA M1 Scalping  -  Boom 1000 / Crash 1000   |
//|                                                                    |
//|   Boom 1000  SELL : NormAO >= UpperLevel  AND  Close < LWMA(10)   |
//|   Crash 1000 BUY  : NormAO <= LowerLevel  AND  Close > LWMA(10)   |
//|   Exit        : 5 candles time-based, OR instant cut on loss      |
//|   Stochastic 90/10 = visual reference only, NOT a trigger         |
//+------------------------------------------------------------------+
#property copyright "Money Pree"
#property version   "1.00"
#property strict
#property indicator_chart_window
#property indicator_buffers 3
#property indicator_plots   3

#property indicator_type1   DRAW_LINE
#property indicator_color1  clrAqua
#property indicator_width1  2
#property indicator_style1  STYLE_SOLID
#property indicator_label1  "LWMA(10)"

#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrLime
#property indicator_width2  2
#property indicator_label2  "BUY Signal"

#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrRed
#property indicator_width3  2
#property indicator_label3  "SELL Signal"

//--- Trade direction mode
enum ENUM_TRADE_MODE
  {
   MODE_AUTO_DETECT,    // Auto: Boom=SELL only, Crash=BUY only
   MODE_SELL_ONLY,
   MODE_BUY_ONLY,
   MODE_BOTH
  };

input group "=== Core Settings ==="
input int              InpLWMAPeriod      = 10;              // LWMA Period
input int              InpAOLookback      = 34;               // AO Normalization Lookback (bars)
input double           InpUpperLevel      = 90.0;             // Upper Level (SELL trigger, Boom)
input double           InpLowerLevel      = 10.0;             // Lower Level (BUY trigger, Crash)
input ENUM_TRADE_MODE  InpTradeMode       = MODE_AUTO_DETECT;  // Trade Direction Mode

input group "=== Stochastic (Visual Reference Only) ==="
input int               InpStochK         = 5;                // %K Period
input int               InpStochD         = 3;                // %D Period
input int               InpStochSlowing   = 3;                // Slowing
input bool              InpShowStochPanel = true;              // Show Info Panel

input group "=== Exit Zone Visual ==="
input bool              InpShowExitZone   = true;              // Draw 5-Candle Exit Marker
input int               InpExitCandles    = 5;                 // Candles Until Time-Based Exit

input group "=== Alerts ==="
input bool               InpEnableAlerts  = true;              // Popup Alert on Confirmed Signal
input bool               InpEnablePush    = false;             // Push Notification on Confirmed Signal
input bool               InpWarnIfNotM1   = true;              // Warn if chart is not M1

//--- Buffers
double LWMABuffer[];
double BuyArrowBuffer[];
double SellArrowBuffer[];

//--- Handles
int hLWMA = INVALID_HANDLE;
int hAO   = INVALID_HANDLE;
int hStoch= INVALID_HANDLE;

//--- Direction flags
bool AllowSell = false;
bool AllowBuy  = false;

//--- Bar-close tracking (used to fire alerts only once per confirmed candle)
datetime g_lastBarTime = 0;

//--- Panel object prefix
#define PANEL_PREFIX "AOLWMA_Panel_"
#define ZONE_PREFIX  "AOLWMA_Zone_"

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
  {
   SetIndexBuffer(0, LWMABuffer,     INDICATOR_DATA);
   SetIndexBuffer(1, BuyArrowBuffer, INDICATOR_DATA);
   SetIndexBuffer(2, SellArrowBuffer,INDICATOR_DATA);

   ArraySetAsSeries(LWMABuffer,      false);
   ArraySetAsSeries(BuyArrowBuffer,  false);
   ArraySetAsSeries(SellArrowBuffer, false);

   PlotIndexSetInteger(1, PLOT_ARROW, 233);          // up arrow
   PlotIndexSetInteger(2, PLOT_ARROW, 234);          // down arrow
   PlotIndexSetDouble (0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble (1, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble (2, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   hLWMA  = iMA(_Symbol, PERIOD_CURRENT, InpLWMAPeriod, 0, MODE_LWMA, PRICE_CLOSE);
   hAO    = iAO(_Symbol, PERIOD_CURRENT);
   hStoch = iStochastic(_Symbol, PERIOD_CURRENT, InpStochK, InpStochD, InpStochSlowing, MODE_SMA, STO_LOWHIGH);

   if(hLWMA==INVALID_HANDLE || hAO==INVALID_HANDLE || hStoch==INVALID_HANDLE)
     {
      Print("AO_LWMA_M1_Scalping: failed to create indicator handles");
      return(INIT_FAILED);
     }

   ResolveDirection();

   if(InpWarnIfNotM1 && _Period!=PERIOD_M1)
      Print("AO_LWMA_M1_Scalping: strategy is designed for M1 - current chart is ", EnumToString((ENUM_TIMEFRAMES)_Period));

   IndicatorSetString(INDICATOR_SHORTNAME, "AO+LWMA M1 Scalping ("+_Symbol+")");

   if(InpShowStochPanel)
      CreatePanel();

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Work out which side(s) this symbol/mode is allowed to signal     |
//+------------------------------------------------------------------+
void ResolveDirection()
  {
   AllowSell = (InpTradeMode==MODE_SELL_ONLY || InpTradeMode==MODE_BOTH);
   AllowBuy  = (InpTradeMode==MODE_BUY_ONLY  || InpTradeMode==MODE_BOTH);

   if(InpTradeMode==MODE_AUTO_DETECT)
     {
      string sym = _Symbol;
      bool isBoom  = (StringFind(sym,"Boom")>=0  || StringFind(sym,"BOOM")>=0);
      bool isCrash = (StringFind(sym,"Crash")>=0 || StringFind(sym,"CRASH")>=0);

      if(isBoom)  AllowSell = true;
      if(isCrash) AllowBuy  = true;
      if(!isBoom && !isCrash)
        {
         // Unknown symbol name - allow both, per-bar conditions still gate entries
         AllowSell = true;
         AllowBuy  = true;
         Print("AO_LWMA_M1_Scalping: symbol name has no Boom/Crash tag - both directions enabled");
        }
     }
  }

//+------------------------------------------------------------------+
//| Custom indicator deinitialization function                       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, ZONE_PREFIX);
   ObjectsDeleteAll(0, PANEL_PREFIX);

   if(hLWMA!=INVALID_HANDLE)  IndicatorRelease(hLWMA);
   if(hAO!=INVALID_HANDLE)    IndicatorRelease(hAO);
   if(hStoch!=INVALID_HANDLE) IndicatorRelease(hStoch);
  }

//+------------------------------------------------------------------+
//| Custom indicator iteration function                              |
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
   int minBars = InpAOLookback + 5;
   if(rates_total < minBars)
      return(0);

   ArraySetAsSeries(time,  false);
   ArraySetAsSeries(open,  false);
   ArraySetAsSeries(high,  false);
   ArraySetAsSeries(low,   false);
   ArraySetAsSeries(close, false);

   double lwma[], ao[], stochK[], stochD[];
   ArraySetAsSeries(lwma,   false);
   ArraySetAsSeries(ao,     false);
   ArraySetAsSeries(stochK, false);
   ArraySetAsSeries(stochD, false);

   if(CopyBuffer(hLWMA, 0, 0, rates_total, lwma)   <=0) return(prev_calculated);
   if(CopyBuffer(hAO,   0, 0, rates_total, ao)     <=0) return(prev_calculated);
   if(CopyBuffer(hStoch,0, 0, rates_total, stochK) <=0) return(prev_calculated);
   if(CopyBuffer(hStoch,1, 0, rates_total, stochD) <=0) return(prev_calculated);

   int start = (prev_calculated>1) ? prev_calculated-2 : InpAOLookback;
   if(start < InpAOLookback) start = InpAOLookback;

   for(int i=start; i<rates_total; i++)
     {
      LWMABuffer[i]      = lwma[i];
      BuyArrowBuffer[i]  = EMPTY_VALUE;
      SellArrowBuffer[i] = EMPTY_VALUE;

      // --- Normalize AO into a 0-100 range (Stochastic-of-AO) over the lookback window
      double hi = ao[i];
      double lo = ao[i];
      int winStart = i - InpAOLookback + 1;
      if(winStart < 0) winStart = 0;
      for(int k=winStart; k<=i; k++)
        {
         if(ao[k] > hi) hi = ao[k];
         if(ao[k] < lo) lo = ao[k];
        }
      double range = hi - lo;
      double normAO = (range > 0.0) ? (ao[i]-lo)/range*100.0 : 50.0;

      bool sellCond = (normAO >= InpUpperLevel) && (close[i] < lwma[i]);
      bool buyCond  = (normAO <= InpLowerLevel) && (close[i] > lwma[i]);

      // --- Dynamic arrow offset based on recent volatility (works across all Deriv price scales)
      double rangeSum = 0.0;
      int    rangeCnt = 0;
      int    volStart = i-9; if(volStart<0) volStart=0;
      for(int k=volStart; k<=i; k++) { rangeSum += (high[k]-low[k]); rangeCnt++; }
      double avgRange = (rangeCnt>0) ? rangeSum/rangeCnt : _Point*10;
      double offset   = avgRange*0.6;
      if(offset<=0.0) offset = _Point*10;

      if(sellCond && AllowSell)
         SellArrowBuffer[i] = high[i] + offset;

      if(buyCond && AllowBuy)
         BuyArrowBuffer[i] = low[i] - offset;
     }

   // --- Fire alerts / draw exit zone only once, on the candle that just CLOSED
   datetime curFormingBarTime = time[rates_total-1];
   if(curFormingBarTime != g_lastBarTime)
     {
      g_lastBarTime = curFormingBarTime;
      int closedIdx = rates_total-2;
      if(closedIdx >= InpAOLookback)
        {
         if(SellArrowBuffer[closedIdx] != EMPTY_VALUE)
            HandleConfirmedSignal(time[closedIdx], "SELL", closedIdx);

         if(BuyArrowBuffer[closedIdx] != EMPTY_VALUE)
            HandleConfirmedSignal(time[closedIdx], "BUY", closedIdx);
        }
     }

   if(InpShowStochPanel)
      UpdatePanel(rates_total-1, lwma, ao, stochK, stochD, close);

   return(rates_total);
  }

//+------------------------------------------------------------------+
//| Handle a signal confirmed on a fully closed candle               |
//+------------------------------------------------------------------+
void HandleConfirmedSignal(datetime barTime, string dir, int idx)
  {
   string msg = StringFormat("%s %s Signal | AO+LWMA M1 Scalping | %s",
                              _Symbol, dir, TimeToString(barTime, TIME_DATE|TIME_MINUTES));

   if(InpEnableAlerts) Alert(msg);
   if(InpEnablePush)   SendNotification(msg);

   Print(msg);

   if(InpShowExitZone)
      DrawExitZone(barTime, dir);
  }

//+------------------------------------------------------------------+
//| Draw a vertical marker N candles ahead = the time-based exit     |
//+------------------------------------------------------------------+
void DrawExitZone(datetime barTime, string dir)
  {
   datetime exitTime = barTime + PeriodSeconds()*InpExitCandles;

   string name = ZONE_PREFIX + IntegerToString((long)barTime);

   if(ObjectFind(0,name)>=0)
      ObjectDelete(0,name);

   ObjectCreate(0, name, OBJ_VLINE, 0, exitTime, 0);
   ObjectSetInteger(0, name, OBJPROP_COLOR, (dir=="SELL") ? clrOrange : clrDodgerBlue);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_BACK,  true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetString (0, name, OBJPROP_TOOLTIP, dir+" exit zone - "+IntegerToString(InpExitCandles)+" candles");
  }

//+------------------------------------------------------------------+
//| Create the info panel objects (once)                             |
//+------------------------------------------------------------------+
void CreatePanel()
  {
   CreateLabel(PANEL_PREFIX+"bg",    10, 20, "", clrWhite, 1, CORNER_LEFT_UPPER);
   CreateLabel(PANEL_PREFIX+"title", 12, 18, "AO + LWMA M1 Scalping", clrYellow, 9, CORNER_LEFT_UPPER);
   CreateLabel(PANEL_PREFIX+"ao",    12, 34, "AO Norm: --", clrWhite, 8, CORNER_LEFT_UPPER);
   CreateLabel(PANEL_PREFIX+"stoch", 12, 48, "Stoch %K/%D: -- / --", clrSilver, 8, CORNER_LEFT_UPPER);
   CreateLabel(PANEL_PREFIX+"lwma",  12, 62, "LWMA(10): --", clrAqua, 8, CORNER_LEFT_UPPER);
   CreateLabel(PANEL_PREFIX+"dir",   12, 76, "Direction: --", clrWhite, 8, CORNER_LEFT_UPPER);
  }

void CreateLabel(string name, int x, int y, string text, color clr, int size, ENUM_BASE_CORNER corner)
  {
   if(ObjectFind(0,name)<0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);

   ObjectSetInteger(0, name, OBJPROP_CORNER, corner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
   ObjectSetString (0, name, OBJPROP_FONT, "Consolas");
   ObjectSetString (0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
//| Refresh the live info panel                                      |
//+------------------------------------------------------------------+
void UpdatePanel(int idx, const double &lwma[], const double &ao[],
                  const double &stochK[], const double &stochD[], const double &close[])
  {
   double hi=ao[idx], lo=ao[idx];
   int winStart = idx-InpAOLookback+1; if(winStart<0) winStart=0;
   for(int k=winStart;k<=idx;k++) { if(ao[k]>hi) hi=ao[k]; if(ao[k]<lo) lo=ao[k]; }
   double range = hi-lo;
   double normAO = (range>0.0) ? (ao[idx]-lo)/range*100.0 : 50.0;

   string aoState = (normAO>=InpUpperLevel) ? " [OVERBOUGHT]" : (normAO<=InpLowerLevel ? " [OVERSOLD]" : "");
   ObjectSetString(0, PANEL_PREFIX+"ao", OBJPROP_TEXT,
                    StringFormat("AO Norm: %.1f%s", normAO, aoState));

   ObjectSetString(0, PANEL_PREFIX+"stoch", OBJPROP_TEXT,
                    StringFormat("Stoch %%K/%%D: %.1f / %.1f  (ref only)", stochK[idx], stochD[idx]));

   string trend = (close[idx] < lwma[idx]) ? "below" : "above";
   ObjectSetString(0, PANEL_PREFIX+"lwma", OBJPROP_TEXT,
                    StringFormat("LWMA(10): %s   (close %s LWMA)", DoubleToString(lwma[idx], _Digits), trend));

   string dirTxt = AllowSell && AllowBuy ? "BOTH" : (AllowSell ? "SELL only" : (AllowBuy ? "BUY only" : "NONE"));
   ObjectSetString(0, PANEL_PREFIX+"dir", OBJPROP_TEXT,
                    StringFormat("Direction: %s   |   Exit: %d candles", dirTxt, InpExitCandles));
  }
//+------------------------------------------------------------------+