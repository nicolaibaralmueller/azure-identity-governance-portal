/* Overview dashboard, pending-actions queue and consent settings. */
var RING_LEN=2*Math.PI*46;
function lvl(v,good,warn){return v>=good?'ok':v>=warn?'warn':'danger';}
// Decimal separator follows the deployment language (loc() in core.js).
function dec(v,n){return v.toLocaleString(loc(),{minimumFractionDigits:n,maximumFractionDigits:n});}
function pctTxt(v){return dec(v,2)+' %';}

function setBar(barId,pctId,val){
  var pct=Math.round(val);
  var el=$(barId);if(!el)return;
  el.style.width=pct+'%';el.className='score-row-fill score-row-fill-'+lvl(val,70,40);
  $(pctId).textContent=pct+'%';
}
function setScore(sc){
  var ring=$('scoreRing');ring.setAttribute('class','ring '+lvl(sc,70,40));
  $('scoreArc').setAttribute('stroke-dasharray',(RING_LEN*Math.max(0,Math.min(100,sc))/100).toFixed(1)+' '+RING_LEN.toFixed(1));
  $('scoreTxt').textContent=Math.round(sc);
  ring.setAttribute('aria-label',t('score.aria',{n:Math.round(sc)}));
}
function setTile(id,val,delta,level){
  var tl=$(id);if(!tl)return;
  tl.className='tile'+(level?' '+level:'');
  tl.querySelector('.val').textContent=val;
  if(delta!=null)tl.querySelector('.delta').textContent=delta;
}
function setFreshness(iso){
  if(!iso)return;var dt=new Date(iso);if(isNaN(dt))return;
  var s=dt.toLocaleString(loc(),{dateStyle:'short',timeStyle:'short'});
  $('dataFreshness').textContent=' · '+t('dash.dataAsOf',{s:s});
  $('esSync').textContent=t('dash.syncEvery',{s:s});
}

/* Paint from the precomputed server summary (instant) before per-tab data has loaded.
   updateDash() later overwrites these with live-exact values. */
function paintDash(s){
  if(!s)return;S.summary=s;
  var po=s.OwnershipPct||0,pc=s.CredPct||0,pca=s.CaPct||0,pst=s.StalePct||0,sc=s.HealthScore||0;
  setBar('sp-own-bar','sp-own-pct',po);setBar('sp-cred-bar','sp-cred-pct',pc);
  setBar('sp-ca-bar','sp-ca-pct',pca);setBar('sp-stale-bar','sp-stale-pct',pst);
  setScore(sc);
  setTile('tlScore',dec(sc,1),t('dash.outOf100'),lvl(sc,70,40));
  setTile('tlExp',fN(s.ExpiringCount),null,s.ExpiringCount===0?'ok':s.ExpiringCount<=5?'warn':'danger');
  setTile('tlPriv',fN(s.PrivilegedCount),null,'');
  $('esTotal').textContent=t('dash.acrossTypes',{n:fN(s.Total)});
  setFreshness(s.LastSynced);
}

