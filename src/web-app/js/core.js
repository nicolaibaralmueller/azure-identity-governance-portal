/* Core: shared state, helpers, API access and data loading. */
var S={apiBase:'',token:null,view:'overview',activeTab:'appregistration',tabData:{appregistration:[],enterpriseapp:[],managedidentity:[],privilegeduser:[]},allItems:[],filteredItems:[],sortCol:'DisplayName',sortDir:'asc',hideMSApps:true,myApps:false,reasonFilter:null,pendAct:null,omApp:null,usTimer:null,refreshTimer:null,curUser:{name:'',upn:''},rs:null,selected:{},notifyAvailable:false,tabLoaded:{},msLoaded:false,isMember:false,detailId:null,consent:null,summary:null};
var TYPES=['appregistration','enterpriseapp','managedidentity','privilegeduser'];
// Getters, so the labels follow the language set by setLanguage() after this file loads.
var TYPE_LABEL={},TYPE_SINGULAR={};
TYPES.forEach(function(ty){
  Object.defineProperty(TYPE_LABEL,ty,{enumerable:true,get:function(){return t('type.'+ty);}});
  Object.defineProperty(TYPE_SINGULAR,ty,{enumerable:true,get:function(){return t('type1.'+ty);}});
});

function esc(s){return(s||'').replace(/'/g,"\\'").replace(/"/g,'&quot;');}
function escH(s){return(s==null?'':String(s)).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');}
// Dates and numbers follow the deployment language (LANG, set by setLanguage()).
function loc(){return typeof LANG!=='undefined'&&LANG==='da'?'da-DK':'en-GB';}
function fD(iso){return iso?new Date(iso).toLocaleDateString(loc()):'';}
function fN(n){return(n||0).toLocaleString(loc());}
function $(id){return document.getElementById(id);}

// Foreground (active-tab) load indicator: the centered spinner + the busy cursor move
// together. Background tab fills don't call this, so the cursor only shows while the
// current tab is loading.
function showLoading(on){$('loadC').style.display=on?'flex':'none';document.body.classList.toggle('app-busy',!!on);}
function showErr(m){showLoading(false);$('errC').style.display='block';$('errC').innerHTML='<div class="eb"><svg class="i"><use href="#i-warn"/></svg>'+escH(m)+'</div>';}

function af(url,opts){opts=opts||{};return fetch(url,Object.assign({},opts,{headers:Object.assign({Authorization:'Bearer '+S.token,'Content-Type':'application/json'},opts.headers||{})}));}
function norm(item){['PendingOwnerChanges','Credentials','RiskReasons','Owners','DirectoryRoles','ApiPermissions'].forEach(function(f){if(!Array.isArray(item[f]))item[f]=item[f]?[item[f]]:[];});}

// ── Identity predicates ──
function gOwn(a){return a.Owners&&a.Owners.length?a.Owners.map(function(o){return o.DisplayName||o.UserPrincipalName||'Unknown';}).join(', '):null;}
function gOwnS(a){return a.Owners&&a.Owners.length?a.Owners.map(function(o){return(o.DisplayName||'')+' '+(o.UserPrincipalName||'');}).join(' ').toLowerCase():'';}
function isMS(a){return a.IsFirstParty===true;}
function hasExp(a){return a.Credentials&&a.Credentials.some(function(c){return c.Status==='Expired'||c.Status==='Expiring';});}
function hasExpired(a){return a.Credentials&&a.Credentials.some(function(c){return c.Status==='Expired';});}
function hasPriv(a){return(a.DirectoryRoles&&a.DirectoryRoles.length>0)||(a.ApiPermissions&&a.ApiPermissions.some(function(p){return p.RiskLevel==='High';}));}
function hasPend(a){return a.MarkedForDeletion||(a.PendingOwnerChanges&&a.PendingOwnerChanges.length>0);}
function isStale(a){
  if(!a.LastSignInDate)return false;
  var d=a.DaysSinceSignIn;if(d==null)return false;
  var t=a.IdentityType==='privilegeduser'?60:a.IdentityType==='managedidentity'?90:180;
  return d>=t;
}
function hasNoCA(a){return a.IdentityType==='enterpriseapp'&&!a.IsFirstParty&&(a.CAStatus==='None');}
// Only an enabled owner is cover — mirrors Get-StaticRisk on the server.
function liveOwners(a){return (a.Owners||[]).filter(function(o){return o.Enabled!==false;});}
function isMyApp(a){var u=(S.curUser.upn||'').toLowerCase();if(!u)return false;return a.Owners&&a.Owners.some(function(o){return(o.UserPrincipalName||'').toLowerCase()===u;});}
function findItem(id,type){var list=S.tabData[type||S.activeTab]||[];return list.find(function(x){return x.AppId===id;});}

// Risk reasons carry specifics ("…: Global Administrator", "(has 1)", "in 214 days").
// Strip them so the same reason groups together on the dashboard and in the filter.
function reasonKey(r){return String(r||'').split(':')[0].replace(/\s*\([^)]*\)/g,'').replace(/\d+/g,'N').trim();}
// The lifetime advisory carries numbers; group it by its fixed start, in either language.
function adviceKey(x){x=String(x||'');if(/^(Secret issued for|Secret udstedt for)/i.test(x))return t('adv.secretLifetimeAbove');return x.split(' - ')[0].trim();}

