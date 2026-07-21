
#property copyright "2026"
#property version   "1.00"
#property description "M5/M15 confluence support and resistance signal indicator"
#property indicator_chart_window
#property indicator_plots 0

enum ENUM_TOLERANCE_MODE { TOLERANCE_ATR=0, TOLERANCE_POINTS=1 };

input group "General"
input ENUM_TIMEFRAMES InpEntryTF=PERIOD_M5;
input ENUM_TIMEFRAMES InpTrendTF=PERIOD_M15;
input int InpLookback=50;
input int InpMaxZones=8;
input int InpMinTouches=2;
input int InpMinBarsBetweenTouches=3;
input bool InpAlerts=true;
input bool InpPushNotifications=false;

input group "Trend Filter"
input int InpFastEMA=20;
input int InpSlowSMA=50;
input int InpSlopeBars=3;
input double InpFlatSlopeATR=0.02;

input group "Zone Detection"
input ENUM_TOLERANCE_MODE InpToleranceMode=TOLERANCE_ATR;
input double InpATRZoneFactor=0.15;
input int InpFixedTolerancePoints=30;
input int InpMinTolerancePoints=10;
input int InpMaxTolerancePoints=500;
input bool InpUsePreviousDay=true;
input bool InpUseEntryEMA=true;
input bool InpUseTrendEMA=true;
input bool InpUseVolumeNodes=true;
input int InpVolumeBins=24;
input double InpHVNFactor=1.20;
input int InpRequiredConfluence=3;

input group "Rejection Candles"
input double InpMinWickBodyRatio=1.5;
input double InpMaxOppositeWickRatio=0.50;
input double InpMaxBodyATR=1.20;
input bool InpAllowPinBars=true;
input bool InpAllowEngulfing=true;

input group "Risk Levels"
input int InpATRPeriod=14;
input double InpSL_ATR_Buffer=1.50;
input double InpMinimumRR=2.0;
input double InpTP2_RR=3.0;

input group "Breakout Validation"
input double InpBreakVolumeFactor=1.50;

input group "Display"
input bool InpApplyChartTheme=true;
input bool InpDrawZones=true;
input bool InpDrawMovingAverages=true;
input bool InpDrawPreviousDay=true;
input color InpSupportColor=clrSeaGreen;
input color InpResistanceColor=clrTomato;
input color InpInvalidColor=clrDimGray;
input int InpZoneExtendBars=60;

struct SZone
{
   double center,low,high;
   bool support,valid,hvn;
   int touches,score;
   datetime born;
};

SZone g_zones[];
int g_emaEntry=INVALID_HANDLE,g_emaTrend=INVALID_HANDLE,g_smaTrend=INVALID_HANDLE,g_atr=INVALID_HANDLE;
datetime g_lastBar=0,g_lastAlertBar=0;
string g_prefix;
double g_atrValue=0,g_pdHigh=0,g_pdLow=0,g_emaEntryValue=0,g_emaTrendValue=0,g_smaTrendValue=0;
int g_trend=0;

double TickNormalize(double p)
{
   double tick=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tick<=0) tick=_Point;
   return NormalizeDouble(MathRound(p/tick)*tick,_Digits);
}

bool ReadOne(const int handle,const int shift,double &value)
{
   double a[1];
   if(handle==INVALID_HANDLE || CopyBuffer(handle,0,shift,1,a)!=1) return false;
   value=a[0]; return MathIsValidNumber(value);
}

double ZoneTolerance()
{
   double t=(InpToleranceMode==TOLERANCE_POINTS ? InpFixedTolerancePoints*_Point : g_atrValue*InpATRZoneFactor);
   return MathMax(InpMinTolerancePoints*_Point,MathMin(InpMaxTolerancePoints*_Point,t));
}

void DeleteObjects()
{
   ObjectsDeleteAll(0,g_prefix);
}

void ApplyTheme()
{
   if(!InpApplyChartTheme) return;
   ChartSetInteger(0,CHART_COLOR_BACKGROUND,clrDarkSlateGray);
   ChartSetInteger(0,CHART_COLOR_FOREGROUND,clrWhiteSmoke);
   ChartSetInteger(0,CHART_COLOR_GRID,clrNONE);
   ChartSetInteger(0,CHART_COLOR_CANDLE_BULL,clrLimeGreen);
   ChartSetInteger(0,CHART_COLOR_CANDLE_BEAR,clrRed);
   ChartSetInteger(0,CHART_COLOR_CHART_UP,clrLimeGreen);
   ChartSetInteger(0,CHART_COLOR_CHART_DOWN,clrRed);
   ChartSetInteger(0,CHART_SHOW_GRID,false);
   ChartSetInteger(0,CHART_SHOW_VOLUMES,CHART_VOLUME_HIDE);
}