/* Live dashboard from the loaded identity data. Health score: 4 weighted categories. */
function updateDash(){try{
  var ar=S.tabData.appregistration||[];
  var ea=S.tabData.enterpriseapp||[];
  var mi=S.tabData.managedidentity||[];
  var pu=S.tabData.privilegeduser||[];
  var all=ar.concat(ea,mi,pu);
  var tot=all.length;
  updatePendingBanner();
  // Recalculate only once every type has arrived; until then the server summary painted
  // by paintDash() stays on screen, so partial data never shows as low counts.
  if(S.isMember||!tot||!allLoaded())return;

  // ── 1. Ownership (30%) — app registrations + non-first-party enterprise apps with an owner ──
  var ownScope=ar.concat(ea.filter(function(a){return!a.IsFirstParty;}));
  function ownedPct(list){return list.length?(list.filter(function(a){return a.Owners&&a.Owners.length>0;}).length/list.length)*100:100;}
  var po=ownedPct(ownScope);
  // Same score, split by type: third-party enterprise apps often have no owner in Entra
  // and can dominate the combined figure.
  var eaOwnScope=ea.filter(function(a){return!a.IsFirstParty;});
  $('sp-own-split').textContent=t('dash.ownSplit',{a:Math.round(ownedPct(ar)),an:fN(ar.length),e:Math.round(ownedPct(eaOwnScope)),en:fN(eaOwnScope.length)});
  // ── 2. Credential hygiene (30%) — managed apps/regs with no expired/expiring creds ──
  var credScope=ownScope.filter(function(a){return a.Credentials&&a.Credentials.length>0;});
  var credOk=credScope.filter(function(a){return!hasExp(a);}).length;
  var pc=credScope.length?(credOk/credScope.length*100):100;
  // ── 3. CA coverage (20%) — non-first-party SSO enterprise apps covered by CA ──
  var caScope=ea.filter(function(a){return!a.IsFirstParty&&a.SSOMode&&a.SSOMode!=='None'&&a.CAStatus!=='Unknown';});
  var pca=caScope.length?((caScope.filter(function(a){return a.CAStatus==='Covered';}).length/caScope.length)*100):100;
  // ── 4. Stale identities (20%) — non-first-party enterprise apps + MIs with sign-in data that are not stale ──
  var staleScope=ea.filter(function(a){return!a.IsFirstParty&&a.LastSignInDate;}).concat(mi.filter(function(a){return a.LastSignInDate;}));
  var pst=staleScope.length?((staleScope.filter(function(a){return!isStale(a);}).length/staleScope.length)*100):100;
  var sc=(po*0.30)+(pc*0.30)+(pca*0.20)+(pst*0.20);

  setBar('sp-own-bar','sp-own-pct',po);setBar('sp-cred-bar','sp-cred-pct',pc);
  setBar('sp-ca-bar','sp-ca-pct',pca);setBar('sp-stale-bar','sp-stale-pct',pst);
  setScore(sc);
  setTile('tlScore',dec(sc,1),t('dash.outOf100'),lvl(sc,70,40));

  // ── Tiles ──
  var byType={};TYPES.forEach(function(t){byType[t]=(S.tabData[t]||[]);});
  var highBy=TYPES.map(function(t){return{t:t,n:byType[t].filter(function(a){return a.RiskLevel==='High';}).length};});
  var high=highBy.reduce(function(s,x){return s+x.n;},0);
  var topHigh=highBy.slice().sort(function(a,b){return b.n-a.n;})[0];
  setTile('tlHigh',fN(high),highBy.filter(function(x){return x.n;}).map(function(x){return x.n+' '+TYPE_LABEL[x.t].toLowerCase();}).join(' · ')||t('common.none'),high?'danger':'ok');
  $('tlHigh').onclick=function(){openList(high?topHigh.t:'appregistration',{risk:'High'});};

  var exp=all.filter(hasExp).length,expd=all.filter(hasExpired).length;
  setTile('tlExp',fN(exp),expd?t('dash.alreadyExpired',{n:expd}):t('dash.noneExpired'),exp===0?'ok':exp<=5?'warn':'danger');

  var noLive=ownScope.filter(function(a){return liveOwners(a).length===0;});
  var leavers=noLive.filter(function(a){return a.Owners&&a.Owners.length>0;}).length;
  setTile('tlOwner',fN(noLive.length),leavers?t('dash.leavers',{n:leavers}):'',noLive.length?'danger':'ok');

  var privApps=ar.concat(ea,mi).filter(hasPriv).length;
  setTile('tlPriv',fN(privApps+pu.length),t('dash.privSplit',{u:pu.length,a:privApps}),'');

  var pend=collectPending();
  setTile('tlPend',fN(pend.length),t('dash.awaitingAdmin'),pend.length?'warn':'');

  // ── Essentials ──
  $('esTotal').textContent=t('dash.acrossTypes',{n:fN(tot)});
  var optedIn=ar.filter(function(a){return a.NotifyOnExpiry;}).length;
  $('esNotify').textContent=S.notifyAvailable?t('dash.emailOptedIn',{n:fN(optedIn)}):t('dash.notConfigured');

  renderRiskByType(byType);
  renderExpiry(ar.concat(ea));
  renderReasons(all);
  renderPendingTop(pend);
  renderAdvisories(all);
  renderNotify(ar);
  renderPendingView(pend);
}catch(e){console.warn('Dashboard error:',e);}}

