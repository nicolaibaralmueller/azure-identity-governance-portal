/* Identity list: columns, cell renderers, filters, sorting, selection and export. */
var COLS={
get appregistration(){return[{k:'DisplayName',l:'Display name',w:'14%'},{k:'RiskLevel',l:'Risk',w:'13%'},{k:'ContextPurpose',l:'Context',w:'12%'},{k:'Owners',l:'Owners',w:'13%'},{k:'Permissions',l:'Permissions',w:'11%'},{k:'Credentials',l:'Credentials',w:'8%'},{k:'CreatedOn',l:'Created',w:'6%'}].concat(S.notifyAvailable?[{k:'NotifyOnExpiry',l:'Notify',w:'5%'}]:[]).concat([{k:'MarkedForDeletion',l:'Actions',w:'8%'}]);},
enterpriseapp:[{k:'DisplayName',l:'Display name',w:'13%'},{k:'RiskLevel',l:'Risk',w:'12%'},{k:'ContextPurpose',l:'Context',w:'11%'},{k:'AccountEnabled',l:'Status',w:'5%'},{k:'IsFirstParty',l:'Type',w:'5%'},{k:'SSOMode',l:'SSO',w:'6%'},{k:'CAStatus',l:'CA',w:'5%'},{k:'Permissions',l:'Permissions',w:'10%'},{k:'Owners',l:'Owners',w:'11%'},{k:'CreatedOn',l:'Created',w:'6%'},{k:'LastSignInDate',l:'Last sign-in',w:'7%'},{k:'MarkedForDeletion',l:'Actions',w:'9%'}],
managedidentity:[{k:'DisplayName',l:'Display name',w:'15%'},{k:'RiskLevel',l:'Risk',w:'13%'},{k:'ManagedIdentityType',l:'Type',w:'6%'},{k:'AccountEnabled',l:'Status',w:'5%'},{k:'Permissions',l:'Permissions',w:'12%'},{k:'AzureResourceId',l:'Azure resource',w:'14%'},{k:'CreatedOn',l:'Created',w:'6%'},{k:'LastSignInDate',l:'Last sign-in',w:'7%'},{k:'MarkedForDeletion',l:'Actions',w:'8%'}],
privilegeduser:[{k:'DisplayName',l:'Display name',w:'16%'},{k:'RiskLevel',l:'Risk',w:'13%'},{k:'DirectoryRoles',l:'Directory roles',w:'20%'},{k:'AccountEnabled',l:'Status',w:'5%'},{k:'Department',l:'Department',w:'8%'},{k:'CreatedOn',l:'Created',w:'6%'},{k:'LastSignInDate',l:'Last sign-in',w:'7%'},{k:'MarkedForDeletion',l:'Actions',w:'9%'}]
};
var ICON_EDIT='<svg width="10" height="10" viewBox="0 0 16 16"><path d="M12.1 2L14 3.9 4.5 13.4 2 14l.6-2.5L12.1 2z"/></svg>';
var ICON_DEL='<svg width="10" height="10" viewBox="0 0 16 16"><path d="M14 3h-3.5l-1-1h-3l-1 1H2v2h12V3zM3 14V6h10v8c0 1.1-.9 2-2 2H5c-1.1 0-2-.9-2-2z"/></svg>';
var ICON_EXT='<svg viewBox="0 0 16 16"><path d="M9 2h5v5l-2-2-3 3-2-2 3-3L9 2zM2 4h5v2H4v6h6V9h2v5H2V4z"/></svg>';

