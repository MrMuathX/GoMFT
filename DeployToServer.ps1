<#
.SYNOPSIS
    Builds GoMFT on the SSH host and installs it as a CasaOS app.

.DESCRIPTION
    Packs the working tree, ships it to the host over SSH, builds the Docker
    image there, then registers the stack with CasaOS through casaos-cli so the
    app appears on the CasaOS dashboard with an icon and a Web UI link.

    Re-running the script is an in-place update: the image is rebuilt and
    `casaos-cli app-management apply` replaces the running container. Data,
    backups and the generated secrets survive because they live in bind mounts
    outside the image.

.EXAMPLE
    .\DeployToServer.ps1
    .\DeployToServer.ps1 -Port 8090
    .\DeployToServer.ps1 -SkipBuild     # re-apply compose only, no rebuild
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    # SSH alias from ~/.ssh/config (host, user, key and port come from there).
    [string] $SshHost   = 'server',

    # CasaOS app id / compose project name / container name.
    [string] $AppId     = 'gomft',

    # Host port the Web UI is published on.
    [int]    $Port      = 8080,

    # Remote build context. Wiped and repopulated on every run.
    [string] $RemoteSrc = '/home/muath/gomft-src',

    # Persistent data root: db, backups and the secrets file live here.
    [string] $DataRoot  = '/DATA/AppData/gomft',

    # TZ passed to the container.
    [string] $Timezone  = 'Asia/Bahrain',

    # Skip `docker build` and only re-apply the CasaOS compose.
    [switch] $SkipBuild
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = $PSScriptRoot

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Note { param([string]$Message) Write-Host "    $Message" -ForegroundColor DarkGray }

function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments, [string]$What)
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$What failed (exit $LASTEXITCODE)" }
}

# --- The whole Linux side of the deploy, run as one script on the host. -------
# Args: 1=AppId 2=Port 3=DataRoot 4=RemoteSrc 5=HostIp 6=Timezone
#       7=Version 8=BuildTime 9=Commit 10=SkipBuild(0|1)
$RemoteScript = @'
#!/usr/bin/env bash
set -euo pipefail

APP_ID="$1"; PORT="$2"; DATA_ROOT="$3"; SRC_DIR="$4"; HOST_IP="$5"
TZ_NAME="$6"; VERSION="$7"; BUILD_TIME="$8"; COMMIT="$9"; SKIP_BUILD="${10}"

STAGE=/tmp/gomft-deploy
IMAGE="${APP_ID}:latest"
ENV_FILE="${DATA_ROOT}/app.env"
COMPOSE_FILE="${STAGE}/docker-compose.yml"
ICON_URL="http://${HOST_IP}:${PORT}/static/img/logo.png"
PUID="$(id -u)"; PGID="$(id -g)"

say() { printf '    %s\n' "$*"; }

# --- 1. unpack the source ----------------------------------------------------
say "unpacking source into ${SRC_DIR}"
rm -rf "$SRC_DIR"
mkdir -p "$SRC_DIR"
tar -xzf "${STAGE}/src.tar.gz" -C "$SRC_DIR"
test -f "${SRC_DIR}/Dockerfile" || { echo "ERROR: Dockerfile missing from upload" >&2; exit 1; }

# --- 2. persistent dirs and secrets ------------------------------------------
say "preparing ${DATA_ROOT}"
sudo mkdir -p "${DATA_ROOT}/data" "${DATA_ROOT}/backups"
sudo chown -R "${PUID}:${PGID}" "$DATA_ROOT"

# GoMFT falls back to a hardcoded JWT secret and a "dev" TOTP key unless these
# are supplied, so generate them once and keep them on the host. Mounted at
# /app/.env read-only; godotenv reads it, nothing in the app writes it.
if [ ! -f "$ENV_FILE" ]; then
    say "generating JWT_SECRET and TOTP_ENCRYPTION_KEY (first run)"
    umask 077
    {
        printf 'JWT_SECRET=%s\n' "$(openssl rand -hex 32)"
        # exactly 32 chars: used verbatim as the AES-256 key, no pad/truncate
        printf 'TOTP_ENCRYPTION_KEY=%s\n' "$(openssl rand -hex 16)"
    } > "$ENV_FILE"
else
    say "reusing existing secrets in ${ENV_FILE}"
fi
chmod 600 "$ENV_FILE"

# --- 3. build the image ------------------------------------------------------
if [ "$SKIP_BUILD" = "1" ]; then
    say "skipping build (-SkipBuild)"
    docker image inspect "$IMAGE" >/dev/null 2>&1 || {
        echo "ERROR: -SkipBuild given but ${IMAGE} does not exist on this host" >&2; exit 1; }
