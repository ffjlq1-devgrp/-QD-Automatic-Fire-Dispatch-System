// QD Automatic Fire System — Station Alarm Box v2.0
// Independent Cloudflare connection; multiple boxes in same or different regions.
string COMMUNITY="";
string CONFIG_CARD="Station_CONFIG";
string URL="";
string SECRET="";
string NAME="Station";
string INV_JSON="{}";
string RESPONSE_REGIONS="ALL";
list INV=[]; // [type, count,...]
list SOUNDS=[]; // [sound name, UUID, duration, ...]
list SEQUENCES=[]; // [incident type, comma-separated names,...]
integer REMINDER_SECONDS=30;
integer POLL_SECONDS=30;
integer GROUP_ACCESS=FALSE;
integer configLine;
key configQuery;
key httpId;
string httpAction="";
integer cursor=0;
integer lastRegister=0;
integer nextPoll=0;
integer ready=FALSE;
integer active=FALSE;
integer acked=FALSE;
integer incidentStart=0;
string incidentId="";
string incidentType="";
string nodeSound="";
float nodeDuration=0.0;
integer lastReminder=0;
list queue=[]; // [uuid, duration,...]
integer playAt=0;
integer dialogChannel;
integer dialogListen;
integer requestPending=FALSE;

integer authorized(key who){return who==llGetOwner() || (GROUP_ACCESS && llSameGroup(who));}
string j(string json,string keyName){return llJsonGetValue(json,[keyName]);}
string getSequence(string type){integer i;for(i=0;i<llGetListLength(SEQUENCES);i+=2)if(llList2String(SEQUENCES,i)==type)return llList2String(SEQUENCES,i+1);return "ALERT,NODE,PLEASE_RESPOND";}
integer soundIndex(string name){integer i;for(i=0;i<llGetListLength(SOUNDS);i+=3)if(llList2String(SOUNDS,i)==name)return i;return -1;}
voidDummy(){} // no-op placeholder; LSL functions have no void keyword
playNext(){
    if(llGetListLength(queue)<2)return;
    string id=llList2String(queue,0);float seconds=llList2Float(queue,1);
    queue=llDeleteSubList(queue,0,1);
    if(id!="" && (key)id!=NULL_KEY)llPlaySound(id,1.0);
    if(seconds<=0.0)seconds=1.0;
    playAt=llGetUnixTime()+(integer)llCeil(seconds);
}
startSequence(string type){
    list names=llCSV2List(getSequence(type));
    integer i;queue=[];
    for(i=0;i<llGetListLength(names);++i){
        string n=llToUpper(llStringTrim(llList2String(names,i),STRING_TRIM));
        if(n=="NODE"){
            if(nodeSound!="" && (key)nodeSound!=NULL_KEY && nodeDuration>0)queue += [nodeSound,nodeDuration];
        }else{
            integer index=soundIndex(n);
            if(index>=0)queue += [llList2String(SOUNDS,index+1),llList2Float(SOUNDS,index+2)];
        }
    }
    playAt=0;
    playNext();
}
http(string action,string path,string body){
    if(requestPending || URL=="" || SECRET=="")return;
    requestPending=TRUE;httpAction=action;
    list headers=[HTTP_CUSTOM_HEADER,"X-Network-Key",SECRET,HTTP_CUSTOM_HEADER,"X-Community-Name",COMMUNITY];
    if(body=="")httpId=llHTTPRequest(URL+path,[HTTP_METHOD,"GET"]+headers,"");
    else httpId=llHTTPRequest(URL+path,[HTTP_METHOD,"POST",HTTP_MIMETYPE,"application/json"]+headers,body);
}
registerStation(){
    vector pos=llGetRegionCorner()+llGetPos();
    string payload=llList2Json(JSON_OBJECT,["id",(string)llGetKey(),"name",NAME,"region",llGetRegionName(),"x",pos.x,"y",pos.y,"inventory",INV_JSON,"response_regions",RESPONSE_REGIONS]);
    http("register","/station/register",payload);
}
processEvent(string action,string data){
    string id=j(data,"incident_id");
    if(action=="DISPATCH"){
        if(active && incidentId==id)return;
        if(active && incidentId!=id)return; // one audible incident per box in v1
        incidentId=id;incidentType=j(data,"type");nodeSound=j(data,"address_sound");nodeDuration=(float)j(data,"address_duration");
        incidentStart=(integer)j(data,"created_at");lastReminder=incidentStart;
        active=TRUE;acked=FALSE;
        llSetText("DISPATCH: "+incidentType,<1.0,0.3,0.2>,1.0);
        startSequence(incidentType);
        llOwnerSay("Dispatch: "+incidentType+" at "+j(data,"node_name")+" ("+j(data,"node_region")+")");
    }else if((action=="ACKED"||action=="CANCEL") && id==incidentId){
        active=FALSE;acked=FALSE;queue=[];llSetText("",ZERO_VECTOR,0.0);
        if(action=="CANCEL")llOwnerSay("Incident cancelled: "+incidentId);
        else llOwnerSay("Incident acknowledged by station "+j(data,"station_id"));
        incidentId="";
    }
}
showMenu(key who){
    if(dialogListen)llListenRemove(dialogListen);
    dialogChannel=-(200000+(integer)llFrand(700000));
    dialogListen=llListen(dialogChannel,"",who,"");
    if(active)llDialog(who,"Incident: "+incidentType,["RESPONDING","Details"],dialogChannel);
    else llDialog(who,"Station: "+NAME,["Status"],dialogChannel);
}
default {
 state_entry(){
    INV=[];SOUNDS=[];SEQUENCES=[];cursor=0;active=FALSE;ready=FALSE;requestPending=FALSE;
    if(llGetInventoryType(CONFIG_CARD)!=INVENTORY_NOTECARD){llOwnerSay("Missing "+CONFIG_CARD);return;}
    configLine=0;configQuery=llGetNotecardLine(CONFIG_CARD,configLine);llSetTimerEvent(1.0);
 }
 changed(integer c){if(c&(CHANGED_INVENTORY|CHANGED_OWNER))llResetScript();}
 on_rez(integer p){llResetScript();}
 dataserver(key id,string data){
    if(id!=configQuery)return;
    if(data==EOF){
        INV_JSON=llList2Json(JSON_OBJECT,INV);ready=TRUE;nextPoll=0;
        llOwnerSay("Station ready: "+NAME+". Apparatus: "+INV_JSON);return;
    }
    data=llStringTrim(data,STRING_TRIM);
    if(data!="" && llGetSubString(data,0,0)!="#"){
        integer p=llSubStringIndex(data,"=");
        if(p>0){
            string k=llToUpper(llStringTrim(llGetSubString(data,0,p-1),STRING_TRIM));
            string v=llStringTrim(llGetSubString(data,p+1,-1),STRING_TRIM);
            if(k=="COMMUNITY_NAME")COMMUNITY=v;
    else if(k=="SERVER_URL")URL=v;
            else if(k=="NETWORK_KEY")SECRET=v;
            else if(k=="STATION_NAME")NAME=v;
            else if(k=="RESPONSE_REGIONS")RESPONSE_REGIONS=v;
            else if(k=="GROUP_ACCESS")GROUP_ACCESS=(integer)v;
            else if(k=="REMINDER_SECONDS")REMINDER_SECONDS=(integer)v;
            else if(k=="POLL_SECONDS")POLL_SECONDS=(integer)v;
            else if(llSubStringIndex(k,"APPARATUS.")==0)INV += [llGetSubString(k,10,-1),(integer)v];
            else if(llSubStringIndex(k,"SOUND.")==0){
                list a=llParseString2List(v,["|"],[]);
                if(llGetListLength(a)==2)SOUNDS += [llGetSubString(k,6,-1),llList2String(a,0),(float)llList2String(a,1)];
            }else if(llSubStringIndex(k,"SEQ.")==0)SEQUENCES += [llGetSubString(k,4,-1),v];
        }
    }
    configQuery=llGetNotecardLine(CONFIG_CARD,++configLine);
 }
 timer(){
    if(!ready)return;
    integer t=llGetUnixTime();
    if(llGetListLength(queue)>=2 && t>=playAt)playNext();
    if(active && !acked && lastReminder==incidentStart && t>=incidentStart+REMINDER_SECONDS && t<incidentStart+300){
        lastReminder=t;
        integer index=soundIndex("REMINDER");
        if(index>=0)llPlaySound(llList2String(SOUNDS,index+1),1.0);
    }
    if(active && t>=incidentStart+305){active=FALSE;queue=[];incidentId="";llSetText("",ZERO_VECTOR,0.0);}
    if(requestPending)return;
    if(t-lastRegister>=120){registerStation();return;}
    if(t>=nextPoll){
        if(active)nextPoll=t+10;
        else nextPoll=t+POLL_SECONDS;
        http("poll","/poll?kind=STATION&id="+(string)llGetKey()+"&since="+(string)cursor,"");
    }
 }
 touch_start(integer count){key who=llDetectedKey(0);if(authorized(who))showMenu(who);}
 listen(integer channel,string name,key who,string msg){
    if(channel!=dialogChannel || !authorized(who))return;
    if(msg=="RESPONDING" && active && !acked && !requestPending){
        string payload=llList2Json(JSON_OBJECT,["incident_id",incidentId,"station_id",(string)llGetKey()]);
        http("ack","/incident/ack",payload);
    }else if(msg=="Details")llRegionSayTo(who,0,"Incident "+incidentId+": "+incidentType);
    else if(msg=="Status")llRegionSayTo(who,0,"Station "+NAME+" online. Inventory: "+INV_JSON);
 }
 http_response(key id,integer status,list meta,string body){
    if(id!=httpId)return;
    requestPending=FALSE;
    if(status<200||status>=300||j(body,"ok")!="true"){
        if(httpAction=="ack")llOwnerSay("Acknowledgement rejected: "+llGetSubString(body,0,180));
        else if(status==401)llOwnerSay("Invalid Cloudflare network key.");
        return;
    }
    if(httpAction=="register")lastRegister=llGetUnixTime();
    else if(httpAction=="ack"){acked=TRUE;llOwnerSay("Acknowledgement accepted.");}
    else if(httpAction=="poll"){
        string events=j(body,"events");list a=llJson2List(events);
        integer i;
        for(i=0;i<llGetListLength(a);++i){
            string e=llList2String(a,i);
            processEvent(j(e,"action"),j(e,"data"));
            cursor=(integer)j(e,"id");
        }
    }
 }
}