// ── Cell renderers ──
function rCreds(a){var cr=a.Credentials||[];if(!cr.length)return'<span class="ctag ctag-n">'+t('common.none')+'</span>';var g=[{l:t('cred.Secret'),i:cr.filter(function(c){return c.Type==='Secret';})},{l:t('cred.Certificate'),i:cr.filter(function(c){return c.Type==='Certificate';})}];return'<div class="ct">'+g.filter(function(x){return x.i.length;}).map(function(x){var w=x.i.some(function(s){return s.Status==='Expired';})?'Expired':x.i.some(function(s){return s.Status==='Expiring';})?'Expiring':'Valid';var c=w==='Expired'?'ctag-d':w==='Expiring'?'ctag-w':'ctag-ok';var tip=x.i.map(function(s){var d=s.EndDateTime?fD(s.EndDateTime):'?';var dl=s.DaysLeft!=null?(s.DaysLeft<0?t('cred.expiredAgoShort',{n:Math.abs(s.DaysLeft)}):t('cred.leftShort',{n:s.DaysLeft})):'';return escH(s.DisplayName||t('common.unnamed'))+': '+d+' ('+dl+')';}).join('\n');return'<span class="ctag '+c+'">'+x.l+' ('+x.i.length+')<span class="ctt">'+tip+'</span></span>';}).join('')+'</div>';}
function rPerms(a){var ro=a.DirectoryRoles||[],pe=a.ApiPermissions||[];if(!ro.length&&!pe.length)return'<span class="na">'+t('common.none')+'</span>';var rt=ro.map(function(r){return'<span class="ptag '+(r.RiskLevel==='High'?'ptag-h':'ptag-m')+' role-tag">'+escH(r.RoleName)+'<span class="ptt">'+t('perm.dirRole')+': '+escH(r.RoleName)+'\n'+t('perm.risk')+': '+tv('risk',r.RiskLevel)+'</span></span>';});var br={};pe.forEach(function(p){if(!br[p.Resource])br[p.Resource]=[];br[p.Resource].push(p);});var pt=Object.keys(br).map(function(r){var ps=br[r];var w=ps.some(function(p){return p.RiskLevel==='High';})?'High':ps.some(function(p){return p.RiskLevel==='Medium';})?'Medium':'Low';var c=w==='High'?'ptag-h':w==='Medium'?'ptag-m':'ptag-l';var tip=ps.map(function(p){return p.Permission+' ('+tv('risk',p.RiskLevel)+')';}).join('\n');return'<span class="ptag '+c+'">'+escH(r)+' ('+ps.length+')<span class="ptt">'+escH(r)+':\n'+tip+'</span></span>';});return'<div class="ptags">'+rt.concat(pt).join('')+'</div>';}
function riskClass(l){return l==='High'?'rh-b':l==='Medium'?'rm-b':'rk-b';}
/* Risk cell = the verdict, its reasons, then any advisories. Advisories are improvement
   hints, not defects — they are styled apart and never influence RiskLevel. */
function rRisk(a){
  var h='<span class="rb '+riskClass(a.RiskLevel)+'">'+escH(tv('risk',a.RiskLevel))+'</span>';
  if(a.RiskReasons&&a.RiskReasons.length)h+='<div class="rr">'+a.RiskReasons.map(escH).join('<br>')+'</div>';
  if(a.Advisories&&a.Advisories.length)h+='<div class="adv">'+a.Advisories.map(function(x){return'<span class="adv-i">&#128161;</span>'+escH(x);}).join('<br>')+'</div>';
  return h;
}
function rSSO(a){var m=a.SSOMode||'None';var inferred=m.indexOf('inferred')>=0;var base=inferred?m.replace(' (inferred)',''):m;var cls=base==='SAML'?'sso-saml':base==='OIDC'?'sso-oidc':base==='Password'?'sso-pw':'sso-none';return'<span class="sso-badge '+cls+'" title="'+escH(inferred?t('sso.inferredTip'):t('sso.fromEntra'))+'">'+escH(tv('sso',m))+'</span>';}
function rCA(a){
  var s=a.CAStatus||'Unknown';
  var ps=a.CAPolicies||[];
  var cls=s==='Covered'?'ca-covered':s==='None'?'ca-none':'ca-unknown';
  var tip=ps.length?ps.join('\n'):(s==='None'?t('ca.noPolicy'):t('ca.noData'));
  return'<span class="ca-badge '+cls+'" title="'+escH(tip)+'">'+escH(tv('ca',s))+'</span>';
}
function rSignIn(a){
  if(!a.LastSignInDate)return'<span class="si-none">'+t('signin.noData')+'</span>';
  var d=a.DaysSinceSignIn;
  var cls=d==null?'si-none':d<=30?'si-ok':d<=90?'si-warn':d<=180?'si-med':'si-stale';
  var lbl=d==null?'':d===0?t('signin.today'):tn('signin.ago',d);
  return'<div class="si-wrap"><span class="'+cls+'">'+escH(fD(a.LastSignInDate))+'</span><div class="si-sub">'+lbl+'</div></div>';
}
function rStatus(a){return a.AccountEnabled?'<span class="ep-badge ep-3p">'+t('status.enabled')+'</span>':'<span class="ep-badge ep-off">'+t('status.disabled')+'</span>';}