int OnInit()
{
   if(InpLookback<20 || InpMaxZones<1 || InpATRPeriod<2) return INIT_PARAMETERS_INCORRECT;
   g_prefix="CSR_"+IntegerToString((int)ChartID())+"_";
   g_emaEntry=iMA(_Symbol,InpEntryTF,InpFastEMA,0,MODE_EMA,PRICE_CLOSE);
   g_emaTrend=iMA(_Symbol,InpTrendTF,InpFastEMA,0,MODE_EMA,PRICE_CLOSE);
   g_smaTrend=iMA(_Symbol,InpTrendTF,InpSlowSMA,0,MODE_SMA,PRICE_CLOSE);
   g_atr=iATR(_Symbol,InpEntryTF,InpATRPeriod);
   if(g_emaEntry==INVALID_HANDLE || g_emaTrend==INVALID_HANDLE || g_smaTrend==INVALID_HANDLE || g_atr==INVALID_HANDLE)
      return INIT_FAILED;
   IndicatorSetString(INDICATOR_SHORTNAME,"M5/M15 Confluence S/R");
   ApplyTheme();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   DeleteObjects();
   if(g_emaEntry!=INVALID_HANDLE) IndicatorRelease(g_emaEntry);
   if(g_emaTrend!=INVALID_HANDLE) IndicatorRelease(g_emaTrend);
   if(g_smaTrend!=INVALID_HANDLE) IndicatorRelease(g_smaTrend);
   if(g_atr!=INVALID_HANDLE) IndicatorRelease(g_atr);
   Comment("");
}

double AvgVolume(MqlRates &r[],int from,int count)
{
   double sum=0; int n=0;
   int total=ArraySize(r);
   for(int i=from;i<from+count && i<total;i++){ sum+=(double)r[i].tick_volume; n++; }
   return n>0?sum/n:0;
}

bool LoadContext()
{
   if(!ReadOne(g_atr,1,g_atrValue) || g_atrValue<=0) return false;
   if(!ReadOne(g_emaEntry,1,g_emaEntryValue) || !ReadOne(g_emaTrend,1,g_emaTrendValue) || !ReadOne(g_smaTrend,1,g_smaTrendValue)) return false;
   double emaPast,smaPast,atrTrend;
   if(!ReadOne(g_emaTrend,1+InpSlopeBars,emaPast) || !ReadOne(g_smaTrend,1+InpSlopeBars,smaPast)) return false;
   int atrTrendHandle=iATR(_Symbol,InpTrendTF,InpATRPeriod);
   if(atrTrendHandle==INVALID_HANDLE) return false;
   bool ok=ReadOne(atrTrendHandle,1,atrTrend); IndicatorRelease(atrTrendHandle);
   if(!ok || atrTrend<=0) return false;
   double close1=iClose(_Symbol,InpTrendTF,1);
   double minSlope=atrTrend*InpFlatSlopeATR;
   bool rising=(g_emaTrend-emaPast>minSlope && g_smaTrendValue-smaPast>minSlope);
   bool falling=(emaPast-g_emaTrend>minSlope && smaPast-g_smaTrendValue>minSlope);
   g_trend=(close1>g_emaTrend && g_emaTrend>g_smaTrendValue && rising)?1:
           (close1<g_emaTrend && g_emaTrend<g_smaTrendValue && falling)?-1:0;
   g_pdHigh=iHigh(_Symbol,PERIOD_D1,1); g_pdLow=iLow(_Symbol,PERIOD_D1,1);
   return true;
}