function renderRiskByType(byType){
  $('riskByType').innerHTML=TYPES.map(function(ty){
    var l=byType[ty],n=l.length||1;
    var h=l.filter(function(a){return a.RiskLevel==='High';}).length,m=l.filter(function(a){return a.RiskLevel==='Medium';}).length,k=l.length-h-m;
    var tip=t('dash.riskTip',{h:h,m:m,k:k});
    return'<button class="stack-row" onclick="switchTab(\''+ty+'\')" title="'+tip+'"><span>'+TYPE_LABEL[ty]+'</span><span class="stack"><i class="c-high" style="width:'+(h/n*100)+'%"></i><i class="c-med" style="width:'+(m/n*100)+'%"></i><i class="c-ok" style="width:'+(k/n*100)+'%"></i></span><span class="n">'+fN(l.length)+'</span></button>';
  }).join('');
}

function renderExpiry(items){
  var weeks=[0,0,0,0,0,0,0,0,0,0,0,0],expired=0;
  items.forEach(function(a){(a.Credentials||[]).forEach(function(c){
    if(c.DaysLeft==null)return;
    if(c.DaysLeft<0){expired++;return;}
    var w=Math.floor(c.DaysLeft/7);if(w<12)weeks[w]++;
  });});
  var max=Math.max.apply(null,weeks)||1,today=new Date();
  $('expiryCols').innerHTML=weeks.map(function(n,i){
    return'<div class="col'+(i<2?' soon':'')+'" title="'+escH(tn('dash.credCount',n))+'"><span>'+(n||'')+'</span><i style="height:'+Math.round(n/max*85)+'%"></i></div>';
  }).join('');
  $('expiryLbls').innerHTML=weeks.map(function(_,i){
    var d=new Date(today.getTime()+i*7*86400000);
    return'<span>'+d.toLocaleDateString(loc(),{day:'numeric',month:'numeric'})+'</span>';
  }).join('');
  var total=weeks.reduce(function(s,n){return s+n;},0);
  $('expiryNote').textContent=tn('dash.expiryNote',total)+(expired?t('dash.expiryNoteExpired',{n:expired}):'.');
}

function renderReasons(all){
  var counts={},byType={};
  all.forEach(function(a){var seen={};(a.RiskReasons||[]).forEach(function(r){var k=reasonKey(r);if(!k||seen[k])return;seen[k]=true;counts[k]=(counts[k]||0)+1;byType[k]=byType[k]||{};var ty=a.IdentityType||"appregistration";byType[k][ty]=(byType[k][ty]||0)+1;});});
  var keys=Object.keys(counts).sort(function(a,b){return counts[b]-counts[a];}).slice(0,6);
  if(!keys.length){$('topReasons').innerHTML='<li class="empty">'+t('dash.noReasons')+'</li>';return;}
  $('topReasons').innerHTML=keys.map(function(k){
    var types=byType[k],t=Object.keys(types).sort(function(a,b){return types[b]-types[a];})[0]||'appregistration';
    return'<li><button onclick="openReason(\''+esc(k)+'\',\''+t+'\')">'+escH(k)+'</button><span class="pill neutral">'+fN(counts[k])+'</span></li>';
  }).join('');
}
function openReason(key,type){openList(type,{reason:key});}

function renderAdvisories(all){
  var counts={};
  all.forEach(function(a){var seen={};(a.Advisories||[]).forEach(function(x){var k=adviceKey(x);if(seen[k])return;seen[k]=true;counts[k]=(counts[k]||0)+1;});});
  var keys=Object.keys(counts).sort(function(a,b){return counts[b]-counts[a];});
  $('advisoryTop').innerHTML=keys.length?keys.map(function(k){return'<li><span>'+escH(k)+'</span><span class="pill info">'+fN(counts[k])+'</span></li>';}).join(''):'<li class="empty">'+t('dash.noAdvisories')+'</li>';
}

/* Notification coverage for app registrations. "Eligible" = has an owner with a UPN and at
   least one credential, the same rule the Notify toggle uses (canNotify). */
