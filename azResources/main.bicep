// ============================================================================
// Identity Governance - Main Infrastructure Template
// ============================================================================
// Parameterized so the solution can be provisioned in any tenant /
// subscription / resource group.
//
// Deploys: Storage Account (+ tables), App Service Plans, Function App (API),
//          Web App (portal), Application Insights (+ optional Log Analytics),
//          optional Key Vault. RBAC for the Function App managed identity is
//          granted afterwards by the Setup/ scripts.
// ============================================================================

@description('Base name for all resources, e.g. "idgov"')
param appName string

@description('Environment identifier')
@allowed(['dev', 'tst', 'acc', 'prd'])
param environment string

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Function App (API) name')
param functionAppName string = '${appName}-api-${environment}'

@description('Web App (portal) name')
param webAppName string = '${appName}-portal-${environment}'

@description('Shared App Service plan name (hosts both the Function App and the Web App)')
param appPlanName string = 'asp-${appName}-${environment}'

@description('Storage Account name (3-24 lowercase alphanumeric, globally unique)')
param storageAccountName string = toLower('${take(replace(appName, '-', ''), 13)}${take(uniqueString(resourceGroup().id), 6)}${environment}')

@description('SKU for the shared App Service plan. B2 = Basic dedicated, 2 vCPU / 3.5 GB, always-warm — sized to host both apps on one plan (~same cost as two B1). B1 if co-hosting a light load; Y1 is consumption (cold start) and not used for the dedicated, always-on design.')
@allowed(['Y1','B1', 'B2'])
param appPlanSku string = 'B2'

@description('PowerShell worker processes per Function App instance. Microsoft recommends starting at the plan\'s core count (B2 = 2).')
@minValue(1)
@maxValue(10)
param functionWorkerProcessCount int = 2

@description('Concurrent PowerShell runspaces per worker process, i.e. how many requests each process handles at once.')
@minValue(1)
@maxValue(50)
param psWorkerConcurrency int = 10

@description('Storage Account SKU')
param storageSku string = 'Standard_LRS'

@description('Linux runtime stack for the portal site')
param portalLinuxFxVersion string = 'NODE|24-lts'

@description('Startup command serving the static portal from wwwroot')
param portalStartupCommand string = 'pm2 serve /home/site/wwwroot 8080 --no-daemon --spa'

@description('''Optional. CIDR ranges allowed to reach the PORTAL site (e.g. ["203.0.113.10/32","198.51.100.0/24"]).
When this or portalFrontDoorId is set, all other inbound traffic to the portal is denied. When both are empty
(default), the portal is open to all networks. SCM/Kudu has its own rules (scmAllowedServiceTags).''')
param portalAllowedIpRanges array = []

@description('''Optional. ID of the Front Door profile allowed to reach the PORTAL site (the profile's frontDoorId, a GUID).
Adds an Allow rule for the AzureFrontDoor.Backend service tag that only matches requests whose X-Azure-FDID header
carries this ID, so no other customer's Front Door gets through. Empty (default) = no Front Door rule.''')
param portalFrontDoorId string = ''

@description('''Optional. CIDR ranges allowed to reach the API (Function App). The portal SPA calls the API from the
user's browser, so this is the users' egress IP range (not Front Door). Same semantics as portalAllowedIpRanges:
empty (default) = open to all networks. Timer triggers are unaffected.''')
param apiAllowedIpRanges array = []

@description('''Optional. Service tags allowed to reach the SCM/Kudu endpoint of both sites (e.g. ["AzureCloud"] for
hosted CI/CD agents). Empty (default) = SCM stays unrestricted.''')
param scmAllowedServiceTags array = []

@description('Optional. Extra CIDR ranges (e.g. your admin network) allowed to SCM/Kudu. Only applied when scmAllowedServiceTags is non-empty.')
param scmAllowedIpRanges array = []

@description('''Optional. Public host name of the portal when it is published through Front Door,
e.g. "identity.contoso.com". Used for CORS and PORTAL_URL. Empty = the default azurewebsites.net host.''')
param portalPublicHostName string = ''

