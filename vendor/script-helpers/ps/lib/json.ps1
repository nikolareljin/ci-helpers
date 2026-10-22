# JSON helpers - PowerShell companion to lib/json.sh.
# PowerShell has native JSON cmdlets; these wrappers mirror the Bash API.

# Usage: json_escape -Value <string>
# Returns: Value with backslash, double quote, newline, CR and tab escaped for a JSON string.
# Output: none.
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

# Usage: format_json -Json <string>
# Returns: the JSON re-serialized with indentation (depth 10).
# Output: none; throws on invalid JSON.
function format_json {
    param([string]$Json)
    return ($Json | ConvertFrom-Json | ConvertTo-Json -Depth 10)
}

# Usage: json_get -Json <string> -Property <name>
# Returns: the top-level property value, or $null when absent.
# Output: none; throws on invalid JSON.
function json_get {
    param([string]$Json, [string]$Property)
    $obj = $Json | ConvertFrom-Json
    return $obj.$Property
}

# jq-style query. If jq is installed, use it; otherwise fall back to PS.
# Usage: jq_query -Filter <jq filter> -Json <string>
# Returns: jq's output lines when jq is installed; without jq, the value of a `.field` filter.
# Output: none; throws when jq is missing and the filter is more than `.field`.
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
