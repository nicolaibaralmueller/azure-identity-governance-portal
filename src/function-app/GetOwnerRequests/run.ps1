using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

# Admin-only listing — members only see their own pending changes (via GetIdentities).
$caller = Get-Caller -Request $Request
if (-not $caller.IsAdmin) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::Forbidden; Body = '{"error":"This action requires the Governance.Admin role."}'; Headers = @{ "Content-Type" = "application/json" } })
    return
}


# Write to the Azure Functions log stream.
Write-Host "PowerShell HTTP trigger function processed a request."

# Interact with query parameters or the body of the request.
$name = $Request.Query.Name
if (-not $name) {
    $name = $Request.Body.Name
}

$body = "This HTTP triggered function executed successfully. Pass a name in the query string or in the request body for a personalized response."

if ($name) {
    $body = "Hello, $name. This HTTP triggered function executed successfully."
}

# Associate values to output bindings by calling 'Push-OutputBinding'.
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body = $body
})
