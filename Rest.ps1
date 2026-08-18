function Invoke-RjRbRestMethodGraph {
    [CmdletBinding()]
    param (
        [string] $Resource,
        [string[]] $UriQueryParam = @(),
        [string] $UriQueryRaw,
        [string] $OdFilter,
        [string] $OdSelect,
        [int] $OdTop,
        [Microsoft.PowerShell.Commands.WebRequestMethod] $Method = [Microsoft.PowerShell.Commands.WebRequestMethod]::Default,
        [Collections.IDictionary] $Headers,
        [object] $Body,
        [string] $InFile,
        [string] $ContentType,
        [switch] $Beta,
        [Nullable[bool]] $ReturnValueProperty,
        [switch] $FollowPaging,
        [Management.Automation.ActionPreference] $NotFoundAction
    )

    $invokeArguments = rjRbGetParametersFiltered -exclude 'Beta'

    $invokeArguments['Uri'] = "https://graph.microsoft.com/$(if($Beta) {'beta'} else {'v1.0'})"

    if (-not $Headers -and (Test-Path Variable:Script:RjRbGraphAuthHeaders)) {
        $invokeArguments['Headers'] = $Script:RjRbGraphAuthHeaders
    }

    Invoke-RjRbRestMethod -JsonEncodeBody @invokeArguments
}

function Invoke-RjRbRestMethodDefenderATP {
    [CmdletBinding()]
    param (
        [string] $Resource,
        [string[]] $UriQueryParam = @(),
        [string] $UriQueryRaw,
        [string] $OdFilter,
        [string] $OdSelect,
        [int] $OdTop,
        [Microsoft.PowerShell.Commands.WebRequestMethod] $Method = [Microsoft.PowerShell.Commands.WebRequestMethod]::Default,
        [Collections.IDictionary] $Headers,
        [object] $Body,
        [string] $InFile,
        [string] $ContentType,
        [Nullable[bool]] $ReturnValueProperty,
        [switch] $FollowPaging,
        [Management.Automation.ActionPreference] $NotFoundAction
    )

    $invokeArguments = rjRbGetParametersFiltered

    $invokeArguments['Uri'] = "https://api.securitycenter.microsoft.com/api"

    if (-not $Headers -and (Test-Path Variable:Script:RjRbDefenderATPAuthHeaders)) {
        $invokeArguments['Headers'] = $Script:RjRbDefenderATPAuthHeaders
    }

    Invoke-RjRbRestMethod -JsonEncodeBody @invokeArguments
}

