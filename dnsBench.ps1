# ---------- config ----------
# Parameters (can be overridden when calling the script)
$HostName   = "www.google.com" #"sduwhv.imigrasi.go.id"
$Trials     = 5
$Resolvers  = @(
  # Cloudflare
  "1.1.1.1","1.0.0.1",
  # Google
  "8.8.8.8","8.8.4.4",
  # Quad9
  "9.9.9.9","149.112.112.112"
)
# Include system-configured DNS servers (primary & secondary) in the test
$IncludeSystemResolvers = $true
# Include IPv6 resolvers (system/public). If false, only IPv4 will be tested.
$IncludeIPv6Resolvers = $false
# Restrict resolvers to public IPv4 addresses only (excludes loopback, private, link-local, CGNAT, multicast/reserved)
$OnlyPublicIPv4 = $true
# Optional: an upload endpoint to POST a test file to. If empty, upload test is skipped.
$UploadUrl  = ""  # e.g. "https://sduwhv.imigrasi.go.id/upload"
# Size of test file to generate (in megabytes) for upload test. Small values for quick runs.
$UploadFileSizeMB = 5
# ---------- helpers ----------
function Avg($xs){ if($xs.Count -eq 0){return [double]::NaN}; [Math]::Round(($xs | Measure-Object -Average).Average,3) }
function CurlTimes($url,$extra){
  $fmt = "dns=%{time_namelookup} tcp=%{time_connect} tls=%{time_appconnect} ttfb=%{time_starttransfer} total=%{time_total}`n"
  $res = @()
   1..$Trials | ForEach-Object {
    $out = curl -sS $extra -o NUL -w $fmt $url 2>$null
    # parse into object
    $kv = @{}
     $out -split '\s+' | Where-Object {$_ -match '='} | ForEach-Object { $p=$_ -split '='; $kv[$p[0]]=[double]$p[1] }
    $res += [pscustomobject]@{dns=$kv.dns; tcp=$kv.tcp; tls=$kv.tls; ttfb=$kv.ttfb; total=$kv.total}
    Start-Sleep -Milliseconds 150
  }
  $avg = [pscustomobject]@{
    dns   = Avg($res.dns)
    tcp   = Avg($res.tcp)
    tls   = Avg($res.tls)
    ttfb  = Avg($res.ttfb)
    total = Avg($res.total)
  }
  return $avg
}
function Get-UploadMbps(){
  # Try common CLI tools to obtain upload speed in Mbps.
  $tools = @(
    @{ Name="Ookla Speedtest"; Command="speedtest"; Args="-f json"; Parser="Ookla" },
    @{ Name="speedtest-cli"; Command="speedtest-cli"; Args="--json"; Parser="PyCli" },
    @{ Name="librespeed-cli"; Command="librespeed-cli"; Args="--json"; Parser="Libre" }
  )
  foreach($t in $tools){
    $cmd = Get-Command $t.Command -ErrorAction SilentlyContinue
    if(-not $cmd){ continue }
    try{
      $json = & $t.Command $t.Args 2>$null
      if([string]::IsNullOrWhiteSpace($json)){ continue }
      $obj = $json | ConvertFrom-Json
      switch($t.Parser){
        "Ookla" {
          if($obj.upload -and $obj.upload.bytes -and $obj.upload.elapsed){
            $bps = ( [double]$obj.upload.bytes * 8.0 ) / ( [double]$obj.upload.elapsed / 1000.0 )
            return [Math]::Round($bps / 1e6, 2)
          }
        }
        "PyCli" {
          if($obj.upload){
            return [Math]::Round(([double]$obj.upload) / 1e6, 2)
          }
        }
        "Libre" {
          if($obj.upload){
            $val = [double]$obj.upload
            if($val -gt 1000){ return [Math]::Round($val / 1e6, 2) } else { return [Math]::Round($val, 2) }
          }
        }
      }
    } catch {
      continue
    }
  }
  return [double]::NaN
}
# Gather system DNS resolvers (IPv4) if requested
function Get-SystemResolvers(){
  try{
    $items4 = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue
    $items6 = Get-DnsClientServerAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue
    $ips = @()
    if($items4){ $ips += ($items4 | ForEach-Object { $_.ServerAddresses }) }
    if($items6){ $ips += ($items6 | ForEach-Object { $_.ServerAddresses }) }
    if($ips){ return ($ips | Where-Object { $_ } | Select-Object -Unique) }
  } catch {}
  return @()
}