@description('''Make EasyAuth honour the X-Forwarded-Host header (forwardProxy convention "Standard") so sign-in redirects
go to the Front Door host instead of azurewebsites.net. Enable only when the sites sit behind a reverse proxy.''')
param authForwardProxy bool = false

@description('''Let the portal's EasyAuth sign in with a user-assigned managed identity (federated identity credential on the
app registration) instead of a client secret. Creates the identity and the OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID setting.
The federated credential itself is added after the first deploy (Setup/Configure-AuthAppRegistration.ps1 -ManagedIdentityPrincipalId, see docs/setup-guide.md).
False (default) keeps the client-secret setting MICROSOFT_PROVIDER_AUTHENTICATION_SECRET.''')
param authUseManagedIdentity bool = false

@description('Enable Key Vault purge protection. Cannot be disabled again once enabled; use in prd only.')
param enablePurgeProtection bool = false

@description('Resource ID of an existing Log Analytics workspace for Application Insights. Empty = create a dedicated workspace in this resource group.')
param logAnalyticsWorkspaceId string = ''

@description('''Disable instrumentation-key (local) auth on Application Insights and make the Function App
ingest telemetry with its managed identity instead. DEFAULT FALSE — do NOT enable until the Function App
identity holds Monitoring Metrics Publisher on the component (Setup/Assign-AzureRbac.ps1). Enabling this
before the role exists makes the host stall on rejected telemetry. Order: deploy (false) -> run Assign-AzureRbac.ps1
-> set this true and redeploy.''')
param disableAppInsightsLocalAuth bool = false

@description('''Deploy a Key Vault for application secrets added by hand. Off by default: the solution needs none
(mail uses Azure Communication Services and EasyAuth can use a federated credential, both with managed identities).
Turning it off later does not delete an existing vault (incremental deployment).''')
param deployKeyVault bool = false

@description('Key Vault name (3-24 chars, globally unique)')
param keyVaultName string = toLower('kv${take(replace(appName, '-', ''), 13)}${take(uniqueString(resourceGroup().id), 4)}${environment}')

@description('''Endpoint of the Azure Communication Services resource that sends notification mail, e.g.
"https://<resource>.<geo>.communication.azure.com". The Function App authenticates with its managed identity, which
needs a mail-sender role on that resource (Setup/Assign-CommunicationServicesRole.ps1). Empty = mail disabled.''')
param acsEndpoint string = ''

@description('''Sender (MailFrom) address on a domain connected to that Communication Services resource,
e.g. "DoNotReply@contoso.com". The display name is configured on the sender in the email domain. Empty = mail disabled.''')
param mailSenderAddress string = ''

@description('''Optional. Mailbox(es) copied on post-expiry escalations, semicolon or comma separated —
typically the identity governance coordinator or a team distribution list. This is also the ONLY
recipient when an app with an expired credential has no active owner left to tell, so leaving it
empty means orphaned apps expire silently.''')
param governanceEscalationTo string = ''

@description('Maximum client-secret lifetime the organisation allows, in days. Secrets issued for longer are flagged as an advisory (not a risk). 365 = 12 months.')
param secretMaxLifetimeDays int = 365

@description('''Language of the portal and of every notification e-mail: en (English) or da (Danish). One language per
deployment. Risk reasons and advisories switch language on the next sync run after a change.''')
@allowed(['en', 'da'])
param language string = 'en'

@description('''Entra app registration (client) ID used for App Service Authentication (EasyAuth) on BOTH the portal and the API.
Create this app registration manually first (it is a tenant-level object). When set, the API rejects all unauthenticated
calls (HTTP 401) and only accepts tokens issued to this app; when empty, EasyAuth is NOT deployed and both sites stay public.''')
param authClientId string = ''

@description('''Scope the portal requests so its access token is valid against the API. Leave empty to default to
"api://<authClientId>/user_impersonation" (requires an "Expose an API" scope of that name on the app registration).''')
param authApiScope string = ''

