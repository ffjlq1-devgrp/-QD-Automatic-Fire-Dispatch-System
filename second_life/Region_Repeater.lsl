// QD Automatic Fire System — Region Repeater v2.0
// Automatically registers local Fire Nodes and relays Cloudflare spawn commands.
// No peer UUIDs. Not needed in the Master or Station regions.
string COMMUNITY="";
string CONFIG_CARD="Repeater_CONFIG";
string URL="";
string SECRET="";
integer CHANNEL=-7712401;
integer POLL_SECONDS=20;
integer configLine;
key configQuery;
integer ready=FALSE;
string currentRegion="";
integer cursor=0;
integer nextPoll=0;
integer lastBeacon=0;
integer listenHandle;
key httpId;
string httpAction="";
integer busy=FALSE;
list nodeQueue=[];

string lastPayload="";
list lastBatch=[];

string j(string data,string k){return llJsonGetValue(data,[k]);}
http(string action,string path,string body){
 if(busy||URL==""||SECRET=="")return;
 busy=TRUE;httpAction=action;
 list opts=[HTTP_CUSTOM_HEADER,"X-Network-Key",SECRET,HTTP_CUSTOM_HEADER,"X-Community-Name",COMMUNITY];
 if(body=="")httpId=llHTTPRequest(URL+path,[HTTP_METHOD,"GET"]+opts,"");
 else httpId=llHTTPRequest(URL+path,[HTTP_METHOD,"POST",HTTP_MIMETYPE,"application/json"]+opts,body);
}
default {
 state_entry(){
  ready=FALSE;busy=FALSE;cursor=0;nodeQueue=[];
  if(listenHandle)llListenRemove(listenHandle);
  listenHandle=llListen(CHANNEL,"",NULL_KEY,"");
  if(llGetInventoryType(CONFIG_CARD)!=INVENTORY_NOTECARD){llOwnerSay("Missing "+CONFIG_CARD);return;}
  configLine=0;configQuery=llGetNotecardLine(CONFIG_CARD,configLine);llSetTimerEvent(2.0);
 }
 on_rez(integer p){llResetScript();}
 changed(integer c){if(c&(CHANGED_REGION|CHANGED_OWNER|CHANGED_INVENTORY))llResetScript();}
 dataserver(key id,string data){
  if(id!=configQuery)return;
  if(data==EOF){ready=TRUE;currentRegion=llGetRegionName();llOwnerSay("Repeater online in "+currentRegion);return;}
  data=llStringTrim(data,STRING_TRIM);
  if(data!=""&&llGetSubString(data,0,0)!="#"){
   integer p=llSubStringIndex(data,"=");if(p>0){
    string k=llToUpper(llStringTrim(llGetSubString(data,0,p-1),STRING_TRIM));
    string v=llStringTrim(llGetSubString(data,p+1,-1),STRING_TRIM);
    if(k=="COMMUNITY_NAME")COMMUNITY=v;
    else if(k=="SERVER_URL")URL=v;
    else if(k=="NETWORK_KEY")SECRET=v;
    else if(k=="POLL_SECONDS")POLL_SECONDS=(integer)v;
   }
  }
  configQuery=llGetNotecardLine(CONFIG_CARD,++configLine);
 }
 listen(integer channel,string name,key id,string message){
  if(channel!=CHANNEL||!ready)return;
  list a=llParseStringKeepNulls(message,["|"],[]);
  if(llGetListLength(a)<3||llList2String(a,1)!=SECRET)return;
  string action=llList2String(a,0);
  string payload=llList2String(a,2);
  if(action=="NODE"){
   if(j(payload,"region")!=currentRegion)return;
   // Keep only latest pending registration for each node where possible.
   if(llGetListLength(nodeQueue)<100)nodeQueue += [payload];
  }
 }
 timer(){
  if(!ready)return;
  integer t=llGetUnixTime();
  if(llGetRegionName()!=currentRegion){llResetScript();return;}
  if(t-lastBeacon>=30){lastBeacon=t;llRegionSay(CHANNEL,"REPEATER|"+SECRET+"|"+currentRegion);}
  if(busy)return;
  if(llGetListLength(nodeQueue)){
   integer count=llGetListLength(nodeQueue);
   if(count>20)count=20;
   lastBatch=llList2List(nodeQueue,0,count-1);
   nodeQueue=llDeleteSubList(nodeQueue,0,count-1);
   lastPayload=llList2Json(JSON_OBJECT,["nodes",llList2Json(JSON_ARRAY,lastBatch)]);
   http("register","/nodes/batch",lastPayload);return;
  }
  if(t>=nextPoll){nextPoll=t+POLL_SECONDS;
   http("poll","/poll?kind=REGION&id="+llEscapeURL(currentRegion)+"&since="+(string)cursor,"");
  }
 }
 http_response(key id,integer status,list meta,string body){
  if(id!=httpId)return;
  busy=FALSE;
  if(status<200||status>=300||j(body,"ok")!="true"){
   if(httpAction=="register")nodeQueue=lastBatch+nodeQueue;
   if(status==401)llOwnerSay("Repeater network key rejected.");
   return;
  }
  if(httpAction=="poll"){
   list events=llJson2List(j(body,"events"));integer i;
   for(i=0;i<llGetListLength(events);++i){
    string e=llList2String(events,i);
    string action=j(e,"action");
    if(action=="SPAWN" || action=="LARGE_NEARBY")llRegionSay(CHANNEL,action+"|"+SECRET+"|"+j(e,"data"));
    cursor=(integer)j(e,"id");
   }
  }
 }
}
