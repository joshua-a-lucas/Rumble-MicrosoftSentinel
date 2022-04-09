using namespace System.Net

# Input bindings are passed in via param block.
param($request, $TriggerMetadata)

# Log the function start time
$currentUTCtime = (Get-Date).ToUniversalTime()
Write-Host "[+] PowerShell HTTP trigger function processed a POST request at: $currentUTCtime"

# Get environment variables from the Azure Functions app
$workspaceId = $ENV:workspaceId
$workspaceKey = $ENV:workspaceKey

# Name of the custom Log Analytics table upon which the Log Analytics Data Connector API will append '_CL'
$logType = "RumbleAlerts"

# Optional value that specifies the name of the field denoting the time the data was generated
# If unspecified, the Log Analytics Data Connector API assumes it was generated at ingestion time
$timeGeneratedField = ""

# Fetch the JSON content in the body of the HTTP POST request sent from Rumble via a webhook
$obj = $request.Body

# Correct improperly formatted 'names' and 'addresses' properties in the new and changed asset arrays
# and convert the asset objects back to JSON to send to the Log Analytics Data Connector API
if ($obj.new -ne 0){
    foreach ($asset in $obj.'new_assets'){
        $asset.addresses = $asset.addresses -replace '\[' -replace '\]' -split ' '
        $asset.names = $asset.names -replace '\[' -replace '\]' -split ' '
        $asset | Add-Member -MemberType NoteProperty -Name 'event_type' -value 'new-assets-found'
    }

    $new_assets = $obj.new_assets | ConvertTo-Json -Depth 3
}

if ($obj.changed -ne 0){
    foreach ($asset in $obj.'changed_assets'){
        $asset.addresses = $asset.addresses -replace '\[' -replace '\]' -split ' '
        $asset.names = $asset.names -replace '\[' -replace '\]' -split ' '
        $asset | Add-Member -MemberType NoteProperty -Name 'event_type' -value 'assets-changed'
    }

    $changed_assets = $obj.changed_assets | ConvertTo-Json -Depth 3
}

Write-Host "[+] Fetched new and changed information from Rumble alerts webhook"

# Helper function to build the authorization signature for the Log Analytics Data Connector API
Function Build-Signature ($customerId, $sharedKey, $date, $contentLength, $method, $contentType, $resource)
{
    $xHeaders = "x-ms-date:" + $date
    $stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource

    $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
    $keyBytes = [Convert]::FromBase64String($sharedKey)

    $sha256 = New-Object System.Security.Cryptography.HMACSHA256
    $sha256.Key = $keyBytes
    $calculatedHash = $sha256.ComputeHash($bytesToHash)
    $encodedHash = [Convert]::ToBase64String($calculatedHash)
    $authorization = 'SharedKey {0}:{1}' -f $customerId,$encodedHash
    return $authorization
}

# Helper function to build and invoke a POST request to the Log Analytics Data Connector API
Function Post-LogAnalyticsData($customerId, $sharedKey, $body, $logType)
{
    $method = "POST"
    $contentType = "application/json"
    $resource = "/api/logs"
    $rfc1123date = [DateTime]::UtcNow.ToString("r")
    $contentLength = $body.Length
    $signature = Build-Signature `
        -customerId $customerId `
        -sharedKey $sharedKey `
        -date $rfc1123date `
        -contentLength $contentLength `
        -method $method `
        -contentType $contentType `
        -resource $resource
    
    $uri = "https://" + $customerId + ".ods.opinsights.azure.com" + $resource + "?api-version=2016-04-01"
    $headers = @{
        "Authorization" = $signature;
        "Log-Type" = $logType;
        "x-ms-date" = $rfc1123date;
        "time-generated-field" = $timeGeneratedField;
    }

    $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $body -UseBasicParsing
    return $response.StatusCode
}

# POST the new asset alerts to the Log Analytics Data Connector API
if ($obj.new -ne 0){
    $statusCode = Post-LogAnalyticsData -customerId $workspaceId -sharedKey $workspaceKey -body ([System.Text.Encoding]::UTF8.GetBytes($new_assets)) -logType $logType
    if ($statusCode -eq 200){
        Write-Host "[+] (New Assets) Successfully sent POST request to the Log Analytics API"
    } else {
        Write-Host "[-] (New Assets) Failed to send POST request to the Log Analytics API with status code: $statusCode"
    }
}

# POST the changed asset alerts to the Log Analytics Data Connector API
if ($obj.changed -ne 0){
    $statusCode = Post-LogAnalyticsData -customerId $workspaceId -sharedKey $workspaceKey -body ([System.Text.Encoding]::UTF8.GetBytes($changed_assets)) -logType $logType
    if ($statusCode -eq 200){
        Write-Host "[+] (Changed Assets) Successfully sent POST request to the Log Analytics API"
    } else {
        Write-Host "[-] (Changed Assets) Failed to send POST request to the Log Analytics API with status code: $statusCode"
    }    
}

# Log the function end time
$currentUTCtime = (Get-Date).ToUniversalTime()
Write-Host "[+] PowerShell timer trigger function finished at: $currentUTCtime"