function renderNotify(ar){
  if(S.notifyState==='loading'){$('notifyCard').innerHTML='<div class="empty">'+t('dash.notifyChecking')+'</div>';return;}
  if(S.notifyState==='error'){$('notifyCard').innerHTML='<div class="empty">'+t('dash.notifyError')+' <button class="mbtn" onclick="loadNotifyConfig()">'+t('btn.retry')+'</button></div>';return;}
  if(!S.notifyAvailable){$('notifyCard').innerHTML='<div class="empty">'+t('dash.notifyNotConfigured')+'</div>';return;}
  var eligible=ar.filter(canNotify),on=eligible.filter(function(a){return a.NotifyOnExpiry;}).length;
  var off=eligible.length-on,urgent=eligible.filter(function(a){return!a.NotifyOnExpiry&&hasExp(a);}).length;
  var pct=eligible.length?on/eligible.length*100:0;
  function row(label,n,status,cls){return'<li>'+(status?'<button onclick="openList(\'appregistration\',{status:\''+status+'\'})">'+label+'</button>':'<span>'+label+'</span>')+'<span class="pill '+cls+'">'+fN(n)+'</span></li>';}
  $('notifyCard').innerHTML=
    '<div class="big-stat">'+t('dash.notifyStat',{on:'<span class="big-num">'+fN(on)+'</span>',total:fN(eligible.length),pct:Math.round(pct)})+'</div>'+
    '<div class="score-row-bar" style="margin:6px 0 10px"><div class="score-row-fill score-row-fill-'+lvl(pct,70,40)+'" style="width:'+pct.toFixed(1)+'%"></div></div>'+
    '<ul class="rlist">'+
      row(t('dash.notifyOn'),on,'notify-on','ok')+
      row(t('dash.notifyOff'),off,'notify-off',off?'med':'neutral')+
      row(t('dash.notifyOffExp'),urgent,'notify-off-expiring',urgent?'high':'neutral')+
      row(t('dash.notEligible'),ar.length-eligible.length,null,'neutral')+
    '</ul>';
}

function kindPill(kind){return'<span class="pill '+(kind==='Delete'?'high':'info')+'">'+escH(tv('kind',kind))+'</span>';}
function renderPendingTop(pend){
  $('pendingTop').innerHTML=pend.length?pend.slice(0,5).map(function(p,i){
    return'<li><button onclick="openPending('+i+')">'+escH(p.item.DisplayName)+'</button>'+kindPill(p.kind)+'</li>';
  }).join(''):'<li class="empty">'+t('pend.nothing')+'</li>';
}
function renderPendingView(pend){
  S.pending=pend;
  $('pendingRows').innerHTML=pend.length?pend.map(function(p,i){
    return'<tr data-pend="'+i+'"><td><span class="name-cell">'+escH(p.item.DisplayName)+'</span></td><td>'+TYPE_SINGULAR[p.type]+'</td><td>'+kindPill(p.kind)+'</td><td>'+escH(p.detail||'')+'</td><td>'+escH(p.by||t('common.unknown'))+'</td><td>'+fD(p.on)+'</td></tr>';
  }).join(''):'<tr><td colspan="6"><div class="es">'+t('pend.nothing')+'</div></td></tr>';
}
function openPending(i){var p=(S.pending||[])[i];if(!p)return;switchTab(p.type);openDetails(p.item.AppId);}
document.addEventListener('click',function(e){var tr=e.target.closest('#pendingRows tr[data-pend]');if(tr)openPending(+tr.getAttribute('data-pend'));});