# Helper: detect private/reserved IPv4 ranges
function Test-IPv4Private([string]$ip){
  if(-not ($ip -match '^[0-9]{1,3}(\.[0-9]{1,3}){3}$')){ return $true }
  $parts = $ip.Split('.') | ForEach-Object { [int]$_ }
  if($parts.Count -ne 4){ return $true }
  $a,$b,$c,$d = $parts
  if($a -eq 10){ return $true }
  if($a -eq 172 -and $b -ge 16 -and $b -le 31){ return $true }
  if($a -eq 192 -and $b -eq 168){ return $true }
  if($a -eq 127){ return $true }
  if($a -eq 169 -and $b -eq 254){ return $true }
  if($a -eq 100 -and $b -ge 64 -and $b -le 127){ return $true } # CGNAT 100.64.0.0/10
  if($a -ge 224){ return $true } # Multicast/Reserved
  if($a -eq 0 -and $b -eq 0 -and $c -eq 0 -and $d -eq 0){ return $true }
  if($a -eq 255 -and $b -eq 255 -and $c -eq 255 -and $d -eq 255){ return $true }
  return $false
}
function Measure-Upload($url, $sizeMB){
  if([string]::IsNullOrWhiteSpace($url)){
    return $null
  }
  # create temp file of requested size with random bytes
  $tmp = [IO.Path]::GetTempFileName()
  $fs = [IO.File]::OpenWrite($tmp)
  try{
    $bytes = 1MB
    $totalBytes = [int64]$sizeMB * $bytes
    $buffer = New-Object byte[] (64KB)
    $rand = New-Object System.Random
    $written = 0L
    while($written -lt $totalBytes){
      $rand.NextBytes($buffer)
      $toWrite = [int]([Math]::Min($buffer.Length, $totalBytes - $written))
      $fs.Write($buffer,0,$toWrite)
      $written += $toWrite
    }
    $fs.Flush()
  } finally { $fs.Close() }

  $results = @()
  1..$Trials | ForEach-Object {
    try{
      $sw = [diagnostics.stopwatch]::StartNew()
      # Use Invoke-WebRequest/Invoke-RestMethod to POST the file. -UseBasicParsing legacy flag not needed in PS Core.
  Invoke-RestMethod -Uri $url -Method Post -InFile $tmp -ContentType 'application/octet-stream' -TimeoutSec 120 -ErrorAction Stop | Out-Null
      $sw.Stop()
      $results += $sw.Elapsed.TotalSeconds
    } catch {
      # on failure record as NaN
      $results += [double]::NaN
    }
    Start-Sleep -Milliseconds 150
  }
  Remove-Item -Force $tmp -ErrorAction SilentlyContinue

  $good = $results | Where-Object { -not [double]::IsNaN($_) }
  if($good.Count -eq 0){ return [pscustomobject]@{AvgSeconds=[double]::NaN; MBps=[double]::NaN; Results=$results} }
  $avg = [Math]::Round(($good | Measure-Object -Average).Average,3)
  $mb = [Math]::Round($sizeMB / $avg,3)
  return [pscustomobject]@{AvgSeconds=$avg; MBps=$mb; Results=$results}
}
# ---------- DNS resolver benchmark ----------
$dnsResults = @()
$allResolvers = @()
if($IncludeSystemResolvers){ $allResolvers += (Get-SystemResolvers) }
$allResolvers += $Resolvers
$allResolvers = $allResolvers | Where-Object { $_ } | Select-Object -Unique
# Apply family/public filters
if(-not $IncludeIPv6Resolvers){
  # Keep only IPv4
  $allResolvers = $allResolvers | Where-Object { $_ -match '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' }
  if($OnlyPublicIPv4){
    $allResolvers = $allResolvers | Where-Object { -not (Test-IPv4Private $_) }
  }
} else {
  # Keep IPv4 and IPv6; optionally you could filter IPv6 private ranges here if needed
  $allResolvers = $allResolvers | Where-Object { (($_ -match '^[0-9]{1,3}(\.[0-9]{1,3}){3}$') -or ($_ -match ':')) }
}
"Testing DNS resolvers:"; $allResolvers | ForEach-Object { " - $_" }
foreach($r in $allResolvers){
  $times = @()
  1..$Trials | ForEach-Object {
    $t = (Measure-Command { Resolve-DnsName $HostName -Server $r -Type A -ErrorAction SilentlyContinue }).TotalMilliseconds
    if($t -gt 0){ $times += $t }
    Start-Sleep -Milliseconds 100
  }
  $dnsResults += [pscustomobject]@{
    Resolver = $r
    AvgMs    = [Math]::Round(($times | Measure-Object -Average).Average,1)
  }
}
$dnsResults = $dnsResults | Sort-Object AvgMs
"DNS resolver speed (lower is better):"
$dnsResults | Format-Table

