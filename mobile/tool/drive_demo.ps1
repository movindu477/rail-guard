$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
New-Item -ItemType Directory -Force -Path "outputs/videos" | Out-Null

# 1. Tap 1006 marker on phone to open bottom sheet
& $adb -s 225333cf38027ece shell input tap 540 603
Start-Sleep -Seconds 1

# 2. Start screenrecord on phone in background
Write-Host "Starting screenrecord on phone..."
$recordProc = Start-Process -FilePath $adb -ArgumentList "-s 225333cf38027ece shell screenrecord --time-limit 60 /sdcard/two_train_demo.mp4" -PassThru

# 3. Drive emulator towards phone over ~56 seconds (28 steps * 2s)
$lon = 79.861250
$startLat = 6.921247
$targetLat = 6.918547
$step = 0.00015

Write-Host "Driving emulator from $startLat down to $targetLat..."
for ($i = 0; $i -lt 28; $i++) {
    $curLat = [Math]::Max($targetLat, $startLat - ($i * $step))
    $latStr = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:F6}", $curLat)
    $lonStr = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:F6}", $lon)
    & $adb -s emulator-5554 emu geo fix $lonStr $latStr | Out-Null
    Start-Sleep -Seconds 2
}

# Wait for screenrecord process to finish
Write-Host "Waiting for screenrecord to complete..."
$recordProc.WaitForExit(70000)
Start-Sleep -Seconds 2

# Pull video
Write-Host "Pulling video to outputs/videos/two_train_demo.mp4..."
& $adb -s 225333cf38027ece pull /sdcard/two_train_demo.mp4 outputs/videos/two_train_demo.mp4
Write-Host "Video saved successfully."