function canNotify(a){return !!(a.Owners&&a.Owners.some(function(o){return o.UserPrincipalName;})&&a.Credentials&&a.Credentials.length>0);}
function rNotify(a){
  var hasOwner=a.Owners&&a.Owners.some(function(o){return o.UserPrincipalName;});
  var hasCreds=a.Credentials&&a.Credentials.length>0;
  var ok=hasOwner&&hasCreds;
  var tip=ok?(a.NotifyOnExpiry?t('notify.on'):t('notify.off'))
    :!hasOwner&&!hasCreds?t('notify.noOwnerNoCreds')
    :!hasOwner?t('notify.noOwner')
    :t('notify.noCreds');
  var onclick=ok?'onclick="toggleNotify(\''+a.AppId+'\',\''+esc(a.DisplayName)+'\','+(!a.NotifyOnExpiry)+');return false"':'';
  return'<label class="pill-toggle '+(ok?'':'pill-toggle-disabled')+'" title="'+escH(tip)+'" '+onclick+'>'
    +'<input type="checkbox" '+(a.NotifyOnExpiry?'checked':'')+' aria-label="'+escH(tip)+'">'
    +'<span class="pill-track"><span class="pill-thumb"></span></span>'
    +'</label>';
}

/* Owner-supplied context: what this app is for. Optional, never nags, no expiry — the
   one field only the owner can fill in. Editable by anyone who can act on the identity. */
function ctxTags(a){
  var tags=[];
  if(a.ContextSystem)tags.push('<span class="ctx-tag">'+escH(a.ContextSystem)+'</span>');
  if(a.ContextEnvironment)tags.push('<span class="ctx-tag">'+escH(tv('env',a.ContextEnvironment))+'</span>');
  if(a.ContextCriticality)tags.push('<span class="ctx-tag'+(a.ContextCriticality==='Business critical'?' ctx-crit':'')+'">'+escH(tv('crit',a.ContextCriticality))+'</span>');
  return tags;
}
function rCtx(a){
  var h='',tags=ctxTags(a);
  if(a.ContextPurpose){h+='<div class="ctx" title="'+escH(a.ContextPurpose)+'">'+escH(a.ContextPurpose.length>90?a.ContextPurpose.slice(0,90)+'…':a.ContextPurpose)+'</div>';}
  else if(!tags.length){h+='<div class="ctx-none">'+t('ctx.notDescribed')+'</div>';}
  if(tags.length)h+='<div class="ctx-tags">'+tags.join('')+'</div>';
  h+='<div style="margin-top:4px"><button class="tgb tgb-ctx" onclick="openCtx(\''+a.AppId+'\')">'+ICON_EDIT+(a.ContextPurpose||tags.length?t('ctx.edit'):t('ctx.describe'))+'</button></div>';
  return h;
}

function rAct(a){var en=esc(a.DisplayName);var h='<div class="ag">';
// Same recorded action either way; members see it in the language of their own role.
var delLabel=S.isMember?t('act.requestDecom'):t('act.tagDelete');
if(a.MarkedForDeletion){h+='<button class="tgb tagged" onclick="promptUM(\''+a.AppId+'\',\''+en+'\')">'+(S.isMember?t('act.decomRequested'):t('act.markedDelete'))+'</button><div class="tgm">'+t('common.byOn',{by:escH(a.MarkedBy||t('common.unknown')),on:fD(a.MarkedOn)})+'</div>';}else{h+='<button class="tgb tgb-d" onclick="promptM(\''+a.AppId+'\',\''+en+'\')">'+ICON_DEL+delLabel+'</button>';}
if(a.ProposedName){h+='<div class="tgm" style="margin-top:3px"><span class="tgm-rename">'+t('act.renameRequested')+'</span><br>'+escH(a.ProposedName)+'<br>'+t('common.byOn',{by:escH(a.RenameRequestedBy||t('common.unknown')),on:fD(a.RenameRequestedOn)})+'</div>';}else if(S.activeTab!=='managedidentity'&&S.activeTab!=='privilegeduser'){h+='<button class="tgb" onclick="promptRename(\''+a.AppId+'\',\''+en+'\')">'+ICON_EDIT+t('act.requestRename')+'</button>';}
h+='</div>';return h;}