function entraUrl(a,type){
  type=type||a.IdentityType||S.activeTab;
  var base='https://entra.microsoft.com/#view/';
  if(type==='appregistration')return base+'Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/Overview/appId/'+a.AppId;
  if(type==='enterpriseapp'||type==='managedidentity')return base+'Microsoft_AAD_IAM/ManagedAppMenuBlade/~/Overview/objectId/'+(a.ObjectId||a.AppId)+'/appId/'+a.AppId;
  if(type==='privilegeduser')return base+'Microsoft_AAD_UsersAndTenants/UserProfileMenuBlade/~/overview/userId/'+(a.ObjectId||a.AppId);
  return'';
}

// ── Pending governance actions, de-duplicated across tabs ──
// A linked app registration and enterprise app share one AppId and one GovernanceState row,
// so the same request can appear in both tabs. Count it once.
function collectPending(){
  var out=[],seen={};
  TYPES.forEach(function(t){(S.tabData[t]||[]).forEach(function(a){
    function add(kind,detail,by,on,key){var k=a.AppId+'|'+key;if(seen[k])return;seen[k]=true;out.push({type:t,item:a,kind:kind,detail:detail,by:by,on:on});}
    if(a.MarkedForDeletion)add('Delete','',a.MarkedBy,a.MarkedOn,'del');
    if(a.ProposedName)add('Rename',a.ProposedName,a.RenameRequestedBy,a.RenameRequestedOn,'ren');
    (a.PendingOwnerChanges||[]).forEach(function(p){add(p.Action==='add'?'Add owner':'Remove owner',p.TargetName||p.TargetUpn,p.RequestedBy,p.RequestedOn,'own-'+p.Action+'-'+p.TargetUpn);});
  });});
  out.sort(function(x,y){return new Date(y.on||0)-new Date(x.on||0);});
  return out;
}

// ── Resilient GET ──
// A slow or briefly failing API (cold worker, sync timer running, transient 5xx) must not
// leave part of the portal empty until the user reloads. Each attempt has a time limit;
// network errors, timeouts, 408/429 and 5xx are retried with back-off.
var RETRY_DELAYS=[1000,3000,8000],REQUEST_TIMEOUT=90000;
function afRetry(url,attempt){
  attempt=attempt||0;
  var ctl=new AbortController(),timer=setTimeout(function(){ctl.abort();},REQUEST_TIMEOUT);
  function again(err){if(attempt>=RETRY_DELAYS.length)throw err;return new Promise(function(res){setTimeout(res,RETRY_DELAYS[attempt]);}).then(function(){return afRetry(url,attempt+1);});}
  return af(url,{signal:ctl.signal}).then(function(r){
    clearTimeout(timer);
    if(r.status>=500||r.status===408||r.status===429)return again(new Error('API '+r.status));
    return r;
  },function(e){clearTimeout(timer);return again(e.name==='AbortError'?new Error('timed out'):e);});
}

// ── Data loading ──
// Per-type load state drives the loading banner and decides when the dashboard may be
// recalculated: 'loading' | 'ok' | 'error'.
S.loadState={};
function requiredTypes(){return S.isMember?['appregistration','enterpriseapp']:TYPES;}
function allLoaded(){return requiredTypes().every(function(t){return S.loadState[t]==='ok';});}