// ============================================================================
// Variables
// ============================================================================

var appInsightsName = '${appName}-AppInsights-${environment}'
var logAnalyticsName = 'log-${appName}-${environment}'

// Tables used by the Function App
var tableNames = [
  'AppOwnerRequests'
  'AuditLog'
  'GovernanceState'
  'IdentityCache'
  'NotificationLog'
  'TenantConfig'
]

// Note: RBAC role assignments for the Function App identity (Storage Table Data
// Contributor, Storage Blob Data Owner, Monitoring Metrics Publisher) are NOT created here.
// The deploying principal typically only has Contributor, which cannot write role
// assignments. They are granted by Setup/Assign-AzureRbac.ps1 (privileged operator)
// after the first infrastructure deploy.

// App Service Authentication (EasyAuth) — only deployed when a client ID is supplied
var enableAuth = !empty(authClientId)
var authOpenIdIssuer = '${az.environment().authentication.loginEndpoint}${tenant().tenantId}/v2.0'
var resolvedApiScope = empty(authApiScope) ? 'api://${authClientId}/user_impersonation' : authApiScope

// Portal EasyAuth credential: managed identity (federated credential) or client secret app setting
var portalAuthCredentialSettingName = authUseManagedIdentity ? 'OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID' : 'MICROSOFT_PROVIDER_AUTHENTICATION_SECRET'
var portalIdentityName = 'id-${appName}-portal-${environment}'

// Reverse proxy (Front Door): honour X-Forwarded-Host for sign-in redirects
var authHttpSettings = authForwardProxy ? {
  httpSettings: {
    forwardProxy: {
      convention: 'Standard'
    }
  }
} : {}

// Portal inbound rules: our Front Door profile (service tag + X-Azure-FDID), then any CIDR ranges.
// Any rule present = deny everything else; no rules = open to all networks.
var portalFrontDoorRules = empty(portalFrontDoorId) ? [] : [
  {
    ipAddress: 'AzureFrontDoor.Backend'
    tag: 'ServiceTag'
    action: 'Allow'
    priority: 100
    name: 'FrontDoor'
    headers: {
      'x-azure-fdid': [
        portalFrontDoorId
      ]
    }
  }
]
var portalIpRules = map(range(0, length(portalAllowedIpRanges)), i => {
  ipAddress: portalAllowedIpRanges[i]
  action: 'Allow'
  priority: (200 + i)
  name: 'Allowed-${i}'
})
var portalIpSecurityRestrictions = concat(portalFrontDoorRules, portalIpRules)

// SCM/Kudu restrictions - only applied when service tags are given, otherwise SCM stays open
var scmSiteConfig = empty(scmAllowedServiceTags) ? {} : {
  scmIpSecurityRestrictionsUseMain: false
  scmIpSecurityRestrictionsDefaultAction: 'Deny'
  scmIpSecurityRestrictions: concat(
    map(range(0, length(scmAllowedServiceTags)), i => {
      ipAddress: scmAllowedServiceTags[i]
      tag: 'ServiceTag'
      action: 'Allow'
      priority: 100 + i
      name: 'ScmTag-${i}'
    }),
    map(range(0, length(scmAllowedIpRanges)), i => {
      ipAddress: scmAllowedIpRanges[i]
      action: 'Allow'
      priority: 200 + i
      name: 'ScmIp-${i}'
    })
  )
}

// ============================================================================
// Log Analytics Workspace (only when no central workspace is supplied)
// ============================================================================

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = if (empty(logAnalyticsWorkspaceId)) {
  name: logAnalyticsName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// ============================================================================
// Application Insights
// ============================================================================

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: empty(logAnalyticsWorkspaceId) ? logAnalytics.id : logAnalyticsWorkspaceId
    IngestionMode: 'LogAnalytics'
    RetentionInDays: 90
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    // Reject instrumentation-key (local) auth for telemetry ingestion so only Entra-
    // authenticated principals may write. Gated behind disableAppInsightsLocalAuth (default
    // false) because it REQUIRES the Function App identity to already hold Monitoring Metrics
    // Publisher (Setup/Assign-AzureRbac.ps1); enabling it first makes the host stall on
    // rejected telemetry. Flip the parameter to true only after the role is granted.
    DisableLocalAuth: disableAppInsightsLocalAuth
  }
}

