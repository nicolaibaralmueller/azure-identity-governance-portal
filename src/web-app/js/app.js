/* Navigation, header menus and start-up. */
var VIEW_TITLE={get overview(){return t('view.overview');},get pending(){return t('view.pending');},get consent(){return t('view.consent');}};

function showView(v){
  S.view=v;document.body.setAttribute('data-view',v);
  document.querySelectorAll('.view').forEach(function(s){s.classList.toggle('active',s.id==='v-'+v);});
  document.querySelectorAll('.nav-item').forEach(function(n){
    var on=v==='list'?n.getAttribute('data-type')===S.activeTab:n.getAttribute('data-view')===v;
    n.classList.toggle('active',on);
    if(on)n.setAttribute('aria-current','page');else n.removeAttribute('aria-current');
  });
  $('bladeName').textContent='| '+(v==='list'?TYPE_LABEL[S.activeTab]:VIEW_TITLE[v]);
  if(v!=='list')closeDetails();
  document.body.classList.remove('nav-open');
  $('content').scrollTop=0;
}
function scrollToCard(id){var el=$(id);if(el)el.scrollIntoView({behavior:'smooth',block:'start'});}

function switchTab(ty){
  var changed=S.activeTab!==ty;
  closeDetails();
  S.activeTab=ty;
  if(changed){S.selected={};S.myApps=false;setReason(null);}
  updateBulk();
  showView('list');
  $('fgOwner').style.display=(ty==='managedidentity'||ty==='privilegeduser')?'none':'inline-flex';
  $('msFT').style.display=ty==='enterpriseapp'?'inline-flex':'none';
  $('fgSSO').style.display=ty==='enterpriseapp'?'inline-flex':'none';
  if(ty!=='enterpriseapp')$('ssoF').value='all';
  $('myAppsT').style.display=(ty==='appregistration'||ty==='enterpriseapp')?'inline-flex':'none';
  $('myAppsC').checked=S.myApps;
  S.allItems=S.tabData[ty]||[];S.filteredItems=S.allItems.slice();
  if(changed){S.sortCol='DisplayName';S.sortDir='asc';}
  popOF();popStatusF();buildTH();applyFilters();
  if(!S.tabLoaded[ty]){
    showLoading(true);$('tblC').style.display='none';
    loadType(ty).then(function(){updateDash();}).catch(function(e){if(S.activeTab===ty)showErr(t('load.couldntType',{type:TYPE_LABEL[ty].toLowerCase(),msg:e.message}));});
  }else{$('tblC').style.display='block';showLoading(false);}
}

// Open a list with a specific set of filters (used by dashboard tiles and links).
function openList(type,opts){
  opts=opts||{};
  $('searchI').value=opts.q||'';
  $('ownerF').value='all';$('riskF').value=opts.risk||'all';
  switchTab(type);
  $('statusF').value=opts.status||'all';if(!$('statusF').value)$('statusF').value='all';
  setReason(opts.reason||null);
  applyFilters();
}

// ── Header ──
function toggleMenu(id,btn){
  var m=$(id),open=!m.classList.contains('open');
  closeMenus();
  if(open){m.classList.add('open');btn.setAttribute('aria-expanded','true');}
}
function closeMenus(){document.querySelectorAll('.menu.open').forEach(function(m){m.classList.remove('open');});document.querySelectorAll('.hdr-btn[aria-expanded="true"]').forEach(function(b){b.setAttribute('aria-expanded','false');});}
document.addEventListener('click',function(e){if(!e.target.closest('.menu,.hdr-btn'))closeMenus();});
document.addEventListener('keydown',function(e){
  if(e.key!=='Escape')return;
  closeMenus();
  var open=['cModal','rnModal','ctxModal','oModal','dModal'].filter(function(id){return $(id).classList.contains('visible');})[0];
  if(open==='cModal')closeModal();else if(open==='rnModal')closeRnModal();else if(open==='ctxModal')closeCtx();else if(open==='oModal')closeOM();else if(open==='dModal')closeDetails();
});
$('globalSearch').addEventListener('keydown',function(e){
  if(e.key!=='Enter')return;
  var q=this.value.trim();
  if(S.view!=='list')switchTab(S.activeTab);
  $('searchI').value=q;applyFilters();
});
function signOut(){window.location.href='/.auth/logout';}

// ── Start-up ──
function init(){
  renderThemePicker();
  showLoading(true);
  fetch('/config.json').then(function(r){if(!r.ok)throw new Error(t('err.config'));return r.json();}).then(function(cfg){S.apiBase=cfg.apiBaseUrl||cfg.apiBase;setLanguage(cfg.language||'en');return fetch('/.auth/me');}).then(function(r){return r.json();}).then(function(meD){
    if(!meD||!meD.length)throw new Error(t('err.noAuth'));
    S.token=meD[0].access_token;if(!S.token)throw new Error(t('err.noToken'));
    var cl=meD[0].user_claims||[];function gN(t){var f=cl.find(function(c){return c.typ===t;});return f?f.val:'';}
    S.curUser.name=gN('name')||meD[0].user_id||'User';
    S.curUser.upn=gN('preferred_username')||gN('http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress')||meD[0].user_id||'';
    var roles=cl.filter(function(c){return c.typ==='roles'||c.typ==='http://schemas.microsoft.com/ws/2008/06/identity/claims/role';}).map(function(c){return c.val;});
    S.isMember=roles.indexOf('Governance.Member')>=0&&roles.indexOf('Governance.Admin')<0;
    if(S.isMember)document.body.classList.add('role-member');
    var role=roles.indexOf('Governance.Admin')>=0?'Governance.Admin':S.isMember?'Governance.Member':t('role.none');

    $('uName').textContent=S.curUser.name;$('uUpn').textContent=S.curUser.upn;$('uRole').textContent=role;$('esRole').textContent=role;
    var parts=S.curUser.name.split(/\s+/).filter(Boolean);$('avatar').textContent=((parts[0]||'?')[0]+(parts.length>1?parts[parts.length-1][0]:'')).toUpperCase();
    var dm=S.curUser.upn.split('@')[1]||'';var tn=dm.split('.')[0]||'Governance';tn=tn.charAt(0).toUpperCase()+tn.slice(1);
    $('tenantName').textContent=tn;$('tenantSub').textContent=tn;$('esTenant').textContent=dm?tn+' ('+dm+')':tn;

    if(S.isMember)switchTab('appregistration');else showView('overview');
    if(!S.isMember)loadConsentData();
    // The Notify column depends on notifyAvailable, but don't block first paint on it —
    // resolve it in the background and re-render once if it turns out to be available.
    loadNotifyConfig();
    requiredTypes().forEach(function(t){var tc=$('tc-'+t);if(tc)tc.textContent='…';});
    return loadActiveThenRest();
  }).catch(function(e){document.documentElement.classList.remove('i18n-pending');showErr(e.message);});
}
init();