function rOwn(a){var pd=a.PendingOwnerChanges||[];var h;if(a.Owners&&a.Owners.length){h='<div class="ol">'+a.Owners.map(function(o){
  // A disabled owner is struck through: they are still listed in Entra but receive nothing.
  var gone=o.Enabled===false;
  return'<div class="oe'+(gone?' oe-gone':'')+'"'+(gone?' title="'+escH(t('own.goneTip'))+'"':'')+'>'+escH(o.DisplayName||t('common.unknown'))+(gone?' <span class="oe-badge">'+t('common.left')+'</span>':'')+' <span class="oupn">'+escH(o.UserPrincipalName||'')+'</span></div>';}).join('')+'</div>';
  if(!liveOwners(a).length)h+='<span class="no-own">'+t('own.noActive')+'</span>';
}else{h='<span class="no-own">'+t('own.none')+'</span>';}if(pd.length){h+='<div class="pi">'+pd.map(function(p){return'<span class="pit '+(p.Action==='add'?'pa':'pr')+'">'+(p.Action==='add'?'+':'−')+' '+escH(p.TargetName||p.TargetUpn)+'</span>';}).join('')+'</div>';}h+='<div style="margin-top:4px"><button class="tgb tgb-own" onclick="openOM(\''+a.AppId+'\',\''+esc(a.DisplayName)+'\')">'+ICON_EDIT+t('act.editOwners')+'</button></div>';return h;}

// ── Header and sorting ──
function buildTH(){var c=COLS[S.activeTab];$('tHead').innerHTML='<tr><th class="th-cb"><div class="thc"><input type="checkbox" onchange="toggleAll(this.checked)" aria-label="'+escH(t('list.selectAll'))+'"></div></th>'+c.map(function(x){return'<th style="width:'+x.w+'" data-col="'+x.k+'"'+(S.sortCol===x.k?' class="sorted"':'')+'><div class="thc" onclick="sortBy(\''+x.k+'\')">'+escH(tv('col',x.k)===x.k?x.l:t('col.'+x.k))+'<svg class="si" viewBox="0 0 12 12"><path id="si-'+x.k+'" d="'+(S.sortCol===x.k&&S.sortDir==='desc'?'M6 10l4-4H2z':'M6 2l4 4H2z')+'"/></svg></div><div class="rh" onmousedown="startR(event,this)"></div></th>';}).join('')+'</tr>';}
var RO={High:0,Medium:1,Healthy:2};
function gSV(a,c){switch(c){case'CreatedOn':case'LastSignInDate':return a[c]?new Date(a[c]).getTime():0;case'Owners':return(gOwn(a)||'zzz').toLowerCase();case'MarkedForDeletion':return a.MarkedForDeletion?0:1;case'RiskLevel':return RO[a.RiskLevel]!=null?RO[a.RiskLevel]:2;case'Credentials':return hasExp(a)?0:2;case'Permissions':case'DirectoryRoles':return hasPriv(a)?0:1;default:return String(a[c]||'').toLowerCase();}}
function doSort(){S.filteredItems.sort(function(a,b){var vA=gSV(a,S.sortCol),vB=gSV(b,S.sortCol);if(vA<vB)return S.sortDir==='asc'?-1:1;if(vA>vB)return S.sortDir==='asc'?1:-1;return 0;});}
function sortBy(c){S.sortDir=S.sortCol===c&&S.sortDir==='asc'?'desc':'asc';S.sortCol=c;document.querySelectorAll('#tHead th').forEach(function(t){t.classList.remove('sorted');});var th=document.querySelector('#tHead th[data-col="'+c+'"]');if(th)th.classList.add('sorted');document.querySelectorAll('[id^="si-"]').forEach(function(i){i.setAttribute('d','M6 2l4 4H2z');});var ic=$('si-'+c);if(ic)ic.setAttribute('d',S.sortDir==='asc'?'M6 2l4 4H2z':'M6 10l4-4H2z');doSort();renderT();}