// ── Consent posture ──
function dismissConsentBanner(){$('consentBanner').classList.remove('visible');try{sessionStorage.setItem('consentBannerDismissed','1');}catch(e){}}
function ucsLabel(ucs){return tv('ucs',ucs||'Unknown');}
function loadConsentData(){
  afRetry(S.apiBase+'/GetTenantConfig').then(function(r){if(!r.ok)throw new Error('API '+r.status);return r.json();}).then(function(d){
    // Dashboard paints instantly from the precomputed summary; updateDash() refines it.
    if(d&&d.Dashboard)paintDash(d.Dashboard);
    S.consent=d;
    var status=d&&d.OverallStatus?d.OverallStatus:'Unknown';
    var cls=status==='Healthy'?'ok':status==='Critical'?'high':status==='Warning'?'med':'neutral';
    var nF=d&&d.Findings?d.Findings.length:0;
    $('esConsent').innerHTML='<span class="pill '+cls+'">'+escH(tv('cstatus',status))+'</span>'+(nF?' '+escH(tn('cons.findingCount',nF)):'')+' &middot; <a href="#" onclick="showView(\'consent\');return false">'+t('cons.review')+'</a>';

    var rows='';
    function cr(label,val,good){rows+='<div class="consent-row"><span class="consent-row-icon '+(good?'good':'bad')+'">'+(good?'✓':'✗')+'</span><span class="consent-row-label">'+escH(label)+'</span><span class="consent-row-val '+(good?'good':'bad')+'">'+escH(String(val))+'</span></div>';}
    if(d){
      cr(t('cons.workflow'),d.AdminConsentEnabled?t('status.enabled'):t('status.disabled'),d.AdminConsentEnabled===true);
      cr(t('cons.reviewers'),d.ReviewersConfigured?t('common.yes'):t('common.no'),d.ReviewersConfigured===true);
      cr(t('cons.email'),d.EmailNotificationsEnabled?t('cons.on'):t('cons.off'),d.EmailNotificationsEnabled===true);
      var ucs=d.UserConsentSetting||'Unknown';
      cr(t('cons.userSetting'),ucsLabel(ucs),ucs==='Disabled'||ucs==='VerifiedPublishersOnly'||ucs==='Restricted');
      $('consentFindings').innerHTML=nF?d.Findings.map(function(f){return'<div class="finding">⚠ '+escH(f.Message)+'</div>';}).join(''):'<div class="empty">'+t('cons.noFindings')+'</div>';
    }else{
      rows='<div class="empty">'+t('cons.noData')+'</div>';
      $('consentFindings').innerHTML='<div class="empty">'+t('cons.noData')+'</div>';
    }
    $('consentRows').innerHTML=rows;

    // Banner only when not dismissed and the status is actionable.
    var dismissed=false;try{dismissed=!!sessionStorage.getItem('consentBannerDismissed');}catch(e){}
    if(dismissed||!d||status==='Healthy'||status==='Unknown'||!nF)return;
    var isCrit=status==='Critical';
    $('consentBanner').className='banner admin-only visible '+(isCrit?'banner-crit':'banner-warn');
    $('consentBannerTitle').textContent=isCrit?t('cons.bannerCrit'):t('cons.bannerWarn');
    $('consentBannerFindings').innerHTML=d.Findings.map(function(f){return'<div class="consent-banner-finding">'+escH(f.Message)+'</div>';}).join('');
  }).catch(function(e){
    console.warn('Tenant config failed:',e);
    $('esConsent').innerHTML=t('cons.couldntLoad')+' &middot; <a href="#" onclick="loadConsentData();return false">'+t('btn.retry')+'</a>';
    $('consentRows').innerHTML='<div class="empty">'+t('cons.couldntLoadSettings')+' <button class="mbtn" onclick="loadConsentData()">'+t('btn.retry')+'</button></div>';
  });
}

// ── Notification setup (is mail via Azure Communication Services configured?) ──
// Retried like the identity calls; an error is shown as such, not as "not configured".
function loadNotifyConfig(){
  S.notifyState='loading';if(!S.isMember)renderNotify(S.tabData.appregistration||[]);
  return afRetry(S.apiBase+'/GetNotifyConfig').then(function(r){if(!r.ok)throw new Error('API '+r.status);return r.json();}).then(function(d){
    S.notifyState='ok';S.notifyAvailable=!!(d&&d.available);
    $('esNotify').textContent=S.notifyAvailable?t('dash.email'):t('dash.notConfigured');
    if(S.activeTab==='appregistration'&&S.loadState.appregistration==='ok')renderActive();
    updateDash();if(allLoaded())renderNotify(S.tabData.appregistration||[]);
  }).catch(function(e){
    console.warn('Notification config failed:',e);
    S.notifyState='error';$('esNotify').textContent=t('dash.couldntCheck');
    renderNotify(S.tabData.appregistration||[]);
  });
}
