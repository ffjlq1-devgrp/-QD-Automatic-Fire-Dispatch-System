// QD Automatic Fire System — Master Generator v2.0
// One master per customer network. Owner touch: Dispatch Now / Status / Enable / Disable.
string CONFIG_CARD = "Master_CONFIG";
string URL = "";
string KEY = "";
string COMMUNITY = "";
integer ENABLED = TRUE;
integer DELAY = 900; // seconds
integer CHANCE = 5; // chance in 20 each interval
string TYPES = "AUTOMATIC_FIRE_ALARM,RESIDENTIAL_FIRE_ALARM,COMMERCIAL_FIRE_ALARM,VEHICLE_FIRE,BRUSH_FIRE";
list RULES; // [type, minimum, requirements-json, ...]
integer lineNo;
key query;
key req;
string reqAction;
integer nextDispatch;
integer pendingManual;
integer busy;
integer menuChannel;
integer menuListen;

string field(string line, string name) { return llStringTrim(llGetSubString(line,llStringLength(name),-1),STRING_TRIM); }
string ruleFor(string type) {
    integer i;
    for (i=0;i<llGetListLength(RULES);i+=3) if(llList2String(RULES,i)==type)
        return llList2String(RULES,i+2);
    return "{\"ENGINE\":1}";
}
integer minFor(string type) {
    integer i;
    for (i=0;i<llGetListLength(RULES);i+=3) if(llList2String(RULES,i)==type)
        return llList2Integer(RULES,i+1);
    return 1;
}
integer compatibleNode(string building,string type) {
    if(type=="AUTOMATIC_FIRE_ALARM")return building!="OUTDOOR" && building!="WILDLAND";
    if(type=="RESIDENTIAL_FIRE_ALARM")return building=="RESIDENTIAL" || building=="MULTI_RESIDENTIAL";
    if(type=="COMMERCIAL_FIRE_ALARM")return building=="COMMERCIAL" || building=="INDUSTRIAL" || building=="INSTITUTIONAL";
    if(type=="VEHICLE_FIRE")return building=="OUTDOOR";
    if(type=="BRUSH_FIRE")return building=="OUTDOOR" || building=="WILDLAND";
    return FALSE;
}
string pickType() {
    list a=llCSV2List(TYPES);
    if(!llGetListLength(a))return "AUTOMATIC_FIRE_ALARM";
    return llStringTrim(llList2String(a,(integer)llFrand(llGetListLength(a))),STRING_TRIM);
}
request(string action,string path,string body) {
    if(URL=="" || KEY=="") {llOwnerSay("Missing SERVER_URL or NETWORK_KEY.");busy=FALSE;return;}
    reqAction=action;
    list headers=[HTTP_CUSTOM_HEADER,"X-Network-Key",KEY,HTTP_CUSTOM_HEADER,"X-Community-Name",COMMUNITY,HTTP_MIMETYPE,"application/json"];
    if(body=="")req=llHTTPRequest(URL+path,[HTTP_METHOD,"GET",HTTP_CUSTOM_HEADER,"X-Network-Key",KEY,HTTP_CUSTOM_HEADER,"X-Community-Name",COMMUNITY],"");
    else req=llHTTPRequest(URL+path,[HTTP_METHOD,"POST"]+headers,body);
}
readConfig() {lineNo=0;query=llGetNotecardLine(CONFIG_CARD,lineNo);}
startDispatch(integer manual) {
    if(busy)return;
    busy=TRUE;pendingManual=manual;
    request("nodes","/nodes","");
}
showMenu(key who) {
    if(menuListen)llListenRemove(menuListen);
    menuChannel=-(100000+(integer)llFrand(900000));
    menuListen=llListen(menuChannel,"",who,"");
    llDialog(who,"Master Generator",["Dispatch Now","Status","Enable","Disable"],menuChannel);
}
default {
    state_entry() {
        RULES=[];busy=FALSE;nextDispatch=llGetUnixTime()+DELAY;
        if(llGetInventoryType(CONFIG_CARD)!=INVENTORY_NOTECARD){llOwnerSay("Missing "+CONFIG_CARD);return;}
        readConfig();llSetTimerEvent(5.0);
    }
    changed(integer c) {if(c & (CHANGED_INVENTORY|CHANGED_OWNER))llResetScript();}
    dataserver(key id,string data) {
        if(id!=query)return;
        if(data==EOF){llOwnerSay("Master ready. "+(string)(llGetListLength(RULES)/3)+" dispatch rules loaded.");return;}
        data=llStringTrim(data,STRING_TRIM);
        if(data!="" && llGetSubString(data,0,0)!="#") {
            integer p=llSubStringIndex(data,"=");
            if(p>0){
                string k=llToUpper(llStringTrim(llGetSubString(data,0,p-1),STRING_TRIM));
                string v=llStringTrim(llGetSubString(data,p+1,-1),STRING_TRIM);
                if(k=="COMMUNITY_NAME")COMMUNITY=v;
            else if(k=="SERVER_URL")URL=v;
                else if(k=="NETWORK_KEY")KEY=v;
                else if(k=="ENABLED")ENABLED=(integer)v;
                else if(k=="DELAY_SECONDS") {
                    DELAY=(integer)v;
                    if(DELAY<60)DELAY=60;
                }
                else if(k=="CHANCE_IN_20") {
                    CHANCE=(integer)v;
                    if(CHANCE<0)CHANCE=0;
                    if(CHANCE>20)CHANCE=20;
                }
                else if(k=="INCIDENT_TYPES")TYPES=v;
                else if(llSubStringIndex(k,"RULE.")==0){
                    string type=llGetSubString(k,5,-1);
                    list parts=llParseString2List(v,[","],[]);
                    integer minStations=1;
                    list kv=[];
                    integer i;
                    for(i=0;i<llGetListLength(parts);++i){
                        list pair=llParseString2List(llList2String(parts,i),[":"],[]);
                        if(llGetListLength(pair)==2){
                            string a=llToUpper(llStringTrim(llList2String(pair,0),STRING_TRIM));
                            integer n=(integer)llList2String(pair,1);
                            if(a=="MIN_STATIONS") {
                                minStations=n;
                                if(minStations<1)minStations=1;
                            } else kv += [a,n];
                        }
                    }
                    RULES += [type,minStations,llList2Json(JSON_OBJECT,kv)];
                }
            }
        }
        query=llGetNotecardLine(CONFIG_CARD,++lineNo);
    }
    timer() {
        if(!ENABLED || busy || URL=="" || KEY=="")return;
        integer t=llGetUnixTime();
        if(t>=nextDispatch){
            nextDispatch=t+DELAY;
            if(llFrand(20.0)<(float)CHANCE)startDispatch(FALSE);
        }
    }
    touch_start(integer n) {if(llDetectedKey(0)==llGetOwner())showMenu(llGetOwner());}
    listen(integer channel,string name,key id,string msg) {
        if(channel!=menuChannel || id!=llGetOwner())return;
        if(msg=="Dispatch Now")startDispatch(TRUE);
        else if(msg=="Status") {if(!busy){busy=TRUE;request("status","/status","");}}
        else if(msg=="Enable"){ENABLED=TRUE;llOwnerSay("Automatic dispatch enabled.");}
        else if(msg=="Disable"){ENABLED=FALSE;llOwnerSay("Automatic dispatch disabled.");}
    }
    http_response(key id,integer status,list meta,string body) {
        if(id!=req)return;
        if(status<200 || status>=300 || llJsonGetValue(body,["ok"])!="true") {
            llOwnerSay("Cloudflare "+reqAction+" failed ("+(string)status+"): "+llGetSubString(body,0,250));busy=FALSE;return;
        }
        if(reqAction=="nodes") {
            string arr=llJsonGetValue(body,["nodes"]);
            list nodes=llJson2List(arr);
            if(!llGetListLength(nodes)){llOwnerSay("No registered Fire Nodes available.");busy=FALSE;return;}
            // Choose a compatible call/location pair, never a random incompatible building.
            list possible=[];
            list types=llCSV2List(TYPES);
            integer ni;integer ti;
            for(ni=0;ni<llGetListLength(nodes);++ni){
                string candidate=llList2String(nodes,ni);
                string building=llJsonGetValue(candidate,["building_type"]);
                for(ti=0;ti<llGetListLength(types);++ti){
                    string candidateType=llToUpper(llStringTrim(llList2String(types,ti),STRING_TRIM));
                    if(compatibleNode(building,candidateType))possible += [llJsonGetValue(candidate,["id"]),candidateType];
                }
            }
            if(llGetListLength(possible)<2){llOwnerSay("No compatible nodes and incident types are registered.");busy=FALSE;return;}
            integer pair=(integer)llFrand(llGetListLength(possible)/2)*2;
            string nodeId=llList2String(possible,pair);
            string type=llList2String(possible,pair+1);
            string payload=llList2Json(JSON_OBJECT,["node_id",nodeId,"type",type,"min_stations",minFor(type),"requirements",ruleFor(type)]);
            request("create","/incident/create",payload);
        } else if(reqAction=="create") {
            llOwnerSay("Incident created: "+llJsonGetValue(body,["incident_id"])+". Initial stations: "+llJsonGetValue(body,["stations"]));
            busy=FALSE;
        } else if(reqAction=="status") {
            llOwnerSay("Online stations: "+llJsonGetValue(body,["stations"])+"; nodes: "+llJsonGetValue(body,["nodes"])+"; open incidents: "+llJsonGetValue(body,["open"]));busy=FALSE;
        } else busy=FALSE;
    }
}