void AddCandidate(double price,bool support,datetime born,double tol)
{
   int n=ArraySize(g_zones);
   for(int i=0;i<n;i++)
   {
      if(g_zones[i].support==support && MathAbs(g_zones[i].center-price)<=tol)
      {
         g_zones[i].center=(g_zones[i].center*g_zones[i].touches+price)/(g_zones[i].touches+1);
         g_zones[i].touches++; g_zones[i].born=MathMax(g_zones[i].born,born); return;
      }
   }
   ArrayResize(g_zones,n+1);
   g_zones[n].center=price; g_zones[n].low=price-tol; g_zones[n].high=price+tol;
   g_zones[n].support=support; g_zones[n].valid=true; g_zones[n].hvn=false;
   g_zones[n].touches=1; g_zones[n].score=1; g_zones[n].born=born;
}

void BuildZones(MqlRates &r[])
{
   ArrayResize(g_zones,0);
   double tol=ZoneTolerance(); int total=ArraySize(r);
   for(int i=2;i<total-2;i++)
   {
      bool swingLow=(r[i].low<=r[i-1].low && r[i].low<r[i+1].low);
      bool swingHigh=(r[i].high>=r[i-1].high && r[i].high>r[i+1].high);
      if(swingLow) AddCandidate(r[i].low,true,r[i].time,tol);
      if(swingHigh) AddCandidate(r[i].high,false,r[i].time,tol);
   }
   // Recount separated reactions rather than adjacent touches.
   for(int z=0;z<ArraySize(g_zones);z++)
   {
      int touches=0,last=-10000;
      for(int i=1;i<total;i++)
      {
         bool hit=g_zones[z].support ? (r[i].low<=g_zones[z].center+tol && r[i].low>=g_zones[z].center-tol)
                                      : (r[i].high>=g_zones[z].center-tol && r[i].high<=g_zones[z].center+tol);
         if(hit && i-last>=InpMinBarsBetweenTouches){ touches++; last=i; }
      }
      g_zones[z].touches=touches; g_zones[z].low=g_zones[z].center-tol; g_zones[z].high=g_zones[z].center+tol;
      g_zones[z].score=1+(touches>=InpMinTouches?1:0);
   }
   // Lightweight tick-volume profile.
   if(InpUseVolumeNodes && InpVolumeBins>=5 && total>5)
   {
      double lo=r[1].low,hi=r[1].high;
      for(int i=2;i<total;i++){ lo=MathMin(lo,r[i].low); hi=MathMax(hi,r[i].high); }
      if(hi>lo)
      {
         double bins[]; ArrayResize(bins,InpVolumeBins); ArrayInitialize(bins,0.0);
         for(int i=1;i<total;i++)
         {
            double typical=(r[i].high+r[i].low+r[i].close)/3.0;
            int b=(int)MathFloor((typical-lo)/(hi-lo)*InpVolumeBins); b=(int)MathMax(0,MathMin(InpVolumeBins-1,b));
            bins[b]+=(double)r[i].tick_volume;
         }
         double avg=0; for(int b=0;b<InpVolumeBins;b++) avg+=bins[b]; avg/=InpVolumeBins;
         for(int z=0;z<ArraySize(g_zones);z++)
         {
            int b=(int)MathFloor((g_zones[z].center-lo)/(hi-lo)*InpVolumeBins); b=(int)MathMax(0,MathMin(InpVolumeBins-1,b));
            g_zones[z].hvn=(avg>0 && bins[b]>=avg*InpHVNFactor); if(g_zones[z].hvn) g_zones[z].score++;
         }
      }
   }
   for(int z=0;z<ArraySize(g_zones);z++)
   {
      if(InpUseEntryEMA && MathAbs(g_zones[z].center-g_emaEntryValue)<=tol) g_zones[z].score++;
      if(InpUseTrendEMA && MathAbs(g_zones[z].center-g_emaTrendValue)<=tol) g_zones[z].score++;
      if(InpUsePreviousDay && (MathAbs(g_zones[z].center-g_pdHigh)<=tol || MathAbs(g_zones[z].center-g_pdLow)<=tol)) g_zones[z].score++;
      // A decisive high-volume close invalidates the zone.
      double av=AvgVolume(r,2,MathMin(20,total-2));
      if(g_zones[z].support && r[1].close<g_zones[z].low && (av<=0 || r[1].tick_volume>=av*InpBreakVolumeFactor)) g_zones[z].valid=false;
      if(!g_zones[z].support && r[1].close>g_zones[z].high && (av<=0 || r[1].tick_volume>=av*InpBreakVolumeFactor)) g_zones[z].valid=false;
   }
}

