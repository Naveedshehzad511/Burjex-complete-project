$ErrorActionPreference='Stop'
function W($rel,$b64){ $p=Join-Path 'C:\burjex\btrader' $rel; $gz=[Convert]::FromBase64String($b64); $in=New-Object System.IO.MemoryStream(,$gz); $ds=New-Object System.IO.Compression.GzipStream($in,[System.IO.Compression.CompressionMode]::Decompress); $out=New-Object System.IO.MemoryStream; $ds.CopyTo($out); $ds.Close(); [IO.File]::WriteAllBytes($p,$out.ToArray()); Write-Host ('wrote {0}' -f $rel) -ForegroundColor Green }
$b=""
$b+="H4sIAAAAAAAC/2WQvQqDMBSF9zxFtrYgureLILRD6dRupUNIoqTkR25UWsR3rxo1mkIg4Z7vXE6OUKWBCrf4ZlgtOe5wDkbhXaq5rd42oUYpo3"
$b+="cnJGYwA5UZXYGRksPCxwkFFdNFCBx3Do2gPMCtmwbslX8vNQHm4Tjpj0sy+opBXrvOQhNNBZHBL3pbPkv+FauRWi94AGFCF//2ygnz7a0odfC+"
$b+="RRi7PfaIn0GSaLv5FfWwL2kwbOoc9RJMI9iiTtVF62p6rjsg/hnTU0msHdQpfduhHx55ZL7WAQAA"
W 'apps\gateway-api\src\modules\crm\crm.module.ts' $b
$b=""
$b+="H4sIAAAAAAAC/3WQvQ6CMBRG9z7F3YCElF0XjHExMXFwMw4EKinpD2mLmBDeXWgBi8SlQ893bu9XymupDHRwkUXDCPTwVJJDkAqiTaWTXHIuRb"
$b+="BHdA6eW/MnW7XGD95UVlBRHqUwSjJG1CLgxDiG8wX65kmUVJCrki9arDRiAa4n4juHpqC/i2GcZOO1OzG3dJBQ6oJhhwDcBL2D+9IMK1JSbYgK"
$b+="uz6K/dGPeDC+S4/WpqbNzCuOiXUdi8l7fnQD+wg5CjnLtJ6/carW9egDmqv8RrMBAAA="
W 'apps\gateway-api\src\modules\trading\trading.module.ts' $b
Write-Host 'crm.module.ts + trading.module.ts written (DI fix).' -ForegroundColor Cyan