else
    say "building ${IMAGE} (several minutes on a cold cache)"
    docker build \
        --build-arg "VERSION=${VERSION}" \
        --build-arg "BUILD_TIME=${BUILD_TIME}" \
        --build-arg "COMMIT=${COMMIT}" \
        --build-arg "UID=${PUID}" \
        --build-arg "GID=${PGID}" \
        -t "$IMAGE" "$SRC_DIR"
fi

# --- 4. compose file with CasaOS metadata ------------------------------------
say "writing compose for CasaOS"
cat > "$COMPOSE_FILE" <<YAML
name: ${APP_ID}
services:
    app:
        container_name: ${APP_ID}
        image: ${IMAGE}
        pull_policy: never
        restart: unless-stopped
        environment:
            TZ: ${TZ_NAME}
            PUID: "${PUID}"
            PGID: "${PGID}"
            SERVER_ADDRESS: ":8080"
            BASE_URL: http://${HOST_IP}:${PORT}
            DATA_DIR: /app/data
            BACKUP_DIR: /app/backups
            LOGS_DIR: /app/data/logs
        labels:
            icon: ${ICON_URL}
        networks:
            default: null
        ports:
            - mode: ingress
              target: 8080
              published: "${PORT}"
              protocol: tcp
        volumes:
            - type: bind
              source: ${DATA_ROOT}/data
              target: /app/data
              bind:
                create_host_path: true
            - type: bind
              source: ${DATA_ROOT}/backups
              target: /app/backups
              bind:
                create_host_path: true
            - type: bind
              source: ${ENV_FILE}
              target: /app/.env
              read_only: true
        x-casaos:
            ports:
                - container: "8080"
                  description:
                    en_us: Web UI and REST API (published on ${PORT})
            volumes:
                - container: /app/data
                  description:
                    en_us: 'SQLite database, rclone remote configs and job logs'
                - container: /app/backups
                  description:
                    en_us: Database backups written by the built-in backup job
                - container: /app/.env
                  description:
                    en_us: 'JWT and TOTP keys, generated on the host at first deploy'
networks:
    default:
        name: ${APP_ID}_default
x-casaos:
    architectures:
        - amd64
    author: Muath
    category: Utilities
    description:
        en_us: 'Managed file transfer built on rclone. Define remotes and transfer configs, schedule them with cron, and watch every run from the web UI with per-job logs, retries and notifications. rclone ships inside the image, so nothing needs installing on the host.'
    developer: Muath
    icon: ${ICON_URL}
    is_uncontrolled: false
    main: app
    port_map: "${PORT}"
    scheme: http
    store_app_id: ${APP_ID}
    tagline:
        en_us: Scheduled file transfers, powered by rclone
    thumbnail: ""
    tips:
        custom: |
            First login is admin@example.com / admin -- change it immediately
            under Settings. It is an admin account reachable from the whole LAN.

            Data lives on the host in ${DATA_ROOT} (database, rclone configs,
            logs and backups), so rebuilding the image never loses a job.

            JWT_SECRET and TOTP_ENCRYPTION_KEY were generated once into
            ${ENV_FILE} and are mounted read-only. Deleting that file logs every
            session out and makes existing 2FA secrets undecryptable.
    title:
        en_us: GoMFT
YAML

# --- 5. install or update through CasaOS -------------------------------------
# Captured first, then matched with a herestring: piping straight into `grep -q`
# makes grep close the pipe on the first match, casaos-cli dies of SIGPIPE and
# `pipefail` reports the whole pipeline as a miss.
INSTALLED="$(casaos-cli app-management list apps 2>/dev/null || true)"
if grep -qE "^${APP_ID}[[:space:]]" <<< "$INSTALLED"; then
    say "app already registered -- applying update"
    casaos-cli app-management apply "$APP_ID" -f "$COMPOSE_FILE"
else
    say "registering new CasaOS app"
    casaos-cli app-management install -f "$COMPOSE_FILE"
fi

# --- 6. wait for it to answer ------------------------------------------------
say "waiting for the web UI"
for _ in $(seq 1 60); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/login" || true)"
    if [ "$code" = "200" ]; then
        say "web UI responding (HTTP 200)"
        exit 0
    fi
    sleep 2
done

echo "ERROR: no HTTP 200 from /login after 120s. Last container logs:" >&2
docker logs --tail 50 "$APP_ID" >&2 || true
exit 1
'@

# --- Preflight ---------------------------------------------------------------
Write-Step 'Preflight'

foreach ($tool in 'ssh', 'scp', 'tar', 'git') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "'$tool' is not on PATH -- it is required to deploy"
    }
}