bool BullishPattern(MqlRates &r[],int i)
{
   double body=MathAbs(r[i].close-r[i].open),range=r[i].high-r[i].low;
   if(range<=0 || body>g_atrValue*InpMaxBodyATR) return false;
   double lower=MathMin(r[i].open,r[i].close)-r[i].low,upper=r[i].high-MathMax(r[i].open,r[i].close);
   bool pin=InpAllowPinBars && r[i].close>r[i].open && lower>=MathMax(body,_Point)*InpMinWickBodyRatio && upper<=lower*InpMaxOppositeWickRatio;
   double prevBody=MathAbs(r[i+1].close-r[i+1].open);
   bool engulf=InpAllowEngulfing && r[i].close>r[i].open && r[i+1].close<r[i+1].open && body>prevBody && r[i].open<=r[i+1].close && r[i].close>=r[i+1].open;
   return pin||engulf;
}

bool BearishPattern(MqlRates &r[],int i)
{
   double body=MathAbs(r[i].close-r[i].open),range=r[i].high-r[i].low;
   if(range<=0 || body>g_atrValue*InpMaxBodyATR) return false;
   double lower=MathMin(r[i].open,r[i].close)-r[i].low,upper=r[i].high-MathMax(r[i].open,r[i].close);
   bool pin=InpAllowPinBars && r[i].close<r[i].open && upper>=MathMax(body,_Point)*InpMinWickBodyRatio && lower<=upper*InpMaxOppositeWickRatio;
   double prevBody=MathAbs(r[i+1].close-r[i+1].open);
   bool engulf=InpAllowEngulfing && r[i].close<r[i].open && r[i+1].close>r[i+1].open && body>prevBody && r[i].open>=r[i+1].close && r[i].close<=r[i+1].open;
   return pin||engulf;
}

void Rect(string name,datetime t1,datetime t2,double top,double bottom,color c)
{
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_RECTANGLE,0,t1,top,t2,bottom);
   else { ObjectMove(0,name,0,t1,top); ObjectMove(0,name,1,t2,bottom); }
   ObjectSetInteger(0,name,OBJPROP_COLOR,c); ObjectSetInteger(0,name,OBJPROP_FILL,true);
   ObjectSetInteger(0,name,OBJPROP_BACK,true); ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
}

void HLine(string name,double price,color c,ENUM_LINE_STYLE style)
{
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_HLINE,0,0,price);
   ObjectSetDouble(0,name,OBJPROP_PRICE,price); ObjectSetInteger(0,name,OBJPROP_COLOR,c);
   ObjectSetInteger(0,name,OBJPROP_STYLE,style); ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
}

void Arrow(string name,datetime time,double price,bool buy)
{
   if(ObjectFind(0,name)>=0) return;
   ObjectCreate(0,name,OBJ_ARROW,0,time,price); ObjectSetInteger(0,name,OBJPROP_ARROWCODE,buy?233:234);
   ObjectSetInteger(0,name,OBJPROP_COLOR,buy?clrLime:clrRed); ObjectSetInteger(0,name,OBJPROP_WIDTH,2);
}

void DrawMA(string name,int handle,color c)
{
   if(!InpDrawMovingAverages) return;
   double v; if(ReadOne(handle,1,v)) HLine(g_prefix+name,v,c,STYLE_DOT);
}

