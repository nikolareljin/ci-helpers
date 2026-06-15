# JSON helpers — PowerShell companion to lib/json.sh.
# PowerShell has native JSON cmdlets; these wrappers mirror the Bash API.

function json_escape {
    param([string]$Value)
    # Escape for embedding in a JSON string value.
    $Value = $Value -replace '\\', '\\\\'
    $Value = $Value -replace '"',  '\"'
    $Value = $Value -replace "`n", '\n'
    $Value = $Value -replace "`r", '\r'
    $Value = $Value -replace "`t", '\t'
    return $Value
}

function format_json {
    param([string]$Json)
    return ($Json | ConvertFrom-Json | ConvertTo-Json -Depth 10)
}

function json_get {
    param([string]$Json, [string]$Property)
    $obj = $Json | ConvertFrom-Json
    return $obj.$Property
}

# jq-style query. If jq is installed, use it; otherwise fall back to PS.
function jq_query {
    param([string]$Filter, [string]$Json)
    if (Get-Command 'jq' -ErrorAction SilentlyContinue) {
        return ($Json | jq $Filter)
    }
    # Minimal fallback: supports simple `.field` access only.
    if ($Filter -match '^\.([\w]+)$') {
        return json_get $Json $Matches[1]
    }
    throw "jq not installed and filter '$Filter' is too complex for built-in fallback"
}