// ============================================================================
// Storage Account with Tables
// ============================================================================

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: storageSku
  }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    defaultToOAuthAuthentication: true
    accessTier: 'Hot'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}

resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource tables 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' = [
  for tableName in tableNames: {
    parent: tableService
    name: tableName
  }
]

// ============================================================================
// App Service Plan (shared)
// ============================================================================
// One Linux dedicated plan hosts BOTH the Function App and the Web App. The portal
// is a near-idle static site, so pooling its capacity with the API/timer workload on a
// single B2 (2 vCPU / 3.5 GB) gives the Function App real headroom for the sync + the
// parallel tab loads — at roughly the same cost as two separate B1 plans. Always On is
// set on both apps to keep them warm (no PowerShell cold start).

resource appPlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: appPlanName
  location: location
  kind: 'linux'
  sku: {
    name: appPlanSku
  }
  properties: {
    reserved: true // Linux dedicated
  }
}

// ============================================================================
// User-assigned identity for the portal's EasyAuth (optional)
// ============================================================================
// Used ONLY as the federated credential on the app registration (no client secret).
// Microsoft: assign it to no other resource, or that resource can act as the app registration.

resource portalIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (authUseManagedIdentity) {
  name: portalIdentityName
  location: location
}

// ============================================================================
// Web App (portal, static frontend served by Node)
// ============================================================================

resource webApp 'Microsoft.Web/sites@2023-12-01' = {
  name: webAppName
  location: location
  kind: 'app,linux'
  identity: authUseManagedIdentity ? {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${portalIdentity.id}': {}
    }
  } : {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appPlan.id
    httpsOnly: true
    clientAffinityEnabled: false
    // appSettings are only declared when the managed-identity credential is used: declaring them is a full
    // replace and would wipe a manually set MICROSOFT_PROVIDER_AUTHENTICATION_SECRET in client-secret mode.
    siteConfig: union({
      linuxFxVersion: portalLinuxFxVersion
      appCommandLine: portalStartupCommand
      alwaysOn: true
      ftpsState: 'FtpsOnly'
      minTlsVersion: '1.3'
      scmMinTlsVersion: '1.3'
      // Front Door rule and/or CIDR rules (see portalIpSecurityRestrictions). With any rule the
      // default is Deny; with none the portal is open to all networks.
      ipSecurityRestrictionsDefaultAction: empty(portalIpSecurityRestrictions) ? 'Allow' : 'Deny'
      ipSecurityRestrictions: portalIpSecurityRestrictions
    }, scmSiteConfig, authUseManagedIdentity ? {
      appSettings: [
        { name: 'OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID', value: portalIdentity!.properties.clientId }
      ]
    } : {})
  }
}

// Host the browser uses for the portal: the Front Door host when published, else the default host
var portalHostName = empty(portalPublicHostName) ? webApp.properties.defaultHostName : portalPublicHostName