void EvaluateAndDraw(MqlRates &r[])
{
   DeleteObjects();
   datetime future=r[0].time+(datetime)(PeriodSeconds(InpEntryTF)*InpZoneExtendBars);
   int drawn=0;
   for(int z=0;z<ArraySize(g_zones) && drawn<InpMaxZones;z++)
   {
      if(g_zones[z].touches<InpMinTouches) continue;
      color c=!g_zones[z].valid?InpInvalidColor:(g_zones[z].support?InpSupportColor:InpResistanceColor);
      if(InpDrawZones) Rect(g_prefix+"ZONE_"+IntegerToString(z),r[ArraySize(r)-1].time,future,g_zones[z].high,g_zones[z].low,c);
      drawn++;
   }
   if(InpDrawPreviousDay && InpUsePreviousDay){ HLine(g_prefix+"PDH",g_pdHigh,clrGold,STYLE_DASH); HLine(g_prefix+"PDL",g_pdLow,clrGold,STYLE_DASH); }
   DrawMA("EMA_ENTRY",g_emaEntry,clrAqua); DrawMA("EMA_TREND",g_emaTrend,clrDeepSkyBlue); DrawMA("SMA_TREND",g_smaTrend,clrOrange);

   string decision="WAIT",reason="No confirmed rejection at a qualified zone";
   double entry=r[1].close,sl=0,tp1=0,tp2=0; int best=-1;
   for(int z=0;z<ArraySize(g_zones);z++)
   {
      if(!g_zones[z].valid || g_zones[z].touches<InpMinTouches || g_zones[z].score<InpRequiredConfluence) continue;
      bool touched=(r[1].low<=g_zones[z].high && r[1].high>=g_zones[z].low);
      if(!touched) continue;
      if(g_trend==1 && g_zones[z].support && BullishPattern(r,1) && r[1].close>=g_zones[z].low){ best=z; decision="BUY"; break; }
      if(g_trend==-1 && !g_zones[z].support && BearishPattern(r,1) && r[1].close<=g_zones[z].high){ best=z; decision="SELL"; break; }
   }
   if(g_trend==0) reason="M15 trend is neutral or moving averages are flat";
   else if(best>=0)
   {
      bool buy=(decision=="BUY");
      sl=buy ? MathMin(g_zones[best].low,r[1].low)-g_atrValue*InpSL_ATR_Buffer
             : MathMax(g_zones[best].high,r[1].high)+g_atrValue*InpSL_ATR_Buffer;
      sl=TickNormalize(sl); double risk=MathAbs(entry-sl);
      tp1=TickNormalize(buy?entry+risk*InpMinimumRR:entry-risk*InpMinimumRR);
      tp2=TickNormalize(buy?entry+risk*InpTP2_RR:entry-risk*InpTP2_RR);
      reason="Confirmed rejection + M15 trend + zone confluence";
      Arrow(g_prefix+"SIG_"+IntegerToString((int)r[1].time),r[1].time,buy?r[1].low-g_atrValue*.2:r[1].high+g_atrValue*.2,buy);
      HLine(g_prefix+"SL",sl,clrOrangeRed,STYLE_SOLID); HLine(g_prefix+"TP1",tp1,clrLime,STYLE_SOLID); HLine(g_prefix+"TP2",tp2,clrGreenYellow,STYLE_DASH);
      if(InpAlerts && g_lastAlertBar!=r[1].time)
      {
         string msg=_Symbol+" "+EnumToString(InpEntryTF)+" "+decision+" | Entry "+DoubleToString(entry,_Digits)+" SL "+DoubleToString(sl,_Digits)+" TP1 "+DoubleToString(tp1,_Digits);
         Alert(msg); if(InpPushNotifications) SendNotification(msg); g_lastAlertBar=r[1].time;
      }
   }
   string trend=(g_trend>0?"BULLISH":g_trend<0?"BEARISH":"NEUTRAL");
   string panel="M5/M15 CONFLUENCE S/R\nTrend: "+trend+"\nDecision: "+decision+"\nReason: "+reason+
                "\nATR: "+DoubleToString(g_atrValue,_Digits)+"\nZones found: "+IntegerToString(ArraySize(g_zones));
   if(best>=0) panel+="\nScore: "+IntegerToString(g_zones[best].score)+" | Touches: "+IntegerToString(g_zones[best].touches)+
                         "\nEntry: "+DoubleToString(entry,_Digits)+"\nSL: "+DoubleToString(sl,_Digits)+
                         "\nTP1: "+DoubleToString(tp1,_Digits)+"\nTP2: "+DoubleToString(tp2,_Digits);
   Comment(panel); ChartRedraw();
}

int OnCalculate(const int rates_total,const int prev_calculated,const datetime &time[],const double &open[],const double &high[],const double &low[],const double &close[],const long &tick_volume[],const long &volume[],const int &spread[])
{
   datetime bar=iTime(_Symbol,InpEntryTF,0);
   if(bar<=0 || bar==g_lastBar) return rates_total;
   g_lastBar=bar;
   MqlRates r[]; ArraySetAsSeries(r,true);
   int need=MathMax(InpLookback,InpSlowSMA+InpSlopeBars)+5;
   int copied=CopyRates(_Symbol,InpEntryTF,0,need,r);
   if(copied<MathMax(20,InpATRPeriod+5)) return rates_total;
   if(!LoadContext()) return rates_total;
   BuildZones(r); EvaluateAndDraw(r);
   return rates_total;
}
