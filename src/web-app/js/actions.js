/* Governance actions (tag, rename, describe, notify, owners) and the details pane.
   Every action only records intent via the API; nothing changes in Entra ID until an
   administrator runs the Tools/Apply-*.ps1 scripts. */
function afterChange(){applyFilters();updateDash();}
function apiFail(e){alert(t('err.failed',{msg:e.message}));}
function postTag(body){return af(S.apiBase+'/TagApplication',{method:'POST',body:JSON.stringify(body)}).then(function(r){if(!r.ok)return r.text().then(function(t){throw new Error(t);});return r;});}

// ── Tag / untag for deletion ──
function promptM(id,n){S.pendAct={appId:id,appName:n,action:'mark'};
  $('mTitle').textContent=S.isMember?t('mod.decomTitle'):t('mod.markTitle');
  $('mBody').innerHTML=t('mod.markBody',{name:escH(n)})+(S.isMember?'<br><br>'+t('mod.decomNote'):'');
  $('mBtn').textContent=S.isMember?t('mod.decomTitle'):t('mod.markTitle');$('cModal').classList.add('visible');}
function promptUM(id,n){S.pendAct={appId:id,appName:n,action:'unmark'};
  $('mTitle').textContent=S.isMember?t('mod.withdrawTitle'):t('mod.removeTagTitle');
  $('mBody').innerHTML=t('mod.unmarkBody',{name:escH(n)});
  $('mBtn').textContent=S.isMember?t('mod.withdrawTitle'):t('mod.removeTag');$('cModal').classList.add('visible');}
function closeModal(){$('cModal').classList.remove('visible');S.pendAct=null;}
function confirmAction(){if(!S.pendAct)return;var b=$('mBtn'),label=b.textContent;b.disabled=true;b.textContent=t('btn.processing');postTag(S.pendAct).then(function(){var a=S.allItems.find(function(x){return x.AppId===S.pendAct.appId;});if(a){if(S.pendAct.action==='mark'){a.MarkedForDeletion=true;a.MarkedBy=t('common.you');a.MarkedOn=new Date().toISOString();}else{a.MarkedForDeletion=false;a.MarkedBy=null;a.MarkedOn=null;}}closeModal();afterChange();}).catch(apiFail).finally(function(){b.disabled=false;b.textContent=label;});}

// ── Expiry notifications ──
function toggleNotify(id,name,enable){
  postTag({appId:id,appName:name,action:enable?'notify':'unnotify'}).then(function(){
    var a=S.allItems.find(function(x){return x.AppId===id;});
    if(a){a.NotifyOnExpiry=enable;}
    afterChange();
  }).catch(apiFail);
}

// ── Describe (owner-supplied context) ──
var ctxApp=null;
function openCtx(id){ctxApp=S.allItems.find(function(x){return x.AppId===id;});if(!ctxApp)return;
  $('ctxAppN').textContent=ctxApp.DisplayName||'';
  $('ctxPurpose').value=ctxApp.ContextPurpose||'';
  $('ctxSystem').value=ctxApp.ContextSystem||'';
  $('ctxEnv').value=ctxApp.ContextEnvironment||'';
  $('ctxCrit').value=ctxApp.ContextCriticality||'';
  $('ctxMeta').textContent=ctxApp.ContextUpdatedBy?t('mod.ctxUpdated',{by:ctxApp.ContextUpdatedBy,on:fD(ctxApp.ContextUpdatedOn)}):t('mod.ctxNotYet');
  $('ctxModal').classList.add('visible');setTimeout(function(){$('ctxPurpose').focus();},100);}
function closeCtx(){$('ctxModal').classList.remove('visible');ctxApp=null;}
function saveCtx(){
  if(!ctxApp)return;
  var b=$('ctxBtn');b.disabled=true;b.textContent=t('btn.saving');
  var payload={appId:ctxApp.AppId,appName:ctxApp.DisplayName,action:'context',
    purpose:$('ctxPurpose').value.trim(),system:$('ctxSystem').value.trim(),
    environment:$('ctxEnv').value,criticality:$('ctxCrit').value};
  postTag(payload).then(function(r){return r.json();}).then(function(d){
    ctxApp.ContextPurpose=payload.purpose;ctxApp.ContextSystem=payload.system;
    ctxApp.ContextEnvironment=payload.environment;ctxApp.ContextCriticality=payload.criticality;
    ctxApp.ContextUpdatedBy=(d&&d.by)||t('common.you');ctxApp.ContextUpdatedOn=(d&&d.date)||new Date().toISOString();
    closeCtx();afterChange();
  }).catch(apiFail).finally(function(){b.disabled=false;b.textContent=t('btn.save');});
}

