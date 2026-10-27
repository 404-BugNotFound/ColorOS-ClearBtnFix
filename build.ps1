$ErrorActionPreference = 'Stop'
$root = 'C:\Users\Pan\Projects\ClearBtnFix'
$sdk = 'C:\Users\Pan\Android'
$bt = "$sdk\build-tools\35.0.0"
$androidJar = "$sdk\platforms\android-35\android.jar"
$jdk = 'C:\Program Files\Eclipse Adoptium\jdk-21.0.12.101-hotspot\bin'
$out = "$root\build"
$libs = "$root\libs"

New-Item -ItemType Directory -Force $libs | Out-Null
$aar = "$libs\api-102.0.0.aar"
if (-not (Test-Path $aar)) {
    Invoke-WebRequest https://repo1.maven.org/maven2/io/github/libxposed/api/102.0.0/api-102.0.0.aar -OutFile $aar
}
$hash = (Get-FileHash -Algorithm SHA256 $aar).Hash.ToLower()
if ($hash -ne '423484a6e1807e7a423c4b88fcd8176d104318259d91791877fed88fe91479d0') { throw "aar sha256 mismatch: $hash" }
$apiJar = "$libs\xposed-api.jar"
if (-not (Test-Path $apiJar)) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [System.IO.Compression.ZipFile]::OpenRead($aar)
    $z.Entries | Where-Object FullName -eq 'classes.jar' | ForEach-Object { [System.IO.Compression.ZipFileExtensions]::ExtractToFile($_, $apiJar, $true) }
    $z.Dispose()
}

if (Test-Path $out) { Remove-Item -Recurse -Force $out }
New-Item -ItemType Directory -Force "$out\classes", "$out\dex", "$out\res" | Out-Null

$srcs = Get-ChildItem -Recurse "$root\src\main\java" -Filter *.java | ForEach-Object FullName
& "$jdk\javac.exe" --release 17 -encoding UTF-8 -Xlint:-options -classpath "$androidJar;$apiJar" -d "$out\classes" $srcs
if ($LASTEXITCODE) { throw 'javac failed' }

$classFiles = "$out\classes.jar"
& "$jdk\jar.exe" cf $classFiles -C "$out\classes" .
& "$bt\d8.bat" --release --min-api 31 --lib $androidJar --classpath $apiJar --output "$out\dex" $classFiles
if ($LASTEXITCODE) { throw 'd8 failed' }

& "$bt\aapt2.exe" compile --dir "$root\src\main\res" -o "$out\res\res.zip"
if ($LASTEXITCODE) { throw 'aapt2 compile failed' }
& "$bt\aapt2.exe" link -o "$out\unsigned.apk" -I $androidJar --manifest "$root\src\main\AndroidManifest.xml" --min-sdk-version 31 --target-sdk-version 35 "$out\res\res.zip"
if ($LASTEXITCODE) { throw 'aapt2 link failed' }

# add classes.dex and META-INF/xposed/*
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::Open("$out\unsigned.apk", 'Update')
[System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, "$out\dex\classes.dex", 'classes.dex') | Out-Null
Get-ChildItem "$root\src\main\resources\META-INF\xposed" | ForEach-Object {
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $_.FullName, "META-INF/xposed/$($_.Name)") | Out-Null
}
$zip.Dispose()

& "$bt\zipalign.exe" -f -p 4 "$out\unsigned.apk" "$out\aligned.apk"
if ($LASTEXITCODE) { throw 'zipalign failed' }

$ks = "$root\debug.keystore"
if (-not (Test-Path $ks)) {
    & "$jdk\keytool.exe" -genkeypair -keystore $ks -storepass android -keypass android -alias key -keyalg RSA -keysize 2048 -validity 36500 -dname 'CN=ClearBtnFix' | Out-Null
}
& "$bt\apksigner.bat" sign --ks $ks --ks-pass pass:android --key-pass pass:android --out "$out\ClearBtnFix.apk" "$out\aligned.apk"
if ($LASTEXITCODE) { throw 'apksigner failed' }
& "$bt\apksigner.bat" verify "$out\ClearBtnFix.apk"
Write-Output "OK $out\ClearBtnFix.apk"