# ---------- HTTPS timing benchmark ----------
$url = "https://$HostName/"
"h2/HTTPS timings (seconds):"
$h2 = CurlTimes $url "-sS"
$h2 | Format-List

"h3/HTTP3 timings (seconds) if supported:"
$h3 = CurlTimes $url "--http3 -sS"
$h3 | Format-List

# ---------- Packet loss and jitter snapshot (ICMP) ----------
"ICMP snapshot to host (loss and jitter hint):"
$pingCount = 20
$ping = Test-Connection $HostName -Count $pingCount -ErrorAction SilentlyContinue
if($ping){
  # Prefer property in this order: ResponseTime (Windows PS), Latency (PS7+), Time/RoundtripTime as fallbacks
  $latProp = @('ResponseTime','Latency','Time','RoundtripTime') |
    Where-Object { $null -ne ($ping | Get-Member -Name $_ -ErrorAction SilentlyContinue) } |
    Select-Object -First 1
  if($latProp){
    $lat = $ping | Select-Object -ExpandProperty $latProp | Where-Object { $_ -ne $null }
    if(($lat | Measure-Object).Count -gt 0){
      $loss = 100.0 * (1 - (($lat | Measure-Object).Count / [double]$pingCount))
      $avgLat = ($lat | Measure-Object -Average).Average
      $sumSquares = ($lat | ForEach-Object { $d = ($_ - $avgLat); $d * $d } | Measure-Object -Sum).Sum
      $jitt = [Math]::Round(([Math]::Sqrt($sumSquares / (($lat | Measure-Object).Count))),1)
      [pscustomobject]@{ LossPercent = [Math]::Round($loss,1); AvgMs = [Math]::Round($avgLat,1); JitterMs = $jitt } | Format-List
    } else { "Ping blocked or unreachable (no latency samples)" }
  } else { "Ping output missing latency field (ResponseTime/Latency)" }
} else { "Ping blocked or unreachable" }

# ---------- Recommendation ----------
"Recommendation:"
$bestDns = $dnsResults | Select-Object -First 1
$proto = if(( $null -ne $h3) -and ($h3.total -gt 0) -and ($h3.total -lt $h2.total)){ "Use HTTP/3 capable browser and stack" } else { "HTTP/2 is fine" }
"Set DNS to $($bestDns.Resolver). Focus on lowering 'total' time. $proto."

# ---------- Upload throughput test (effective upload time for given file size) ----------
if(-not [string]::IsNullOrWhiteSpace($UploadUrl)){
  "\nUpload test to $UploadUrl with file size ${UploadFileSizeMB}MB (lower is better):"
  $uploadRes = Measure-Upload -url $UploadUrl -sizeMB $UploadFileSizeMB
  if($null -eq $uploadRes){ "Upload test skipped (no URL)" } elseif([double]::IsNaN($uploadRes.AvgSeconds)){
    "Upload failed for all trials or timed out."
  } else {
    [pscustomobject]@{ AvgSeconds = $uploadRes.AvgSeconds; Throughput_MBps = $uploadRes.MBps } | Format-List
    "Estimated time to upload a ${UploadFileSizeMB}MB file: $($uploadRes.AvgSeconds) seconds (≈ $([Math]::Round($uploadRes.AvgSeconds/60,2)) minutes)"
  }
} else {
  "\nUpload URL not provided; estimating upload time using a network speed test:"
  $mbps = Get-UploadMbps
  if([double]::IsNaN($mbps)){
    "No supported speed test CLI found (tried: speedtest, speedtest-cli, librespeed-cli). Install one to enable upload estimate."
  } else {
    $megabits = 8.0 * [double]$UploadFileSizeMB
    $seconds = [Math]::Round(($megabits / $mbps), 2)
    [pscustomobject]@{ UploadMbps = $mbps; FileSizeMB = $UploadFileSizeMB; EstimatedSeconds = $seconds } | Format-List
  }
}