// ── Request rename ──
var rnAppId=null,rnAppName=null;
function promptRename(id,name){rnAppId=id;rnAppName=name;$('rnCurrent').textContent=t('mod.currentName',{name:name});$('rnInput').value='';$('rnModal').classList.add('visible');setTimeout(function(){$('rnInput').focus();},100);}
function closeRnModal(){$('rnModal').classList.remove('visible');rnAppId=null;rnAppName=null;}
/* Updates both the app registration AND the linked enterprise app in local state */
function submitRename(){var proposed=$('rnInput').value.trim();if(!proposed){alert(t('mod.enterName'));return;}if(proposed===rnAppName){alert(t('mod.sameName'));return;}var btn=$('rnBtn');btn.disabled=true;btn.textContent=t('btn.submitting');postTag({appId:rnAppId,appName:rnAppName,action:'rename',proposedName:proposed}).then(function(){
var now=new Date().toISOString();
var a=S.allItems.find(function(x){return x.AppId===rnAppId;});if(a){a.ProposedName=proposed;a.RenameRequestedBy=t('common.you');a.RenameRequestedOn=now;}
var otherTab=S.activeTab==='appregistration'?'enterpriseapp':S.activeTab==='enterpriseapp'?'appregistration':null;
if(otherTab&&S.tabData[otherTab]){var linked=S.tabData[otherTab].find(function(x){return x.AppId===rnAppId;});if(linked){linked.ProposedName=proposed;linked.RenameRequestedBy=t('common.you');linked.RenameRequestedOn=now;}}
closeRnModal();afterChange();}).catch(apiFail).finally(function(){btn.disabled=false;btn.textContent=t('btn.submitRequest');});}