// ── Filtering ──
function applyFilters(){var q=$('searchI').value.toLowerCase(),oF=$('ownerF').value,sF=$('statusF').value,rF=$('riskF').value,soF=$('ssoF').value;S.filteredItems=S.allItems.filter(function(a){if(S.myApps&&!isMyApp(a))return false;if(S.hideMSApps&&S.activeTab==='enterpriseapp'&&isMS(a))return false;if(S.activeTab!=='managedidentity'&&S.activeTab!=='privilegeduser'){var ho=a.Owners&&a.Owners.length>0;if(oF==='with-owner'&&!ho)return false;if(oF==='no-owner'&&ho)return false;if(oF.indexOf('owner:')===0){if(!ho)return false;var oName=oF.substring(6);if(!a.Owners.some(function(o){return(o.DisplayName||o.UserPrincipalName||'')===oName;}))return false;}}
if(sF==='marked'&&!a.MarkedForDeletion)return false;
if(sF==='pending'&&!hasPend(a))return false;
if(sF==='expiring'&&!hasExp(a))return false;
if(sF==='privileged'&&!hasPriv(a))return false;
if(sF==='stale'&&!isStale(a))return false;
if(sF==='no-ca'&&!hasNoCA(a))return false;
if(sF==='no-live-owner'&&liveOwners(a).length>0)return false;
if(sF==='owner-disabled'&&!(a.Owners&&a.Owners.some(function(o){return o.Enabled===false;})))return false;
if(sF==='sole-owner'&&!(a.Credentials&&a.Credentials.length&&liveOwners(a).length<=1))return false;
if(sF==='no-context'&&(a.ContextPurpose||a.ContextSystem))return false;
if(sF==='advisories'&&!(a.Advisories&&a.Advisories.length))return false;
if(sF==='notify-on'&&!a.NotifyOnExpiry)return false;
if(sF==='notify-off'){if(!canNotify(a)||a.NotifyOnExpiry)return false;}
if(sF==='notify-off-expiring'){if(!canNotify(a)||a.NotifyOnExpiry||!hasExp(a))return false;}
if(sF==='action-items'){if(!(a.MarkedForDeletion||(a.PendingOwnerChanges&&a.PendingOwnerChanges.length>0)||(hasExpired(a)&&(!a.Owners||!a.Owners.length))||isStale(a)||hasNoCA(a)))return false;}
if(S.reasonFilter&&!(a.RiskReasons||[]).some(function(r){return reasonKey(r)===S.reasonFilter;}))return false;
if(rF!=='all'&&a.RiskLevel!==rF)return false;
if(soF!=='all'&&S.activeTab==='enterpriseapp'&&(a.SSOMode||'None')!==soF)return false;
if(q){if((a.DisplayName||'').toLowerCase().indexOf(q)<0&&(a.AppId||'').toLowerCase().indexOf(q)<0&&(a.UserPrincipalName||'').toLowerCase().indexOf(q)<0&&gOwnS(a).indexOf(q)<0)return false;}return true;});doSort();updateStats();renderT();if(S.detailId)refreshDetails();}

function setReason(key){S.reasonFilter=key||null;$('reasonV').textContent=key||'';$('reasonP').style.display=key?'inline-flex':'none';}
function clearReason(){setReason(null);applyFilters();}
function toggleMyApps(){S.myApps=!S.myApps;$('myAppsC').checked=S.myApps;applyFilters();}
function toggleHideMS(){S.hideMSApps=!S.hideMSApps;$('msFTC').checked=S.hideMSApps;if(!S.hideMSApps&&!S.msLoaded){ensureMSApps().then(function(){S.allItems=S.tabData.enterpriseapp||[];applyFilters();});}else{S.allItems=S.tabData[S.activeTab]||[];applyFilters();}}

function popOF(){var ns={};S.allItems.forEach(function(a){if(a.Owners)a.Owners.forEach(function(o){var n=o.DisplayName||o.UserPrincipalName||'';if(n)ns[n]=true;});});var sel=$('ownerF'),cur=sel.value;while(sel.options.length>3)sel.remove(3);var sep=document.createElement('option');sep.disabled=true;sep.textContent='──────────';sel.appendChild(sep);Object.keys(ns).sort(function(a,b){return a.localeCompare(b,'da');}).forEach(function(n){var o=document.createElement('option');o.value='owner:'+n;o.textContent=n;sel.appendChild(o);});sel.value=cur;if(!sel.value)sel.value='all';}
function popStatusF(){
  var ty=S.activeTab;
  var opts=[['all',t('flt.all')],['action-items',t('st.actionItems')],['marked',t('st.marked')]];
  if(ty==='appregistration'||ty==='enterpriseapp'){opts.push(['pending',t('st.pending')]);}
  opts.push(['privileged',t('st.privileged')]);
  if(ty==='appregistration'||ty==='enterpriseapp'){
    opts.push(['no-live-owner',t('st.noLiveOwner')]);
    opts.push(['owner-disabled',t('st.ownerDisabled')]);
    opts.push(['sole-owner',t('st.soleOwner')]);
    opts.push(['no-context',t('st.noContext')]);
    opts.push(['advisories',t('st.advisories')]);
  }
  if(ty==='appregistration'){opts.push(['expiring',t('st.expiring')]);}
  if(ty==='enterpriseapp'||ty==='managedidentity'||ty==='privilegeduser'){opts.push(['stale',t('st.stale')]);}
  if(ty==='enterpriseapp'){opts.push(['no-ca',t('st.noCa')]);}
  if(ty==='appregistration'&&S.notifyAvailable){
    opts.push(['notify-on',t('st.notifyOn')]);
    opts.push(['notify-off',t('st.notifyOff')]);
    opts.push(['notify-off-expiring',t('st.notifyOffExp')]);
  }
  var sel=$('statusF'),cur=sel.value;
  sel.innerHTML=opts.map(function(o){return'<option value="'+o[0]+'">'+escH(o[1])+'</option>';}).join('');
  sel.value=cur;
  if(!sel.value)sel.value='all';
}