// ============================================================================
// Function App (API)
// ============================================================================

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appPlan.id
    httpsOnly: true
    clientAffinityEnabled: false
    reserved: true // Linux
    keyVaultReferenceIdentity: 'SystemAssigned'
    siteConfig: union({
      // AlwaysOn keeps one instance permanently warm on the dedicated plan,
      // which is what eliminates the PowerShell cold start. It is only honoured on
      // Dedicated/Premium plans (ignored on Consumption).
      linuxFxVersion: 'PowerShell|7.6'
      alwaysOn: true
      use32BitWorkerProcess: false // 64-bit worker
      ftpsState: 'FtpsOnly'
      minTlsVersion: '1.3'
      scmMinTlsVersion: '1.3'
      // Same loop as the portal: empty apiAllowedIpRanges = open to all networks.
      ipSecurityRestrictions: map(range(0, length(apiAllowedIpRanges)), i => {
        ipAddress: apiAllowedIpRanges[i]
        action: 'Allow'
        priority: (100 + i)
        name: 'Allowed-${i}'
      })
      cors: {
        allowedOrigins: [
          'https://${portalHostName}'
          'https://portal.azure.com'
        ]
        supportCredentials: true
      }
      appSettings: concat([
        // Host storage via managed identity (no secret). Requires Storage Blob Data
        // Owner on the storage account (granted by Setup/Assign-AzureRbac.ps1).
        { name: 'AzureWebJobsStorage__accountName', value: storageAccount.name }
        { name: 'AzureWebJobsStorage__blobServiceUri', value: 'https://${storageAccount.name}.blob.${az.environment().suffixes.storage}/' }
        { name: 'AzureWebJobsStorage__queueServiceUri', value: 'https://${storageAccount.name}.queue.${az.environment().suffixes.storage}/' }
        { name: 'AzureWebJobsStorage__tableServiceUri', value: 'https://${storageAccount.name}.table.${az.environment().suffixes.storage}/' }
        // WEBSITE_CONTENTAZUREFILECONNECTIONSTRING / WEBSITE_CONTENTSHARE are only
        // required on Consumption/Elastic Premium (Azure Files content share). On the
        // dedicated plan the app content lives on the plan, so they are omitted —
        // which also lets host storage stay fully managed-identity based.
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'powershell' }
        // Parallel request handling. Without these, the portal's start-up calls queued behind
        // one another (a ~1 ms GetNotifyConfig measured 4 s median). The function code keeps no
        // shared state (no Az context, globals or files), so concurrent runspaces are safe.
        { name: 'FUNCTIONS_WORKER_PROCESS_COUNT', value: string(functionWorkerProcessCount) }
        { name: 'PSWorkerInProcConcurrencyUpperBound', value: string(psWorkerConcurrency) }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        // Mail via Azure Communication Services (Entra ID, managed identity — no key or secret).
        // The mail timers skip their run while either value is empty.
        { name: 'ACS_ENDPOINT', value: acsEndpoint }
        { name: 'MAIL_FROM',    value: mailSenderAddress }
        // Post-expiry escalation target and the secret-lifetime standard advisories are judged
        // against. Both are plain settings — neither is a secret.
        { name: 'GOVERNANCE_ESCALATION_TO', value: governanceEscalationTo }
        { name: 'SECRET_MAX_LIFETIME_DAYS', value: string(secretMaxLifetimeDays) }
        // Language for e-mails and server-generated texts. deploy.ps1 copies it into the portal's config.json.
        { name: 'LANGUAGE', value: language }
        // Deep link used by the monthly owner digest to send people back to the portal.
        { name: 'PORTAL_URL', value: 'https://${portalHostName}' }
      ], disableAppInsightsLocalAuth ? [
        // Authenticate telemetry ingestion with the managed identity (Entra) instead of the
        // instrumentation key. Added ONLY when local auth is disabled on the component, which is
        // valid only once the Function App identity holds Monitoring Metrics Publisher (Assign-AzureRbac.ps1).
        { name: 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING', value: 'Authorization=AAD' }
      ] : [])
    }, scmSiteConfig)
  }
}

// ============================================================================
// Disable basic publishing credentials (FTP / SCM) on both sites
// ============================================================================

resource functionAppFtpPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2023-12-01' = {
  parent: functionApp
  name: 'ftp'
  properties: {
    allow: false
  }
}

resource functionAppScmPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2023-12-01' = {
  parent: functionApp
  name: 'scm'
  properties: {
    allow: false
  }
}

resource webAppFtpPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2023-12-01' = {
  parent: webApp
  name: 'ftp'
  properties: {
    allow: false
  }
}

resource webAppScmPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2023-12-01' = {
  parent: webApp
  name: 'scm'
  properties: {
    allow: false
  }
}

