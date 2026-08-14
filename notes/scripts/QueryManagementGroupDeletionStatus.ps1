$ManagementGroupId = "platform"

while ($true) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $exists = Get-AzManagementGroup |
        Where-Object { $_.Name -eq $ManagementGroupId }

    if (-not $exists) {
        Write-Host "[$timestamp] Management group '$ManagementGroupId' has been deleted."
        break
    }

    Write-Host "[$timestamp] Management group '$ManagementGroupId' still exists. Checking again in 30 seconds..."
    Start-Sleep -Seconds 30
}