// ── Selection ──
function selCount(){return Object.keys(S.selected).length;}
function updateBulk(){var n=selCount();$('bulkCount').textContent=n;$('bulkBar').classList.toggle('visible',n>0);$('tblC').classList.toggle('multi-sel',n>1);}
function toggleSel(id){if(S.selected[id]){delete S.selected[id];}else{S.selected[id]=true;}updateBulk();var row=document.querySelector('tr[data-id="'+id+'"]');if(row){row.classList.toggle('row-sel',!!S.selected[id]);var cb=row.querySelector('.td-cb input');if(cb)cb.checked=!!S.selected[id];}}
function toggleAll(checked){S.filteredItems.forEach(function(a){if(checked){S.selected[a.AppId]=true;}else{delete S.selected[a.AppId];}});updateBulk();document.querySelectorAll('.td-cb input').forEach(function(cb){cb.checked=checked;});document.querySelectorAll('#tBody tr').forEach(function(r){r.classList.toggle('row-sel',checked);});}
function clearSel(){S.selected={};updateBulk();document.querySelectorAll('.td-cb input').forEach(function(cb){cb.checked=false;});document.querySelectorAll('#tBody tr.row-sel').forEach(function(r){r.classList.remove('row-sel');});var hcb=document.querySelector('.th-cb input');if(hcb)hcb.checked=false;}
function bulkDelete(){var ids=Object.keys(S.selected);if(!ids.length)return;if(!confirm(t('bulk.confirm',{n:ids.length})))return;var done=0;ids.forEach(function(id){var a=S.allItems.find(function(x){return x.AppId===id;});if(!a)return;af(S.apiBase+'/TagApplication',{method:'POST',body:JSON.stringify({appId:id,appName:a.DisplayName,action:'mark'})}).then(function(r){if(!r.ok)return;if(a){a.MarkedForDeletion=true;a.MarkedBy=t('common.you');a.MarkedOn=new Date().toISOString();}}).finally(function(){done++;if(done>=ids.length){clearSel();applyFilters();updateDash();}});});}

