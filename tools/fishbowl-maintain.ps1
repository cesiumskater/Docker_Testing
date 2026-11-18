<#
.SYNOPSIS
  The weekly maintenance for Fishbowl in Docker Compose (Windows; fishbowl-maintain.sh
  is the Linux and macOS version).

.DESCRIPTION
  Updates must not stall waiting for someone to run them, so a scheduled task runs this
  every week (README section 12, "Weekly maintenance"). In order:

    1. Builds a new image with every package update published so far, tagged
       fishbowl:candidate. The running container isn't touched, and a failed build
       changes nothing.
    2. If the container isn't running (stopped on purpose, say), the candidate becomes
       the image its next `docker compose up -d` uses, and that's all.
    3. Backs up every MySQL database inside the running container
       (fishbowl-backup --label weekly-maintenance --keep 4). No backup, no change.
    4. Keeps the image the container runs now as fishbowl:previous, makes the candidate
       the fishbowl image, and recreates the container on the same volumes.
    5. Waits until the container is back where it was: healthy if it was healthy before,
       otherwise in the same state on the Fishbowl page, up to FB_MAINTAIN_TIMEOUT
       seconds (default 1200).
    6. If it doesn't get there, it saves the failed container's log next to compose.yaml,
       tags the new image fishbowl:failed, puts fishbowl:previous back and recreates the
       container again.

  It never runs during a first-time setup or a Fishbowl upgrade, and two runs never
  overlap. Everything it prints also goes to fishbowl-maintain.log in that folder.

  Settings (environment): FB_MAINTAIN_TIMEOUT (seconds, default 1200), FB_MAINTAIN_KEEP
  (maintenance backups kept, default 4), FB_MAINTAIN_PULL (1: also fetch a newer base
  image; 0 when the build uses a base image that only exists on this computer).

  Exit status: 0 = done, or nothing to do; 1 = stopped before anything changed; 2 = the
  new image failed and the previous one runs again; 3 = the previous image didn't come
  back either. For 3, restore from the backup this run names (README section 12, "If
  something goes wrong").

.PARAMETER Dir
  The folder that holds compose.yaml. Default: the current folder.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\fishbowl\fishbowl-maintain.ps1" -Dir "$HOME\fishbowl"
#>
[CmdletBinding()]
param([string]$Dir = (Get-Location).Path)

# Native commands report through exit codes; stop only where this script says so.
$ErrorActionPreference = 'Continue'

$Container = 'fishbowl'
$Service = 'fishbowl'
$Image = 'fishbowl'
$Candidate = '{0}:candidate' -f $Image
$Previous = '{0}:previous' -f $Image
$Failed = '{0}:failed' -f $Image
$LabelSource = 'https://github.com/cesiumskater/Docker_Testing'
$Timeout = if ($env:FB_MAINTAIN_TIMEOUT) { [int]$env:FB_MAINTAIN_TIMEOUT } else { 1200 }
$Keep = if ($env:FB_MAINTAIN_KEEP) { [int]$env:FB_MAINTAIN_KEEP } else { 4 }
# 1: also fetch a newer base image; 0 when the build uses a base image that only exists on this computer.
$PullArgs = if ($env:FB_MAINTAIN_PULL -eq '0') { @() } else { @('--pull') }
$script:Backup = '(none taken)'
$script:BeforeHealth = ''
$script:BeforeState = ''

function Say([string]$Text) {
  Write-Output ('{0} [maintain] {1}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'), $Text)
}
function Stop-Run([int]$Code, [string]$Text) {
  Say ('STOPPED: ' + $Text)
  exit $Code
}
function Get-ImageId([string]$Name) {
  $id = & docker image inspect --format '{{.Id}}' $Name 2>$null
  if ($LASTEXITCODE -eq 0) { return "$id".Trim() } else { return '' }
}
function Test-Running {
  $r = & docker inspect --format '{{.State.Running}}' $Container 2>$null
  return ($LASTEXITCODE -eq 0 -and "$r".Trim() -eq 'true')
}
function Get-Health {
  $h = & docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' $Container 2>$null
  return "$h".Trim()
}
function Get-PageState {
  $s = & docker exec $Container cat /run/fishbowl/status 2>$null
  return "$s".Trim()
}
function Remove-Candidate { & docker image rm $Candidate 2>$null | Out-Null }

