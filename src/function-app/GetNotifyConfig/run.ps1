using namespace System.Net
param($Request, $TriggerMetadata)

# Mail is available when the Azure Communication Services endpoint and the sender address are set.
# Whether the identity may actually send is only known at send time (role on the ACS resource).
$available = -not [string]::IsNullOrWhiteSpace($env:ACS_ENDPOINT) -and -not [string]::IsNullOrWhiteSpace($env:MAIL_FROM)

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body       = (@{ available = $available } | ConvertTo-Json)
    Headers    = @{ "Content-Type" = "application/json" }
})