// ── Rendering ──
function renderT(){var tb=$('tBody');$('visC').textContent=S.filteredItems.length;if(!S.filteredItems.length){tb.innerHTML='<tr><td colspan="'+(COLS[S.activeTab].length+1)+'"><div class="es">'+t('list.empty')+'</div></td></tr>';return;}
var rows=S.filteredItems.map(function(a){var b='';if(S.activeTab==='appregistration'&&a.HasLinkedSP)b='<span class="link-badge">'+t('list.linkEnt')+'</span>';if(S.activeTab==='enterpriseapp'&&a.HasLinkedAppReg)b='<span class="link-badge">'+t('list.linkReg')+'</span>';
var eUrl=entraUrl(a,S.activeTab);var idLink=eUrl?'<a class="id-link" href="'+eUrl+'" target="_blank" rel="noopener" title="'+escH(t('list.openEntra'))+'">'+escH(a.AppId||'')+ICON_EXT+'</a>':'<code class="id-link">'+escH(a.AppId||'')+'</code>';
var nc='<td title="'+escH(a.DisplayName)+'"><span class="name-cell">'+escH(a.DisplayName)+'</span>'+b+'<br>'+idLink+'</td>';var c;var isSel=!!S.selected[a.AppId];
var cb='<td class="td-cb"><input type="checkbox" '+(isSel?'checked':'')+' onchange="toggleSel(\''+a.AppId+'\')" aria-label="'+escH(t('list.select'))+'"></td>';
if(S.activeTab==='appregistration'){c=cb+nc+'<td>'+rRisk(a)+'</td><td>'+rCtx(a)+'</td><td>'+rOwn(a)+'</td><td>'+rPerms(a)+'</td><td>'+rCreds(a)+'</td><td>'+fD(a.CreatedOn)+'</td>'+(S.notifyAvailable?'<td style="text-align:center">'+rNotify(a)+'</td>':'')+'<td>'+rAct(a)+'</td>';}
else if(S.activeTab==='enterpriseapp'){var tp=a.IsFirstParty?'<span class="ep-badge ep-ms">'+t('list.microsoft')+'</span>':'<span class="ep-badge ep-3p">'+t('list.thirdParty')+'</span>';c=cb+nc+'<td>'+rRisk(a)+'</td><td>'+rCtx(a)+'</td><td>'+rStatus(a)+'</td><td>'+tp+'</td><td>'+rSSO(a)+'</td><td>'+rCA(a)+'</td><td>'+rPerms(a)+'</td><td>'+rOwn(a)+'</td><td>'+fD(a.CreatedOn)+'</td><td>'+rSignIn(a)+'</td><td>'+rAct(a)+'</td>';}
else if(S.activeTab==='privilegeduser'){var rolesHtml=a.DirectoryRoles&&a.DirectoryRoles.length?'<div class="ptags">'+a.DirectoryRoles.map(function(r){return'<span class="ptag '+(r.RiskLevel==='High'?'ptag-h':'ptag-m')+' role-tag">'+escH(r.RoleName)+'</span>';}).join('')+'</div>':'<span class="na">'+t('common.none')+'</span>';var nameC='<td title="'+escH(a.DisplayName)+'"><span class="name-cell">'+escH(a.DisplayName)+'</span><br><a class="id-link" href="'+entraUrl(a,'privilegeduser')+'" target="_blank" rel="noopener" title="'+escH(t('list.openEntra'))+'">'+escH(a.UserPrincipalName||'')+ICON_EXT+'</a>'+(a.JobTitle?'<br><span class="si-sub">'+escH(a.JobTitle)+'</span>':'')+'</td>';c=cb+nameC+'<td>'+rRisk(a)+'</td><td>'+rolesHtml+'</td><td>'+rStatus(a)+'</td><td>'+escH(a.Department||'')+'</td><td>'+fD(a.CreatedOn)+'</td><td>'+rSignIn(a)+'</td><td>'+rAct(a)+'</td>';}
else{var rs=a.AzureResourceId?'<div class="mi-res" title="'+escH(a.AzureResourceId)+'">'+escH(a.AzureResourceId)+'</div>':'<span class="na">'+t('list.noResource')+'</span>';c=cb+nc+'<td>'+rRisk(a)+'</td><td><span class="mi-info">'+escH(a.ManagedIdentityType||t('common.unknown'))+'</span></td><td>'+rStatus(a)+'</td><td>'+rPerms(a)+'</td><td>'+rs+'</td><td>'+fD(a.CreatedOn)+'</td><td>'+rSignIn(a)+'</td><td>'+rAct(a)+'</td>';}
var r=document.createElement('tr');r.setAttribute('data-id',a.AppId);if(a.MarkedForDeletion)r.classList.add('row-m');if(isSel)r.classList.add('row-sel');if(S.detailId===a.AppId)r.classList.add('row-open');r.innerHTML=c;return r;});tb.replaceChildren.apply(tb,rows);}

// Row click opens the details pane, except when the click lands on a control in the row.
document.addEventListener('click',function(e){var tr=e.target.closest('#tBody tr[data-id]');if(!tr)return;if(e.target.closest('button,a,input,label,select,textarea'))return;openDetails(tr.getAttribute('data-id'));});

function updateStats(){var fi=S.filteredItems,ai=S.allItems;$('visC').textContent=fi.length;$('totC').textContent=ai.length;function bd(oid,iid,cnt,cond){if(cond===undefined)cond=true;$(iid).textContent=cnt;$(oid).style.display=cnt&&cond?'inline-flex':'none';}bd('sHR','hrC',fi.filter(function(a){return a.RiskLevel==='High';}).length);bd('sMR','mrC',fi.filter(function(a){return a.RiskLevel==='Medium';}).length);var ownScoped=S.activeTab!=='managedidentity'&&S.activeTab!=='privilegeduser';bd('sNO','noC',fi.filter(function(a){return!a.Owners||!a.Owners.length;}).length,ownScoped);bd('sOD','odC',fi.filter(function(a){return a.Owners&&a.Owners.some(function(o){return o.Enabled===false;});}).length,ownScoped);bd('sSO','soC',fi.filter(function(a){return a.Credentials&&a.Credentials.length&&liveOwners(a).length===1;}).length,ownScoped);bd('sMD','mdC',fi.filter(function(a){return a.MarkedForDeletion;}).length);bd('sEX','exC',fi.filter(function(a){return hasExp(a);}).length);bd('sPC','pcC',fi.filter(function(a){return hasPend(a);}).length);bd('sPV','pvC',fi.filter(function(a){return hasPriv(a);}).length);bd('sMS','msC',S.hideMSApps&&S.activeTab==='enterpriseapp'?ai.filter(function(a){return isMS(a);}).length:0);bd('sST','stC',fi.filter(function(a){return isStale(a);}).length);bd('sCA','caC',fi.filter(function(a){return hasNoCA(a);}).length);$('statsBar').style.display='flex';updatePendingBanner();}