function Invoke-RjRbRestMethod {
    [CmdletBinding()]
    param (
        [Microsoft.PowerShell.Commands.WebRequestMethod] $Method = [Microsoft.PowerShell.Commands.WebRequestMethod]::Default,
        [uri] $Uri,
        [Alias('Resource')][string] $UriSuffix,
        [string[]] $UriQueryParam = @(),
        [string] $UriQueryRaw,
        [string] $OdFilter,
        [string] $OdSelect,
        [int] $OdTop,
        [Collections.IDictionary] $Headers,
        [object] $Body,
        [switch] $JsonEncodeBody,
        [string] $InFile,
        [string] $ContentType,
        [Management.Automation.ActionPreference] $NotFoundAction,
        [switch] $FollowPaging,
        [Nullable[bool]] $ReturnValueProperty
    )

    $invokeArguments = rjRbGetParametersFiltered -exclude 'UriSuffix', 'UriQueryParam', 'UriQueryRaw', 'OdFilter', 'OdSelect', 'OdTop', 'FollowPaging', 'ReturnValueProperty'

    $uriBuilder = [UriBuilder]::new($Uri)
    function appendToQuery([string] $newQueryOrParamName, [object] $paramValue <# [string] would never be $null #>, [switch] $split, [switch] $skipEmpty) {
        if ($split) {
            $splitPos = $newQueryOrParamName.IndexOf('=')
            $paramValue = $newQueryOrParamName.Substring($splitPos + 1)
            $newQueryOrParamName = $newQueryOrParamName.Substring(0, $splitPos)
        }
        if ($skipEmpty -and (-not $paramValue)) {
            return
        }
        if ($null -ne $paramValue) {
            $newQueryOrParamName += "=$([Web.HttpUtility]::UrlEncode($paramValue))"
        }
        if (-not $uriBuilder.Query) {
            $uriBuilder.Query = $newQueryOrParamName
        }
        else {
            $uriBuilder.Query = $uriBuilder.Query.TrimStart('?') + "&" + $newQueryOrParamName
        }
    }

    if ($UriSuffix) { $uriBuilder.Path += $UriSuffix }
    if ($UriQueryRaw) { appendToQuery $UriQueryRaw }
    $UriQueryParam | Foreach-Object { appendToQuery $_ -split }
    $PSBoundParameters.Keys -ilike 'Od*' | Foreach-Object { appendToQuery "`$$($_.Substring(2).ToLower())" $PSBoundParameters[$_] -skipEmpty }

    $invokeArguments['Uri'] = $uriBuilder.Uri

    $result = invokeRjRbRestMethodInternal @invokeArguments

    if ($null -ne $result) {

        if ($FollowPaging -and $result.PSObject.Properties['value']) {
            # successively release results to PS pipeline
            Write-Output $result.value
            $invokeNextLinkArguments = rjRbGetParametersFiltered -sourceValues $invokeArguments -include 'Method', 'Headers'
            while ($result.PSObject.Properties['@odata.nextLink'] -and $result.PSObject.Properties['value']) {
                $invokeNextLinkArguments['Uri'] = $result.'@odata.nextLink'
                $result = invokeRjRbRestMethodInternal @invokeNextLinkArguments
                Write-Output $result.value
            }
            return # result has already been return using Write-Output
        }

        if (($ReturnValueProperty -eq $true) -or (($ReturnValueProperty -ne $false) -and $result.PSObject.Properties['value'])) {
            $result = $result.value
        }

    }

    return $result
}