// Fetch ONE type. Single-partition read on the backend — far faster than scope=all,
// which has to compute every type before it can respond.
// Enterprise apps default to excluding Microsoft first-party SPs (lazy-loaded on demand).
function fetchOne(type){var url='/GetIdentities?type='+type;if(type==='enterpriseapp')url+='&firstParty=exclude';return afRetry(S.apiBase+url).then(function(r){if(!r.ok)throw new Error('API '+r.status);return r.text();}).then(function(t){var d=t?JSON.parse(t):[];var items=Array.isArray(d)?d:(d?[d]:[]);items.forEach(norm);return items;});}
// Fetch + store one type, tracking its state. Resolves with the items, rejects on failure.
// A type that is already loading returns the same request instead of starting another.
S.loadPromise={};
function loadType(type){
  if(S.loadState[type]==='loading'&&S.loadPromise[type])return S.loadPromise[type];
  S.loadState[type]='loading';updateLoadBanner();
  var p=fetchOne(type).then(function(items){
    setTabData(type,items);S.loadState[type]='ok';updateLoadBanner();
    if(S.activeTab===type){renderActive();showLoading(false);$('tblC').style.display='block';$('errC').style.display='none';}
    return items;
  },function(e){
    S.loadState[type]='error';var tc=$('tc-'+type);if(tc){tc.textContent='⚠';tc.title=t('load.couldntShort');}updateLoadBanner();
    if(S.activeTab===type)showLoading(false);
    throw e;
  });
  S.loadPromise[type]=p;
  return p;
}
function setTabData(type,items){S.tabData[type]=items;S.tabLoaded[type]=true;if(type==='enterpriseapp')S.msLoaded=false;var tc=$('tc-'+type);if(tc)tc.textContent=fN(items.length);}
// Lazy-load Microsoft first-party enterprise apps and merge them in (once).
function ensureMSApps(){if(S.msLoaded)return Promise.resolve();return afRetry(S.apiBase+'/GetIdentities?type=enterpriseapp&firstParty=only').then(function(r){if(!r.ok)throw new Error('API '+r.status);return r.json();}).then(function(d){var items=Array.isArray(d)?d:(d?[d]:[]);items.forEach(norm);S.tabData.enterpriseapp=(S.tabData.enterpriseapp||[]).concat(items);S.msLoaded=true;var tc=$('tc-enterpriseapp');if(tc)tc.textContent=fN(S.tabData.enterpriseapp.length);if(S.activeTab==='enterpriseapp')S.allItems=S.tabData.enterpriseapp;updateDash();}).catch(function(e){console.warn('Microsoft apps load failed:',e);});}

// First paint: load the active tab, show it, then pull the rest. A failure on the active
// tab no longer stops the other types from loading.
function loadActiveThenRest(){
  var active=S.activeTab;
  return loadType(active).then(function(){showLoading(false);$('tblC').style.display='block';},function(e){if(S.activeTab===active)showErr(t('load.couldntType',{type:TYPE_LABEL[active].toLowerCase(),msg:e.message}));})
    .then(loadRemaining);
}
function loadRemaining(){var rest=requiredTypes().filter(function(t){return t!==S.activeTab;});return Promise.allSettled(rest.map(loadType)).then(function(){updateDash();startAutoRefresh();if(!S.hideMSApps)ensureMSApps().then(applyFilters);});}
// Re-request only the types that failed (Retry button in the loading banner).
function retryFailed(){
  var failed=requiredTypes().filter(function(t){return S.loadState[t]==='error';});
  $('errC').style.display='none';
  if(failed.indexOf(S.activeTab)>=0){showLoading(true);$('tblC').style.display='none';}
  return Promise.allSettled(failed.map(loadType)).then(function(){if(S.loadState[S.activeTab]==='ok'){showLoading(false);$('tblC').style.display='block';}updateDash();});
}
// Safety net for a freshly deployed tenant whose cache is still filling: re-pull any
// still-empty tabs every 5s until all have data (capped).
function startAutoRefresh(){clearInterval(S.refreshTimer);var attempts=0,MAX=24,busy=false;var types=requiredTypes();S.refreshTimer=setInterval(function(){if(busy)return;var allHave=types.every(function(t){return S.tabData[t]&&S.tabData[t].length>0;});if(allHave||++attempts>MAX){clearInterval(S.refreshTimer);S.refreshTimer=null;return;}var empty=types.filter(function(t){return S.loadState[t]!=='loading'&&!(S.tabData[t]&&S.tabData[t].length>0);});busy=true;Promise.allSettled(empty.map(function(t){return fetchOne(t).then(function(items){if(items.length){setTabData(t,items);S.loadState[t]="ok";updateLoadBanner();if(S.activeTab===t){renderActive();showLoading(false);$("tblC").style.display="block";$("errC").style.display="none";}}});})).then(function(){busy=false;updateDash();});},5000);}
function refreshAll(){clearInterval(S.refreshTimer);S.refreshTimer=null;showLoading(true);$('tblC').style.display='none';$('errC').style.display='none';$('statsBar').style.display='none';clearSel();S.tabLoaded={};S.loadState={};loadConsentData();loadNotifyConfig();loadActiveThenRest();}

// Loading banner: tells the user what is still loading, and what failed with a Retry.
function updateLoadBanner(){
  var el=$('loadBanner');if(!el)return;
  var types=requiredTypes();
  var loading=types.filter(function(t){return S.loadState[t]==='loading'||!S.loadState[t];});
  var failed=types.filter(function(t){return S.loadState[t]==='error';});
  if(failed.length){
    el.className='banner banner-crit visible';
    $('loadBannerText').innerHTML='<strong>'+escH(t('load.failed',{types:failed.map(function(ty){return TYPE_LABEL[ty].toLowerCase();}).join(', ')}))+'</strong> '+escH(t('load.incomplete'))+' <button class="mbtn" style="margin-left:8px" onclick="retryFailed()">'+escH(t('btn.retry'))+'</button>';
  }else if(loading.length){
    el.className='banner banner-info visible';
    $('loadBannerText').innerHTML='<strong>'+escH(t('load.loading'))+'</strong> '+escH(t('load.progress',{done:types.length-loading.length,total:types.length}));
  }else{el.className='banner';}
}