// Pending governance actions are recorded in storage but NOT yet applied in Entra ID —
// they require an admin to run the Tools/Apply-*.ps1 scripts. Make that gap explicit.
function updatePendingBanner(){
  var p=collectPending(),del=0,ren=0,own=0;
  p.forEach(function(x){if(x.kind==='Delete')del++;else if(x.kind==='Rename')ren++;else own++;});
  var total=p.length;var el=$('pendingBanner');
  var nb=$('navPending');nb.textContent=total;nb.style.display=total?'inline-block':'none';
  if(!total){el.classList.remove('visible');return;}
  var parts=[];if(del)parts.push(t('pend.del',{n:del}));if(ren)parts.push(tn('pend.ren',ren));if(own)parts.push(tn('pend.own',own));
  $('pendingBannerText').innerHTML='<strong>'+escH(tn('pend.total',total))+'</strong> &mdash; '+escH(parts.join(', '))+'. '+escH(t('pend.explain'))+' <a href="#" onclick="showView(\'pending\');return false">'+escH(t('pend.viewQueue'))+'</a>';
  el.classList.add('visible');
}

// Render whatever the active tab currently holds.
function renderActive(){S.allItems=S.tabData[S.activeTab]||[];S.filteredItems=S.allItems.slice();buildTH();popOF();popStatusF();applyFilters();$('myAppsT').style.display=(S.activeTab==='appregistration'||S.activeTab==='enterpriseapp')?'inline-flex':'none';}

function exportCSV(){if(!S.filteredItems.length)return;function cc(v){return'"'+String(v==null?'':v).replace(/"/g,'""')+'"';}var h=['displayName','appId','type','risk','reasons','advisories','purpose','system','environment','criticality','owners','roles','perms','creds','created','marked','markedBy'].map(function(k){return t('csv.'+k);});var rows=S.filteredItems.map(function(a){return[cc(a.DisplayName),cc(a.AppId||a.UserPrincipalName),cc(TYPE_SINGULAR[S.activeTab]),cc(tv('risk',a.RiskLevel)),cc((a.RiskReasons||[]).join('; ')),cc((a.Advisories||[]).join('; ')),cc(a.ContextPurpose),cc(a.ContextSystem),cc(a.ContextEnvironment),cc(a.ContextCriticality),cc(gOwn(a)||t('common.none')),cc((a.DirectoryRoles||[]).map(function(r){return r.RoleName;}).join('; ')),cc((a.ApiPermissions||[]).map(function(p){return p.Resource+':'+p.Permission;}).join('; ')),cc((a.Credentials||[]).map(function(c){return c.Type+':'+(c.DisplayName||'')+'('+c.Status+(c.DaysLeft!=null?','+c.DaysLeft+'d':'')+')';}).join('; ')),cc(fD(a.CreatedOn)),cc(a.MarkedForDeletion?t('common.yes'):t('common.no')),cc(a.MarkedBy)].join(',');});var csv=[h.map(cc).join(',')].concat(rows).join('\n');var blob=new Blob(['﻿'+csv],{type:'text/csv;charset=utf-8;'});var a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download='governance-'+S.activeTab+'-'+new Date().toISOString().slice(0,10)+'.csv';a.click();}

// Tooltips are position:fixed so they escape the scrolling table; place them under the tag.
document.addEventListener('mouseover',function(e){var t=e.target.closest('.ctag,.ptag');if(!t)return;var tt=t.querySelector('.ctt,.ptt');if(!tt)return;var r=t.getBoundingClientRect();tt.style.left=Math.min(r.left,window.innerWidth-400)+'px';tt.style.top=(r.bottom+6)+'px';});
// Column resizing
function startR(e,h){e.preventDefault();e.stopPropagation();var th=h.parentElement;th.closest('table').querySelectorAll('th').forEach(function(t){var w=t.offsetWidth;t.style.width=w+'px';t.style.minWidth=w+'px';});S.rs={th:th,sx:e.pageX,sw:th.offsetWidth,h:h};h.classList.add('active');document.addEventListener('mousemove',onR);document.addEventListener('mouseup',stopR);}
function onR(e){if(!S.rs)return;var w=Math.max(60,S.rs.sw+(e.pageX-S.rs.sx));S.rs.th.style.width=w+'px';S.rs.th.style.minWidth=w+'px';}
function stopR(){if(S.rs)S.rs.h.classList.remove('active');S.rs=null;document.removeEventListener('mousemove',onR);document.removeEventListener('mouseup',stopR);}