function invokeRjRbRestMethodInternal {
    [CmdletBinding()]
    param (
        [Microsoft.PowerShell.Commands.WebRequestMethod] $Method = [Microsoft.PowerShell.Commands.WebRequestMethod]::Default,
        [uri] $Uri,
        [Collections.IDictionary] $Headers,
        [object] $Body,
        [switch] $JsonEncodeBody,
        [string] $InFile,
        [string] $ContentType,
        [int] $ThrottleMaxTries = 3,
        [Management.Automation.ActionPreference] $NotFoundAction
    )

    $invokeArguments = rjRbGetParametersFiltered -exclude 'JsonEncodeBody', 'ThrottleMaxTries', 'NotFoundAction'

    if ($Method -eq [Microsoft.PowerShell.Commands.WebRequestMethod]::Default) {
        if ($Body) {
            $invokeArguments['Method'] = [Microsoft.PowerShell.Commands.WebRequestMethod]::Post
        }
        elseif ($InFile) {
            $invokeArguments['Method'] = [Microsoft.PowerShell.Commands.WebRequestMethod]::Put
        }
        else {
            $invokeArguments['Method'] = [Microsoft.PowerShell.Commands.WebRequestMethod]::Get
        }
    }

    if ($JsonEncodeBody -and $Body -and (-not ($Body -is [byte[]] -or $Body -is [IO.Stream]))) {
        # need to explicetly set charset in ContentType for Invoke-RestMethod to detect it and to correctly encode JSON string
        $invokeArguments['ContentType'] = "application/json; charset=UTF-8"
        $invokeArguments['Body'] = $Body | ConvertTo-Json -Depth 20
    }
    if ($InFile -and -not $ContentType) {
        $invokeArguments['ContentType'] = [Web.MimeMapping]::GetMimeMapping($InFile)
    }

    # remove empty string parameters since they will never be $null but empty only
    @('InFile', 'ContentType') | Where-Object { $invokeArguments.ContainsKey($_) -and $invokeArguments[$_] -eq [string]::Empty } | `
        ForEach-Object { $invokeArguments.Remove($_) }

    $invokeArguments['UseBasicParsing'] = $true

    Write-RjRbDebug "Invoke-RestMethod arguments" $invokeArguments

    $tryCount = 0
    do {

        $tryCount++
        $result = $null # Write-Error down below might not be terminating
        try {
            $result = Invoke-RestMethod @invokeArguments
        }

        catch {
            $isWebException = $_.Exception -is [Net.WebException]

            $isThrottled = $isWebException -and $_.Exception.Response.StatusCode -eq 429 # .NET 4.7 does not (yet) contain [Net.HttpStatusCode]::TooManyRequests
            if ($isThrottled -and $tryCount -lt $ThrottleMaxTries) {
                $retryAfter = [double]$_.Exception.Response.Headers["Retry-After"]
                if (-not $retryAfter) { $retryAfter = 15 }

                Write-RjRbLog "Request has been throttled (http status 429). Delaying for $retryAfter seconds and then trying again (this was try $tryCount of $ThrottleMaxTries)."
                Start-Sleep -Seconds $retryAfter

                continue # retry
            }

            $isNotFound = $isWebException -and $_.Exception.Response.StatusCode -eq [Net.HttpStatusCode]::NotFound
            $errorAction = $(if ($isNotFound -and $null -ne $NotFoundAction) { $NotFoundAction } else { $ErrorActionPreference })

            # no need to write error details to log on SilentlyContinue or Ignore
            if ($errorAction -notin @([Management.Automation.ActionPreference]::SilentlyContinue, [Management.Automation.ActionPreference]::Ignore)) {

                # avoid dumping full credentials outside of debug (use .Clone() to ensure to _not_ modify args for subsequent uses)
                $invokeArgsSanitized = $invokeArguments.Clone()
                if ($invokeArgsSanitized['Headers'] -and $invokeArgsSanitized['Headers']['Authorization']) {
                    $invokeArgsSanitized['Headers'] = $invokeArgsSanitized['Headers'].Clone()
                    $invokeArgsSanitized['Headers']['Authorization'] = $invokeArgsSanitized['Headers']['Authorization'] -replace '(?s)(?<=^\S+ \S{8}).*$', '...'
                }
                Write-RjRbLog "Invoke-RestMethod arguments" $invokeArgsSanitized -NoDebugOnly

                # get error response if available
                if ($isWebException) {
                    $errorResponse = $null; $responseReader = $null
                    try {
                        $responseStream = $_.Exception.Response.GetResponseStream()
                        if ($responseStream) {
                            $responseReader = [IO.StreamReader]::new($responseStream)
                            $errorResponse = $responseReader.ReadToEnd()
                            $errorResponse = $errorResponse | ConvertFrom-Json
                        }
                    }
                    catch { } # ignore all errors
                    finally {
                        if ($responseReader) {
                            $responseReader.Close()
                        }
                    }
                    Write-RjRbLog "Invoke-RestMethod error response" $errorResponse
                }
            }

            Write-Error -ErrorRecord $_ -ErrorAction $errorAction
        }

        break # always break since retries due to throttling will have already been handled above

    } while ($true) # need this for 'continue' to work

    Write-RjRbDebug "Invoke-RestMethod result" $result

    return $result
}

function Invoke-RjRbGraphBatch {
    <#
        .SYNOPSIS
        Sends requests to the Microsoft Graph JSON batch endpoint in chunks of 20,
        with automatic retries for throttled inner requests.

        .DESCRIPTION
        The Graph $batch endpoint returns 200 for the outer call even when individual
        inner requests are throttled with status 429. Throttled inner requests are
        retried after the Retry-After interval reported by the service (up to
        -MaxRetries attempts). Outer 429 responses are already retried by the Graph
        SDK itself.

        Building the batch requests (id, method, url and optional headers/body) stays
        with the caller - this function only handles chunking, transport and
        throttling. Responses are returned in completion order; correlate them to the
        requests via their id property.

        Requires an active Microsoft.Graph session (Connect-MgGraph); declare the
        Microsoft.Graph.Authentication module in the consuming runbook via #Requires.

        .PARAMETER Requests
        The batch request objects (id, method, url, optional headers/body).

        .PARAMETER ProgressLabel
        Label used in progress log lines, e.g. "adds" or "removes". Defaults to "requests".

        .PARAMETER ProgressInterval
        Emit a progress log line (Write-RjRbLog, verbose stream) every N batch calls
        (N * 20 requests). Defaults to 25; set 0 to disable.

        .PARAMETER MaxRetries
        Maximum retry rounds for throttled inner requests per chunk. Defaults to 5.
        Requests still throttled after the last round are returned with their 429
        status so the caller can count them as failures.

        .PARAMETER Beta
        Use the beta endpoint (https://graph.microsoft.com/beta/$batch) instead of v1.0.

        .OUTPUTS
        System.Object[]. One response object per request (id, status, headers, body).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Requests,

        [string]$ProgressLabel = "requests",

        [int]$ProgressInterval = 25,

        [int]$MaxRetries = 5,

        [switch]$Beta
    )

    # Graph batch API: max 20 requests per call
    $batchSize = 20
    $apiVersion = if ($Beta) { 'beta' } else { 'v1.0' }
    $batchUri = "https://graph.microsoft.com/$apiVersion/`$batch"
    $responses = [System.Collections.Generic.List[object]]::new()
    $batchNumber = 0

    for ($i = 0; $i -lt $Requests.Count; $i += $batchSize) {
        $chunk = @($Requests[$i..([Math]::Min($i + $batchSize - 1, $Requests.Count - 1))])
        $batchNumber++

        $pending = $chunk
        $attempt = 0
        while ($pending.Count -gt 0) {
            $batchBody = @{ requests = @($pending) }
            $batchResult = Invoke-MgGraphRequest -Uri $batchUri -Method POST -Body $batchBody

            # Inner requests can be throttled individually even though the outer call succeeded
            $throttled = @($batchResult.responses | Where-Object { $_.status -eq 429 })
            $final = @($batchResult.responses | Where-Object { $_.status -ne 429 })
            if ($final.Count -gt 0) {
                $responses.AddRange([object[]]$final)
            }

            if ($throttled.Count -eq 0) {
                break
            }

            $attempt++
            if ($attempt -gt $MaxRetries) {
                # Give up - the remaining throttled responses are counted as failures by the caller
                $responses.AddRange([object[]]$throttled)
                Write-RjRbLog -Message "Giving up on $($throttled.Count) request(s) still throttled after $MaxRetries retries." -Verbose
                break
            }

            # Honor the longest Retry-After the service returned (fallback 10 seconds)
            $retryAfter = 10
            foreach ($response in $throttled) {
                $headerValue = $response.headers.'Retry-After' -as [int]
                if ($headerValue -and $headerValue -gt $retryAfter) {
                    $retryAfter = $headerValue
                }
            }
            Write-RjRbLog -Message "Graph throttled $($throttled.Count) request(s) (attempt $attempt/$MaxRetries) - waiting $retryAfter seconds..." -Verbose
            Start-Sleep -Seconds $retryAfter

            $throttledIds = [System.Collections.Generic.HashSet[string]]::new([string[]]@($throttled | ForEach-Object { "$($_.id)" }))
            $pending = @($pending | Where-Object { $throttledIds.Contains("$($_.id)") })
        }

        # Progress heartbeat via the verbose log stream. Deliberately NOT Write-Output:
        # inside a value-returning function that would pollute the returned response list.
        if ($ProgressInterval -gt 0 -and $batchNumber % $ProgressInterval -eq 0) {
            Write-RjRbLog -Message "Invoke-RjRbGraphBatch: processed $([Math]::Min($i + $batchSize, $Requests.Count)) of $($Requests.Count) $ProgressLabel..." -Verbose
        }
    }

    return $responses
}
