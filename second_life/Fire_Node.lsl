// QD Automatic Fire System - Fire Node v3.0
// Building alarm: 25% false, 25% small, 25% medium, 25% large.
// Outcome chosen ONLY after station RESPONDING is accepted.
// A LARGE outcome triggers server-side 7m propagation to nearby nodes.
string COMMUNITY = "";
string CONFIG_CARD = "Node_CONFIG";
string URL = "";
string SECRET = "";
string NAME = "Fire Location";
string BUILDING = "RESIDENTIAL";
string SMALL = "Small Fire";
string MEDIUM = "Medium Fire";
string LARGE = "Large Fire";
string ADDRESS_SOUND = "";
float ADDRESS_DURATION = 0.0;
integer CHANNEL = -7712401;
integer configLine;
key configQuery;
integer ready = FALSE;
integer lastHello = 0;
integer lastRepeater = 0;
integer lastDirectRegister = 0;
integer nextPoll = 0;
integer cursor = 0;
key httpId;
string httpAction = "";
integer httpBusy = FALSE;
string handledIncident = "";
string pendingRez = "";
string pendingOutcome = "";
string pendingReport = "";
integer listenHandle;
string currentRegion = "";

string j(string json,string name) { return llJsonGetValue(json,[name]); }
string location() {
    vector p = llGetRegionCorner() + llGetPos();
    return llList2Json(JSON_OBJECT,["id",(string)llGetKey(),"name",NAME,
        "region",llGetRegionName(),"x",p.x,"y",p.y,
        "building_type",BUILDING,"address_sound",ADDRESS_SOUND,
        "address_duration",ADDRESS_DURATION]);
}
http(string action,string path,string body) {
    if(httpBusy || URL=="" || SECRET=="")return;
    httpBusy=TRUE;
    httpAction=action;
    list opts=[HTTP_CUSTOM_HEADER,"X-Network-Key",SECRET,
        HTTP_CUSTOM_HEADER,"X-Community-Name",COMMUNITY];
    if(body=="")httpId=llHTTPRequest(URL+path,[HTTP_METHOD,"GET"]+opts,"");
    else httpId=llHTTPRequest(URL+path,[HTTP_METHOD,"POST",HTTP_MIMETYPE,"application/json"]+opts,body);
}
reportOutcome() {
    if(pendingReport=="" || pendingOutcome=="" || httpBusy)return;
    string data=llList2Json(JSON_OBJECT,["incident_id",pendingReport,
        "node_id",(string)llGetKey(),"outcome",pendingOutcome]);
    http("outcome","/incident/outcome",data);
}
activate(string data,integer nearby) {
    string id=j(data,"incident_id");
    if(id=="" || j(data,"node_id")!=(string)llGetKey())return;
    if(id==handledIncident || llGetObjectDesc()=="QD_LAST:"+id)return;
    if(pendingRez!="")return;
    string objectName="";
    if(nearby){objectName=LARGE;}
    else {
        integer roll=(integer)llFrand(4.0); // uniform 0,1,2,3
        if(roll==0){
            handledIncident=id;
            llSetObjectDesc("QD_LAST:"+id);
            pendingReport=id;
            pendingOutcome="FALSE_ALARM";
            llOwnerSay("Alarm outcome: false alarm (no fire rezzed).");
            reportOutcome();
            return;
        }
        if(roll==1){objectName=SMALL;pendingOutcome="SMALL";}
        else if(roll==2){objectName=MEDIUM;pendingOutcome="MEDIUM";}
        else {objectName=LARGE;pendingOutcome="LARGE";}
    }
    if(llGetInventoryType(objectName)!=INVENTORY_OBJECT){
        llOwnerSay("Cannot rez fire: missing inventory object '"+objectName+"'.");
        pendingOutcome="";
        return;
    }
    // Mark before rez to prevent a second activation from polling/region messages.
    handledIncident=id;
    pendingRez=id;
    if(nearby)pendingOutcome=""; // only original node reports the random outcome
    llRezObject(objectName,llGetPos()+<0.0,0.0,1.0>,ZERO_VECTOR,ZERO_ROTATION,0);
}
default {
    state_entry() {
        ready=FALSE;httpBusy=FALSE;lastRepeater=0;cursor=0;
        handledIncident="";pendingRez="";pendingReport="";pendingOutcome="";
        if(listenHandle)llListenRemove(listenHandle);
        listenHandle=llListen(CHANNEL,"",NULL_KEY,"");
        if(llGetInventoryType(CONFIG_CARD)!=INVENTORY_NOTECARD){llOwnerSay("Missing "+CONFIG_CARD);return;}
        configLine=0;
        configQuery=llGetNotecardLine(CONFIG_CARD,configLine);
        llSetTimerEvent(5.0);
    }
    object_rez(key objectId) {
        if(pendingRez=="")return;
        llSetObjectDesc("QD_LAST:"+pendingRez);
        if(pendingOutcome!=""){
            pendingReport=pendingRez;
            reportOutcome();
        }
        pendingRez="";
    }
    on_rez(integer p){llResetScript();}
    changed(integer c){if(c&(CHANGED_OWNER|CHANGED_INVENTORY|CHANGED_REGION))llResetScript();}
    dataserver(key id,string data) {
        if(id!=configQuery)return;
        if(data==EOF){
            ready=TRUE;currentRegion=llGetRegionName();
            llOwnerSay("Fire Node ready: "+NAME+" ["+BUILDING+"]");return;
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
                else if(k=="NODE_NAME")NAME=v;
                else if(k=="BUILDING_TYPE")BUILDING=llToUpper(v);
                else if(k=="ADDRESS_SOUND")ADDRESS_SOUND=v;
                else if(k=="ADDRESS_DURATION")ADDRESS_DURATION=(float)v;
                else if(k=="SMALL_FIRE")SMALL=v;
                else if(k=="MEDIUM_FIRE")MEDIUM=v;
                else if(k=="LARGE_FIRE")LARGE=v;
            }
        }
        configQuery=llGetNotecardLine(CONFIG_CARD,++configLine);
    }
    timer() {
        if(!ready)return;
        integer t=llGetUnixTime();
        if(llGetRegionName()!=currentRegion){llResetScript();return;}
        if(t-lastHello>=30){lastHello=t;llRegionSay(CHANNEL,"NODE|"+SECRET+"|"+location());}
        if(httpBusy)return;
        if(pendingReport!=""){reportOutcome();return;}
        if(t-lastRepeater>=90){
            if(t-lastDirectRegister>=120){http("register","/node/register",location());return;}
            if(t>=nextPoll){nextPoll=t+15;
                http("poll","/poll?kind=NODE&id="+(string)llGetKey()+"&since="+(string)cursor,"");}
        }
    }
    listen(integer channel,string name,key id,string message) {
        if(channel!=CHANNEL || !ready)return;
        list a=llParseStringKeepNulls(message,["|"],[]);
        if(llGetListLength(a)<3 || llList2String(a,1)!=SECRET)return;
        string action=llList2String(a,0);
        if(action=="REPEATER")lastRepeater=llGetUnixTime();
        else if(action=="SPAWN")activate(llList2String(a,2),FALSE);
        else if(action=="LARGE_NEARBY")activate(llList2String(a,2),TRUE);
    }
    http_response(key id,integer status,list meta,string body) {
        if(id!=httpId)return;
        httpBusy=FALSE;
        if(status<200 || status>=300 || j(body,"ok")!="true"){
            if(status==401)llOwnerSay("Fire Node network key rejected.");
            return;
        }
        if(httpAction=="register")lastDirectRegister=llGetUnixTime();
        else if(httpAction=="outcome"){
            pendingReport="";pendingOutcome="";
        }
        else if(httpAction=="poll"){
            list events=llJson2List(j(body,"events"));
            integer i;
            for(i=0;i<llGetListLength(events);++i){
                string e=llList2String(events,i);
                string action=j(e,"action");
                if(action=="SPAWN")activate(j(e,"data"),FALSE);
                else if(action=="LARGE_NEARBY")activate(j(e,"data"),TRUE);
                cursor=(integer)j(e,"id");
            }
        }
    }
}