# $true once the container is back where it was before; $false on a state that
# won't fix itself, or after $Timeout seconds.
function Test-BackWhereItWas {
  $deadline = (Get-Date).AddSeconds($Timeout)
  $h = ''; $s = ''
  while ((Get-Date) -lt $deadline) {
    if (Test-Running) {
      $h = Get-Health; $s = Get-PageState
      if (@('server-failed', 'upgrade-interrupted', 'foreign-data', 'downgrade', 'no-volumes') -contains $s) {
        Say ("The container reports '{0}'." -f $s); return $false
      }
      if ($h -eq 'healthy') { return $true }
      if ($script:BeforeHealth -ne 'healthy' -and $s -ne '' -and $s -eq $script:BeforeState) { return $true }
    }
    Start-Sleep -Seconds 10
  }
  Say ("Not back after {0} seconds (health: {1}, state: {2})." -f $Timeout, $h, $s)
  return $false
}

function Invoke-RollBack([string]$Why) {
  $saved = 'fishbowl-maintain-failed-{0}.log' -f (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
  & docker logs --tail 300 $Container *> $saved
  Say ("The new image didn't come back ({0}). Its container's log is saved in {1}." -f $Why, (Join-Path (Get-Location).Path $saved))
  & docker tag $Image $Failed 2>$null | Out-Null
  & docker tag $Previous $Image
  if ($LASTEXITCODE -ne 0) {
    Stop-Run 3 ("Couldn't put {0} back. Your data is in the volumes; this run's backup: {1}. Follow README section 12, 'If something goes wrong'." -f $Previous, $script:Backup)
  }
  Say 'Putting the previous image back and recreating the container.'
  & docker compose up -d --force-recreate --no-build $Service
  if (Test-BackWhereItWas) {
    Say ("Rolled back: the previous image runs again. The new one is kept as {0} for a look." -f $Failed)
    exit 2
  }
  Stop-Run 3 ("The previous image didn't come back either. Your data is in the volumes, and this run's backup is {0}. Follow README section 12, 'If something goes wrong'." -f $script:Backup)
}

if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { Stop-Run 1 ("No such folder: {0}" -f $Dir) }
Set-Location -LiteralPath $Dir
if (-not (Test-Path -LiteralPath 'compose.yaml')) {
  Stop-Run 1 ("No compose.yaml in {0}. Run this in the folder you start Fishbowl from, or pass -Dir." -f (Get-Location).Path)
}

# One run at a time: creating the folder fails if it already exists.
$lock = Join-Path (Get-Location).Path '.fishbowl-maintain.lock'
try { New-Item -ItemType Directory -Path $lock -ErrorAction Stop | Out-Null }
catch { Stop-Run 1 ("Another maintenance run holds {0}. If none is running (a crash left it behind), delete that folder." -f $lock) }

Start-Transcript -Path (Join-Path (Get-Location).Path 'fishbowl-maintain.log') -Append | Out-Null
try {
  & docker info *> $null
  if ($LASTEXITCODE -ne 0) { Stop-Run 1 "Docker isn't running. Docker Desktop has to be running, which needs someone signed in to Windows." }
  & docker compose version *> $null
  if ($LASTEXITCODE -ne 0) { Stop-Run 1 "Docker Compose isn't available: 'docker compose version' failed." }

  # 1. Build. A new PACKAGES_REFRESH value makes Docker apply every package update
  #    instead of reusing its cache; FB_IMAGE gives the build its own tag.
  $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
  Say 'Building a new image with every package update published so far. This takes a while.'
  $env:FB_IMAGE = $Candidate
  & docker compose build @PullArgs --build-arg ('PACKAGES_REFRESH=' + $stamp) $Service
  $buildRc = $LASTEXITCODE
  Remove-Item Env:FB_IMAGE -ErrorAction SilentlyContinue
  if ($buildRc -ne 0) { Remove-Candidate; Stop-Run 1 "The build failed (its output is above). Nothing changed; the container keeps its image." }
  if (-not (Get-ImageId $Candidate)) { Stop-Run 1 ("The build reported success, but there's no {0} image." -f $Candidate) }

  # 2. Not running: no backup, no recreate; the next start uses the new image.
  if (-not (Test-Running)) {
    $current = Get-ImageId $Image
    if ($current) { & docker tag $current $Previous | Out-Null }
    & docker tag $Candidate $Image
    if ($LASTEXITCODE -eq 0) { Remove-Candidate }
    Say "The container isn't running, so it was left alone. 'docker compose up -d' starts it on the new image."
    exit 0
  }

  $script:BeforeHealth = Get-Health
  $script:BeforeState = Get-PageState
  if (@('setup', 'upgrading', 'starting-up', 'starting', 'stopping-server') -contains $script:BeforeState) {
    Remove-Candidate
    Stop-Run 1 ("Fishbowl is busy ({0}). Nothing changed; the next run tries again." -f $script:BeforeState)
  }
  Say ("Before: health '{0}', state '{1}'." -f $script:BeforeHealth, $script:BeforeState)

  # 3. Back up first. No backup, no change.
  Say 'Backing up every MySQL database.'
  $out = & docker exec $Container fishbowl-backup --label weekly-maintenance --keep $Keep 2>&1 | ForEach-Object { "$_" }
  $rc = $LASTEXITCODE
  $out | ForEach-Object { Write-Output ('    ' + $_) }
  if ($rc -ne 0) {
    Remove-Candidate
    if ($rc -eq 3) {
      Stop-Run 1 "This installation has a MySQL root password of its own, so an unattended backup can't run. Run this script by hand after 'docker exec -it fishbowl fishbowl-backup', or see README section 12."
    }
    Stop-Run 1 'The backup failed (above). Nothing changed.'
  }
  $script:Backup = ($out | Select-Object -Last 1)

  # 4. Swap and recreate on the same volumes.
  $runningImage = (& docker inspect --format '{{.Image}}' $Container).Trim()
  & docker tag $runningImage $Previous
  if ($LASTEXITCODE -ne 0) { Remove-Candidate; Stop-Run 1 ("Couldn't keep the current image as {0}. Nothing changed." -f $Previous) }
  & docker tag $Candidate $Image
  if ($LASTEXITCODE -ne 0) { Remove-Candidate; Stop-Run 1 "Couldn't tag the new image. Nothing changed." }
  Remove-Candidate
  Say 'Recreating the container on the new image (same volumes).'
  & docker compose up -d --force-recreate --no-build $Service
  if ($LASTEXITCODE -ne 0) { Invoke-RollBack 'docker compose up failed' }

  # 5. Back where it was?
  if (-not (Test-BackWhereItWas)) { Invoke-RollBack "it didn't get back to where it was" }

  # 6. Tidy up: earlier builds of this image that no tag points at any more.
  & docker image prune -f --filter ('label=org.opencontainers.image.source=' + $LabelSource) *> $null
  $built = (& docker exec $Container cat /usr/local/share/fishbowl/image-built 2>$null)
  Say ("Done. The container runs the new image (packages as of {0}). Backup: {1}. The previous image stays as {2} until the next run." -f "$built".Trim(), $script:Backup, $Previous)
  exit 0
}
finally {
  Stop-Transcript | Out-Null
  Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
}