// ============================================================================
// App Service Authentication (EasyAuth)
// ============================================================================
// API: reject every unauthenticated call with 401 (no login redirect). Only
//      tokens issued to the portal app registration are accepted, so only
//      signed-in portal users can execute functions. Timer triggers do not
//      traverse HTTP auth and are unaffected.
// Portal: redirect anonymous users to sign in and keep an access token in the
//      token store so the SPA can call the API on the user's behalf.
// Deployed only when authClientId is supplied; otherwise both sites stay public.
// ============================================================================

resource functionAppAuth 'Microsoft.Web/sites/config@2023-12-01' = if (enableAuth) {
  parent: functionApp
  name: 'authsettingsV2'
  properties: {
    platform: {
      enabled: true
    }
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'Return401'
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          openIdIssuer: authOpenIdIssuer
          clientId: authClientId
        }
        validation: {
          defaultAuthorizationPolicy: {
            allowedApplications: [
              authClientId
            ]
          }
          allowedAudiences: [
            'api://${authClientId}'
            authClientId
          ]
        }
      }
    }
    login: {
      tokenStore: {
        enabled: true
      }
    }
  }
}

resource webAppAuth 'Microsoft.Web/sites/config@2023-12-01' = if (enableAuth) {
  parent: webApp
  name: 'authsettingsV2'
  properties: union({
    platform: {
      enabled: true
    }
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'RedirectToLoginPage'
      redirectToProvider: 'azureactivedirectory'
      // Probe path for Front Door. pm2 --spa answers it with index.html (200), no data.
      excludedPaths: [
        '/health/live'
      ]
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          openIdIssuer: authOpenIdIssuer
          clientId: authClientId
          // EasyAuth needs a client credential to redeem the auth code for an ACCESS token
          // (without it only an id_token is issued and /.auth/me has no access_token).
          // Managed-identity mode: a federated credential, no secret. Otherwise the client secret
          // lives in MICROSOFT_PROVIDER_AUTHENTICATION_SECRET — created manually, not in source.
          clientSecretSettingName: portalAuthCredentialSettingName
        }
        login: {
          loginParameters: [
            'scope=openid profile email ${resolvedApiScope}'
          ]
        }
      }
    }
    login: {
      tokenStore: {
        enabled: true
      }
    }
  }, authHttpSettings)
}

// ============================================================================
// Key Vault (optional)
// ============================================================================
// Secret values are added manually after deployment - they cannot be provisioned
// from source control. Mail no longer needs one (Azure Communication Services, Entra ID).
// The Function App identity gets no role on it from Setup/Assign-AzureRbac.ps1: when you
// enable the vault and add a secret, grant Key Vault Secrets User on the vault by hand.
// ============================================================================

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = if (deployKeyVault) {
  name: keyVaultName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: tenant().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    // Purge protection can only be turned on, never off, so it is omitted unless enabled.
    enablePurgeProtection: enablePurgeProtection ? true : null
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'None'
      defaultAction: 'Allow'
    }
  }
}

// ============================================================================
// Outputs — consumed by deploy.ps1 (config.json injection) and Setup scripts
// ============================================================================

output functionAppName string = functionApp.name
output functionAppHostName string = functionApp.properties.defaultHostName
output functionAppUrl string = 'https://${functionApp.properties.defaultHostName}/api'
output functionAppPrincipalId string = functionApp.identity.principalId
output webAppName string = webApp.name
output webAppHostName string = webApp.properties.defaultHostName
output webAppUrl string = 'https://${webApp.properties.defaultHostName}'
output storageAccountName string = storageAccount.name
output appInsightsName string = appInsights.name
output keyVaultName string = deployKeyVault ? keyVault.name : ''
output easyAuthEnabled bool = enableAuth
output portalPublicUrl string = 'https://${portalHostName}'
// Not secrets: needed for the federated credential on the app registration
output portalIdentityClientId string = authUseManagedIdentity ? portalIdentity!.properties.clientId : ''
output portalIdentityPrincipalId string = authUseManagedIdentity ? portalIdentity!.properties.principalId : ''