$hostLine = & ssh -G $SshHost 2>$null | Select-String -Pattern '^hostname\s+(.+)$' | Select-Object -First 1
if (-not $hostLine) { throw "Could not resolve HostName for SSH alias '$SshHost' from ~/.ssh/config" }
$hostIp = $hostLine.Matches[0].Groups[1].Value.Trim()
Write-Note "$SshHost -> $hostIp"

& ssh -o BatchMode=yes -o ConnectTimeout=10 $SshHost 'command -v docker >/dev/null && command -v casaos-cli >/dev/null && sudo -n true' | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Preflight failed on '$SshHost': needs docker, casaos-cli and passwordless sudo"
}
Write-Note 'docker, casaos-cli and sudo present'

# Refuse to steal a port another app already publishes.
$portOwner = (& ssh $SshHost "docker ps --filter publish=$Port --format '{{.Names}}'" | Out-String).Trim()
if ($portOwner -and $portOwner -ne $AppId) {
    throw "Port $Port on $SshHost is already published by container '$portOwner'. Pass -Port <free port>."
}

$version = (& git -C $RepoRoot describe --tags --always --dirty 2>$null | Out-String).Trim()
if (-not $version) { $version = 'dev' }
$commit = (& git -C $RepoRoot rev-parse --short HEAD 2>$null | Out-String).Trim()
if (-not $commit) { $commit = 'unknown' }
$buildTime = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
Write-Note "version=$version commit=$commit"
if ($version -like '*-dirty') { Write-Note 'working tree has uncommitted changes -- deploying them as-is' }

# --- Package the working tree ------------------------------------------------
Write-Step 'Packing source'

$stage   = Join-Path ([System.IO.Path]::GetTempPath()) "gomft-deploy-$PID"
$null    = New-Item -ItemType Directory -Path $stage -Force
$tarball = Join-Path $stage 'src.tar.gz'
$shFile  = Join-Path $stage 'remote.sh'

try {
    # Anything derived, huge or host-owned. static/dist especially: the
    # frontend stage generates it and a stale local copy would overwrite the
    # fresh one via the Dockerfile's `COPY . .`.
    $excludes = @(
        '.git', 'node_modules', 'docs/node_modules', 'docs/build',
        'static/dist', 'data', 'backups', 'tmp', '.shots', 'screenshots',
        '.env', 'gomft', 'gomft.exe'
    )
    $tarArgs = @('-czf', $tarball)
    foreach ($e in $excludes) { $tarArgs += @('--exclude', "./$e") }
    $tarArgs += @('-C', $RepoRoot, '.')
    Invoke-Native -Exe 'tar' -Arguments $tarArgs -What 'tar'

    $sizeMb = [math]::Round((Get-Item $tarball).Length / 1MB, 1)
    Write-Note "src.tar.gz is $sizeMb MB"
    if ($sizeMb -gt 50) { Write-Note 'WARNING: unexpectedly large -- an exclude may have missed' }

    # LF endings, no BOM: bash will not run the script otherwise.
    [System.IO.File]::WriteAllText(
        $shFile,
        ($RemoteScript -replace "`r`n", "`n"),
        (New-Object System.Text.UTF8Encoding $false))

    # --- Upload --------------------------------------------------------------
    Write-Step "Uploading to $SshHost"
    Invoke-Native -Exe 'ssh' -Arguments @($SshHost, 'rm -rf /tmp/gomft-deploy && mkdir -p /tmp/gomft-deploy') -What 'remote staging'
    Invoke-Native -Exe 'scp' -Arguments @('-q', $tarball, $shFile, "${SshHost}:/tmp/gomft-deploy/") -What 'scp'

    # --- Build, register, verify ---------------------------------------------
    Write-Step 'Building and installing on the host'
    $skip = if ($SkipBuild) { '1' } else { '0' }
    Invoke-Native -Exe 'ssh' -Arguments @(
        $SshHost,
        "bash /tmp/gomft-deploy/remote.sh '$AppId' '$Port' '$DataRoot' '$RemoteSrc' '$hostIp' '$Timezone' '$version' '$buildTime' '$commit' '$skip'"
    ) -What 'remote deploy'
}
finally {
    Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
    & ssh $SshHost 'rm -rf /tmp/gomft-deploy' 2>$null | Out-Null
}

Write-Step 'Deployed'
Write-Host "    GoMFT   http://${hostIp}:$Port" -ForegroundColor Green
Write-Host "    CasaOS  http://${hostIp}  (app '$AppId')" -ForegroundColor Green
Write-Host "    Login   admin@example.com / admin  -- change it on first sign-in" -ForegroundColor Yellow
