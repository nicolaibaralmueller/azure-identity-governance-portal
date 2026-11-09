using namespace System.Net
param($Request, $TriggerMetadata)

# Directory search backs the admin owner-edit modal only — members are view-only.
$caller = Get-Caller -Request $Request
if (-not $caller.IsAdmin) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::Forbidden; Body = '{"error":"This action requires the Governance.Admin role."}'; Headers = @{ "Content-Type" = "application/json" } })
    return
}

$searchQuery = $Request.Query.q
if (-not $searchQuery) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = '{"error":"q parameter is required"}'
        Headers    = @{ "Content-Type" = "application/json" }
    })
    return
}

# Get Graph token
$resource = "https://graph.microsoft.com"
$tokenUri = "$($env:IDENTITY_ENDPOINT)?resource=$resource&api-version=2019-08-01"

$tokenResponse = Invoke-RestMethod -Method GET `
    -Uri $tokenUri `
    -Headers @{ "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER }

$graphToken = $tokenResponse.access_token

# Search users - $search requires ConsistencyLevel: eventual
$uri = "https://graph.microsoft.com/v1.0/users?`$search=`"displayName:$searchQuery`" OR `"userPrincipalName:$searchQuery`"&`$select=id,displayName,userPrincipalName,jobTitle&`$top=10"

try {
    $response = Invoke-RestMethod -Method GET -Uri $uri -Headers @{
        Authorization    = "Bearer $graphToken"
        ConsistencyLevel = "eventual"
    }

    $results = $response.value | ForEach-Object {
        [PSCustomObject]@{
            Id                = $_.id
            DisplayName       = $_.displayName
            UserPrincipalName = $_.userPrincipalName
            JobTitle          = $_.jobTitle
        }
    }

    $body = $results | ConvertTo-Json -Depth 5
    if (-not $body) { $body = "[]" }
}
catch {
    $body = "[]"
}

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body       = $body
    Headers    = @{ "Content-Type" = "application/json" }
})