// ── Owners ──
function openOM(id,name){S.omApp=S.allItems.find(function(a){return a.AppId===id;});if(!S.omApp)return;$('oAppN').textContent=name;$('uSI').value='';$('uSR').innerHTML='';rOL();rPL();$('oModal').classList.add('visible');}
function closeOM(){$('oModal').classList.remove('visible');S.omApp=null;afterChange();}
function rOL(){var a=S.omApp,pd=a.PendingOwnerChanges||[];var rs={};pd.filter(function(p){return p.Action==='remove';}).forEach(function(p){rs[p.TargetUpn]=true;});if(!a.Owners||!a.Owners.length){$('oList').innerHTML='<div class="empty">'+t('own.noOwners')+'</div>';return;}$('oList').innerHTML=a.Owners.map(function(o){var n=escH(o.DisplayName||t('common.unknown')),u=escH(o.UserPrincipalName||''),p=!!rs[o.UserPrincipalName];return'<div class="orow'+(p?' prr':'')+'"><div class="ori"><span class="orn">'+n+(o.Enabled===false?' <span class="oe-badge">'+t('common.left')+'</span>':'')+'</span><span class="oru">'+u+'</span></div>'+(p?'<span class="pl plr">'+t('own.pendingRemoval')+'</span>':'<button class="orb" onclick="reqRO(\''+esc(o.UserPrincipalName)+'\',\''+esc(o.DisplayName||'')+'\')">'+t('own.requestRemoval')+'</button>')+'</div>';}).join('');}
function rPL(){var adds=(S.omApp.PendingOwnerChanges||[]).filter(function(p){return p.Action==='add';});$('pSec').style.display=adds.length?'block':'none';$('pList').innerHTML=adds.map(function(r){return'<div class="orow par"><div class="ori"><span class="orn">'+escH(r.TargetName||r.TargetUpn)+'</span><span class="oru">'+t('common.byOn',{by:escH(r.RequestedBy),on:fD(r.RequestedOn)})+'</span></div><span class="pl pla">'+t('own.pendingAdd')+'</span></div>';}).join('');}
function reqRO(upn,name){if(!S.omApp||!confirm(t('own.confirmRemove',{name:name})))return;af(S.apiBase+'/RequestOwnerChange',{method:'POST',body:JSON.stringify({appId:S.omApp.AppId,appName:S.omApp.DisplayName,action:'remove',targetUpn:upn,targetName:name,targetId:''})}).then(function(r){if(!r.ok)return r.text().then(function(t){throw new Error(t);});if(!S.omApp.PendingOwnerChanges)S.omApp.PendingOwnerChanges=[];S.omApp.PendingOwnerChanges.push({Action:'remove',TargetUpn:upn,TargetName:name,RequestedBy:t('common.you'),RequestedOn:new Date().toISOString()});rOL();rPL();}).catch(apiFail);}
function reqAO(user){if(!S.omApp)return;if((S.omApp.PendingOwnerChanges||[]).some(function(p){return p.Action==='add'&&p.TargetUpn===user.UserPrincipalName;})){alert(t('own.alreadyPending'));return;}af(S.apiBase+'/RequestOwnerChange',{method:'POST',body:JSON.stringify({appId:S.omApp.AppId,appName:S.omApp.DisplayName,action:'add',targetId:user.Id,targetUpn:user.UserPrincipalName,targetName:user.DisplayName})}).then(function(r){if(!r.ok)return r.text().then(function(t){throw new Error(t);});if(!S.omApp.PendingOwnerChanges)S.omApp.PendingOwnerChanges=[];S.omApp.PendingOwnerChanges.push({Action:'add',TargetUpn:user.UserPrincipalName,TargetName:user.DisplayName,RequestedBy:t('common.you'),RequestedOn:new Date().toISOString()});$('uSI').value='';$('uSR').innerHTML='';rOL();rPL();}).catch(apiFail);}
function debUS(){clearTimeout(S.usTimer);S.usTimer=setTimeout(doUS,400);}
function doUS(){var q=$('uSI').value.trim(),c=$('uSR');if(q.length<2){c.innerHTML='';return;}c.innerHTML='<div class="ssp"></div>';af(S.apiBase+'/SearchUsers?q='+encodeURIComponent(q)).then(function(r){return r.json();}).then(function(u){var l=Array.isArray(u)?u:u?[u]:[];S.userResults=l;if(!l.length){c.innerHTML='<div class="sem">'+t('own.noUsers')+'</div>';return;}c.innerHTML='<div class="sr">'+l.map(function(u,i){return'<div class="sri" onclick="reqAO(S.userResults['+i+'])"><span class="srn">'+escH(u.DisplayName||'')+'</span><br><span class="sru">'+escH(u.UserPrincipalName||'')+'</span>'+(u.JobTitle?'<br><span class="srt">'+escH(u.JobTitle)+'</span>':'')+'</div>';}).join('')+'</div>';}).catch(function(){c.innerHTML='<div class="sem">'+t('own.searchFailed')+'</div>';});}

