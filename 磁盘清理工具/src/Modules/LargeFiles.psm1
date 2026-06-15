function Get-LargeFiles {
    param(
        [Parameter(Mandatory)][string[]]$Roots,
        [long]$MinBytes = 100MB
    )
    $results = foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -ge $MinBytes } |
            ForEach-Object {
                [PSCustomObject]@{
                    Path        = $_.FullName
                    DisplayName = $_.FullName
                    Category    = 'LargeFile'
                    SizeBytes   = [long]$_.Length
                    LastUsed    = $_.LastWriteTime
                }
            }
    }
    $results | Sort-Object SizeBytes -Descending
}

Export-ModuleMember -Function Get-LargeFiles
