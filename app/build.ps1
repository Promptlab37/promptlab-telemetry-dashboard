# ---------------------------------------------------------------
#  Sestavi minimalni APK (WebView na celou obrazovku) a nainstaluje
#  ho do telefonu. Bez Gradle - primo aapt2 + javac + d8 + apksigner.
# ---------------------------------------------------------------
$ErrorActionPreference = 'Stop'

# Android SDK a Java se berou z promennych prostredi, jinak ze standardnich
# umisteni - presne tam je instaluje Android Studio.
$sdk    = if ($env:ANDROID_HOME)          { $env:ANDROID_HOME }
          elseif ($env:ANDROID_SDK_ROOT)  { $env:ANDROID_SDK_ROOT }
          else { Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
$bt     = Join-Path $sdk "build-tools\34.0.0"
$plat   = Join-Path $sdk "platforms\android-34\android.jar"
$jdk    = if ($env:JAVA_HOME) { $env:JAVA_HOME }
          else { Join-Path $env:ProgramFiles 'Android\Android Studio\jbr' }
$jbr    = Join-Path $jdk 'bin'
$javac  = Join-Path $jbr "javac.exe"
$keytool= Join-Path $jbr "keytool.exe"
$adb    = Join-Path $sdk "platform-tools\adb.exe"

$root   = Split-Path -Parent $MyInvocation.MyCommand.Path
$out    = Join-Path $root "out"
$ks     = Join-Path $root "debug.keystore"

foreach ($p in @($bt,$plat,$javac,$keytool)) {
    if (-not (Test-Path $p)) { throw "Chybi: $p" }
}

# d8.bat a apksigner.bat spousteji javu pres JAVA_HOME - bez toho skonci
# hlaskou "JAVA_HOME is not set". Java je v JBR od Android Studia.
$env:JAVA_HOME = $jdk
$env:PATH      = "$jbr;$env:PATH"

if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Path $out -Force | Out-Null
New-Item -ItemType Directory -Path "$out\classes" -Force | Out-Null

Write-Host "1/6  aapt2 link (manifest -> zaklad APK)"
& "$bt\aapt2.exe" link `
    -I $plat `
    --manifest (Join-Path $root "AndroidManifest.xml") `
    --min-sdk-version 24 --target-sdk-version 34 `
    -o "$out\base.apk"
if ($LASTEXITCODE -ne 0) { throw "aapt2 link selhal" }

Write-Host "2/6  javac (Java -> .class)"
$srcs = Get-ChildItem (Join-Path $root "src") -Recurse -Filter *.java | ForEach-Object { $_.FullName }
& $javac -source 8 -target 8 -nowarn -bootclasspath $plat -classpath $plat -d "$out\classes" $srcs
if ($LASTEXITCODE -ne 0) { throw "javac selhal" }

Write-Host "3/6  d8 (.class -> classes.dex)"
$classes = Get-ChildItem "$out\classes" -Recurse -Filter *.class | ForEach-Object { $_.FullName }
& "$bt\d8.bat" --lib $plat --min-api 24 --output $out $classes
if ($LASTEXITCODE -ne 0) { throw "d8 selhal" }

Write-Host "4/6  vlozeni classes.dex do APK"
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::Open("$out\base.apk", 'Update')
try {
    $e = $zip.GetEntry('classes.dex')
    if ($e) { $e.Delete() }
    [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
        $zip, "$out\classes.dex", 'classes.dex')
} finally { $zip.Dispose() }

Write-Host "5/6  podpis"
if (-not (Test-Path $ks)) {
    & $keytool -genkeypair -v -keystore $ks -storepass android -keypass android `
        -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 `
        -dname "CN=PROMPTLAB Telemetry, OU=local, O=local, C=CZ" | Out-Null
}
& "$bt\zipalign.exe" -f -p 4 "$out\base.apk" "$out\aligned.apk"
if ($LASTEXITCODE -ne 0) { throw "zipalign selhal" }
& "$bt\apksigner.bat" sign --ks $ks --ks-pass pass:android --key-pass pass:android `
    --out "$out\telemetry.apk" "$out\aligned.apk"
if ($LASTEXITCODE -ne 0) { throw "apksigner selhal" }

Write-Host "6/6  instalace do telefonu"
& $adb install -r "$out\telemetry.apk"

Write-Host ""
Write-Host "HOTOVO: $out\telemetry.apk"
