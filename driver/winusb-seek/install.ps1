# install.ps1 — установка WinUSB-драйвера на Seek CompactPRO (VID_289D&PID_0011).
# Запускать от администратора:
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
# Требуется только inbox winusb.inf — подпись каталога не нужна
# (Windows принимает unsigned INF для класса USB через DevCon/PnP-обход? — НЕТ:
#  для не-signature-режима используем pnputil с /force; при Secure Boot и
#  политиках подписи может понадобиться тестовая подпись — см. README.md).
$ErrorActionPreference = 'Stop'
$inf = Join-Path $PSScriptRoot 'seek-thermal-winusb.inf'
$dev = 'USB\VID_289D&PID_0011'

Write-Host "[1/3] Импорт пакета: $inf"
pnputil /add-driver $inf /install | Out-Host

Write-Host "[2/3] Привязка устройства $dev"
$devs = Get-PnpDevice | Where-Object { $_.InstanceId -like "$dev*" }
if (-not $devs) { Write-Warning "Устройство не найдено в списке (подключён ли тепловизор?)"; exit 2 }
foreach ($d in $devs) {
    #forces driver rebind to the new INF
    pnputil /remove-device "$($d.InstanceId)" | Out-Host
}
Start-Sleep -Seconds 2
Get-PnpDevice | Where-Object { $_.InstanceId -like "$dev*" } | ForEach-Object {
    pnputil /add-driver $inf /install | Out-Host
    pnputil /restart-device "$($_.InstanceId)" | Out-Host
}

Write-Host "[3/3] Итог:"
Get-PnpDevice | Where-Object { $_.InstanceId -like "$dev*" } |
    Select-Object Status, Class, FriendlyName, InstanceId | Format-List