// ── Details pane ──
function kv(label,val){return val==null||val===''?'':'<div class="kv"><dt>'+escH(label)+'</dt><dd>'+val+'</dd></div>';}
function openDetails(id){S.detailId=id;refreshDetails();$('dModal').classList.add('visible');document.querySelectorAll('#tBody tr').forEach(function(r){r.classList.toggle('row-open',r.getAttribute('data-id')===id);});}
function closeDetails(){S.detailId=null;$('dModal').classList.remove('visible');document.querySelectorAll('#tBody tr.row-open').forEach(function(r){r.classList.remove('row-open');});}
function refreshDetails(){
  var ty=S.activeTab,a=findItem(S.detailId,ty);
  if(!a){closeDetails();return;}
  var appLike=ty==='appregistration'||ty==='enterpriseapp';
  var en=esc(a.DisplayName),h='';
  $('dName').textContent=a.DisplayName||'';
  $('dType').textContent=TYPE_SINGULAR[ty]+(a.IsFirstParty?' · Microsoft':'');

  // Risk
  h+='<div class="d-sec">'+t('det.risk')+'</div><span class="rb '+riskClass(a.RiskLevel)+'">'+escH(tv('risk',a.RiskLevel))+'</span>';
  if(a.RiskReasons&&a.RiskReasons.length)h+='<ul class="d-list" style="margin-top:6px">'+a.RiskReasons.map(function(r){return'<li>'+escH(r)+'</li>';}).join('')+'</ul>';
  if(a.Advisories&&a.Advisories.length)h+='<div class="d-sec">'+t('det.advisories')+'</div>'+a.Advisories.map(function(x){return'<div class="adv">'+escH(x)+'</div>';}).join('');

  // Essentials
  h+='<div class="d-sec">'+t('det.essentials')+'</div><dl>';
  if(ty==='privilegeduser'){h+=kv(t('det.upn'),escH(a.UserPrincipalName))+kv(t('det.jobTitle'),escH(a.JobTitle))+kv(t('det.department'),escH(a.Department));}
  else h+=kv(ty==='managedidentity'?t('det.clientId'):t('det.appId'),'<code>'+escH(a.AppId)+'</code>');
  if(a.ObjectId)h+=kv(t('det.objectId'),'<code>'+escH(a.ObjectId)+'</code>');
  if(ty!=='appregistration')h+=kv(t('det.status'),rStatus(a));
  if(ty==='managedidentity'){h+=kv(t('det.type'),escH(a.ManagedIdentityType||t('common.unknown')))+kv(t('det.azureResource'),a.AzureResourceId?'<span class="mi-res">'+escH(a.AzureResourceId)+'</span>':'<span class="na">'+t('list.noResource')+'</span>');}
  if(ty==='enterpriseapp'){h+=kv(t('det.sso'),rSSO(a))+kv(t('det.ca'),rCA(a)+((a.CAPolicies||[]).length?'<div class="si-sub">'+a.CAPolicies.map(escH).join('<br>')+'</div>':''));}
  if(ty==='appregistration'&&a.HasLinkedSP)h+=kv(t('det.linked'),t('det.linkedEnt'));
  if(ty==='enterpriseapp'&&a.HasLinkedAppReg)h+=kv(t('det.linked'),t('det.linkedReg'));
  h+=kv(t('det.created'),escH(fD(a.CreatedOn)));
  if(ty!=='appregistration')h+=kv(t('det.lastSignIn'),rSignIn(a));
  h+='</dl>';

  // Owners
  if(appLike){
    h+='<div class="d-sec">'+t('det.owners')+'</div>';
    if(a.Owners&&a.Owners.length){h+='<ul class="d-list">'+a.Owners.map(function(o){var gone=o.Enabled===false;return'<li><span'+(gone?' class="oe-gone"':'')+'>'+escH(o.DisplayName||t('common.unknown'))+'<br><span class="oupn">'+escH(o.UserPrincipalName||'')+'</span></span>'+(gone?'<span class="oe-badge">'+t('common.left')+'</span>':'')+'</li>';}).join('')+'</ul>';if(!liveOwners(a).length)h+='<span class="no-own">'+t('own.noActive')+'</span>';}
    else h+='<span class="no-own">'+t('own.none')+'</span>';
    var pd=a.PendingOwnerChanges||[];
    if(pd.length)h+='<div class="pi">'+pd.map(function(p){return'<span class="pit '+(p.Action==='add'?'pa':'pr')+'">'+(p.Action==='add'?t('own.add'):t('own.remove'))+' '+escH(p.TargetName||p.TargetUpn)+' '+t('own.pendingSuffix')+'</span>';}).join('')+'</div>';
  }

  // Credentials
  if(a.Credentials&&a.Credentials.length){
    h+='<div class="d-sec">'+t('det.credentials')+'</div><ul class="d-list">'+a.Credentials.slice().sort(function(x,y){return(x.DaysLeft==null?1e9:x.DaysLeft)-(y.DaysLeft==null?1e9:y.DaysLeft);}).map(function(c){
      var cls=c.Status==='Expired'?'high':c.Status==='Expiring'?'med':c.Status==='Valid'?'ok':'neutral';
      var dl=c.DaysLeft==null?'':c.DaysLeft<0?tn('cred.expiredAgo',Math.abs(c.DaysLeft)):tn('cred.left',c.DaysLeft);
      return'<li><span>'+escH(tv('cred',c.Type))+' &middot; '+escH(c.DisplayName||t('common.unnamed'))+'<br><span class="si-sub">'+escH(c.EndDateTime?t('cred.expires',{d:fD(c.EndDateTime)}):t('cred.noEnd'))+(dl?' ('+escH(dl)+')':'')+'</span></span><span class="pill '+cls+'">'+escH(tv('credstatus',c.Status||'Unknown'))+'</span></li>';
    }).join('')+'</ul>';
  }

  // Permissions
  if((a.DirectoryRoles||[]).length||(a.ApiPermissions||[]).length){
    h+='<div class="d-sec">'+t('det.rolesPerms')+'</div><ul class="d-list">';
    (a.DirectoryRoles||[]).forEach(function(r){h+='<li><span>'+t('perm.dirRole')+' &middot; '+escH(r.RoleName)+'</span><span class="pill '+(r.RiskLevel==='High'?'high':'med')+'">'+escH(tv('risk',r.RiskLevel))+'</span></li>';});
    (a.ApiPermissions||[]).forEach(function(p){h+='<li><span>'+escH(p.Resource)+' &middot; '+escH(p.Permission)+'</span><span class="pill '+(p.RiskLevel==='High'?'high':p.RiskLevel==='Medium'?'med':'neutral')+'">'+escH(tv('risk',p.RiskLevel))+'</span></li>';});
    h+='</ul>';
  }

  // Context
  if(appLike){
    var tags=ctxTags(a);
    h+='<div class="d-sec">'+t('det.context')+'</div>';
    if(a.ContextPurpose||tags.length){if(a.ContextPurpose)h+='<p class="d-text">'+escH(a.ContextPurpose)+'</p>';if(tags.length)h+='<div class="ctx-tags">'+tags.join('')+'</div>';if(a.ContextUpdatedBy)h+='<div class="card-note">'+t('det.ctxUpdated',{by:escH(a.ContextUpdatedBy),on:fD(a.ContextUpdatedOn)})+'</div>';}
    else h+='<p class="d-text">'+t('det.ctxNone')+'</p>';
  }

  // Governance
  h+='<div class="d-sec">'+t('det.governance')+'</div><dl>';
  h+=kv(t('det.deletion'),a.MarkedForDeletion?'<span class="pill high">'+(S.isMember?t('act.decomRequested'):t('det.marked'))+'</span> '+t('common.byOn',{by:escH(a.MarkedBy||t('common.unknown')),on:fD(a.MarkedOn)}):t('det.notMarked'));
  if(a.ProposedName)h+=kv(t('act.renameRequested'),escH(a.ProposedName)+'<div class="si-sub">'+t('common.byOn',{by:escH(a.RenameRequestedBy||t('common.unknown')),on:fD(a.RenameRequestedOn)})+'</div>');
  if(ty==='appregistration'&&S.notifyAvailable)h+=kv(t('det.expiryNotify'),rNotify(a));
  h+='</dl>';
  $('dBody').innerHTML=h;

  // Actions
  var act='<a class="mbtn mbtn-p" style="display:inline-flex;align-items:center;text-decoration:none" href="'+entraUrl(a,ty)+'" target="_blank" rel="noopener">'+t('act.openEntra')+'</a>';
  if(appLike)act+='<button class="mbtn own-action" onclick="openOM(\''+a.AppId+'\',\''+en+'\')">'+t('act.editOwners')+'</button>';
  if(appLike)act+='<button class="mbtn" onclick="openCtx(\''+a.AppId+'\')">'+(a.ContextPurpose||a.ContextSystem?t('act.editContext'):t('ctx.describe'))+'</button>';
  if(appLike&&!a.ProposedName)act+='<button class="mbtn" onclick="promptRename(\''+a.AppId+'\',\''+en+'\')">'+t('act.requestRename')+'</button>';
  act+=a.MarkedForDeletion?'<button class="mbtn" onclick="promptUM(\''+a.AppId+'\',\''+en+'\')">'+(S.isMember?t('act.withdraw'):t('act.removeTag'))+'</button>'
                          :'<button class="mbtn" onclick="promptM(\''+a.AppId+'\',\''+en+'\')">'+(S.isMember?t('act.requestDecom'):t('act.tagDelete'))+'</button>';
  $('dActions').innerHTML=act;
}
