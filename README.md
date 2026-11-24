# Fishbowl Advanced in Docker

One container that runs **Fishbowl Advanced Server** on Linux with everything it
needs: **Java 21**, **MySQL 8.4**, and **Fishbowl's own Linux installer**. The
Linux part lives inside the container, so the computer that runs Docker can be
**Linux**, **macOS** or **Windows**. It comes with a web page, **the Fishbowl
page**, where you do everything else in your browser:

- first-time setup: Fishbowl's license agreement, your license key (or the
  14 Day Trial)
- restoring an existing `.sql` backup through Fishbowl Server Administration's
  **Restore** tab, or creating a new company database
- **Fishbowl Server Administration** and the **Fishbowl Client**, each in its
  own browser tab
- starting, stopping and restarting Fishbowl Server, and upgrading to a new
  Fishbowl version

The container starts by itself whenever Docker starts and never stops to wait
for a terminal: whatever still needs you waits on the page.

Repository: **https://github.com/cesiumskater/Docker_Testing**

## Quick start

Docker has to be installed and running first: Docker Desktop on macOS and
Windows, Docker Engine or Docker Desktop on Linux
([Requirements](#2-requirements)).

**How the commands are written.** Linux and macOS share one set of commands,
since bash and zsh read them the same way. Windows gets its own set, written for
**PowerShell** (what Windows Terminal opens by default), because PowerShell
doesn't continue a command on the next line with `\` and a few tools differ. A
block without a label works the same on all three. Every `docker build`,
`docker run` and `docker pull` asks for `--platform linux/amd64`: the image is
x86-64, so the flag changes nothing on an x86-64 computer, and on a Mac with
Apple Silicon it has Docker run the image under emulation.

Each block builds the image straight from GitHub (which also downloads the
Fishbowl installer), tags it with its Fishbowl version, starts the container,
and prints the link to the Fishbowl page.

**Linux and macOS**

```bash
docker build --platform linux/amd64 -t fishbowl "https://github.com/cesiumskater/Docker_Testing.git#main"
docker tag fishbowl "fishbowl:$(docker run --rm --platform linux/amd64 fishbowl version)"
docker run -d --platform linux/amd64 --name fishbowl --restart always --stop-timeout 180 \
  -p 2456:2456 -p 28192:28192 -p 127.0.0.1:6080:6080 \
  -e TZ=America/Denver \
  -v fishbowl-mysql:/var/lib/mysql \
  -v fishbowl-app:/opt/Fishbowl \
  -v fishbowl-data:/var/lib/fishbowl \
  --read-only --tmpfs "/run:mode=0755" --tmpfs "/tmp:exec,mode=1777" --tmpfs "/var/tmp:mode=1777" \
  --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
  --cap-add KILL --cap-add SETGID --cap-add SETUID \
  --security-opt no-new-privileges:true --pids-limit 4096 \
  fishbowl
docker exec fishbowl fishbowl-link
```

**Windows (PowerShell)**

```powershell
docker build --platform linux/amd64 -t fishbowl "https://github.com/cesiumskater/Docker_Testing.git#main"
docker tag fishbowl "fishbowl:$(docker run --rm --platform linux/amd64 fishbowl version)"
docker run -d --platform linux/amd64 --name fishbowl --restart always --stop-timeout 180 -p 2456:2456 -p 28192:28192 -p 127.0.0.1:6080:6080 -e TZ=America/Denver -v fishbowl-mysql:/var/lib/mysql -v fishbowl-app:/opt/Fishbowl -v fishbowl-data:/var/lib/fishbowl --read-only --tmpfs "/run:mode=0755" --tmpfs "/tmp:exec,mode=1777" --tmpfs "/var/tmp:mode=1777" --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER --cap-add KILL --cap-add SETGID --cap-add SETUID --security-opt no-new-privileges:true --pids-limit 4096 fishbowl
docker exec fishbowl fishbowl-link
```

The Windows `docker run` is one long line on purpose. Pasted into PowerShell,
the Linux and macOS version's `\` line breaks give `docker: invalid reference
format`, then `The term '-p' is not recognized`.

Open the link in a browser on the same computer. The page walks you through
the rest: setup (about half a minute), then your company database (restore a
`.sql` backup or create a new one), after which Fishbowl Server starts by
itself. Fishbowl Clients connect to this computer's name or IP address on
**port 2456**.

`TZ` is your time zone as a name from the
[tz database](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones),
such as `America/Denver` or `Europe/London`. That holds on Windows too: a
Windows name like *Mountain Standard Time* doesn't work here.

### With Docker Compose instead of `docker run`

`compose.yaml` runs the layout for a server that runs for years: Fishbowl
Server, the page, the windows, MySQL, a nightly backup, an HTTPS front door and
an outbound allowlist, each in its own container, none of them running as root.
It takes a few more steps than the single container (six volumes, the MySQL root
password file, the name for the HTTPS certificate), all in [section
13](#13-the-compose-stack). Both use the name `fishbowl` and the same three data
volumes, so run one or the other; a site moves between them with its data.

## Contents

1. [What this is, and the support position](#1-what-this-is-and-the-support-position)
2. [Requirements](#2-requirements)
3. [Get the image](#3-get-the-image)
4. [Start it, and starting automatically](#4-start-it-and-starting-automatically)
5. [The Fishbowl page](#5-the-fishbowl-page)
6. [First-time setup](#6-first-time-setup)
7. [Your company database: restore a .sql backup or create a new one](#7-your-company-database-restore-a-sql-backup-or-create-a-new-one)
8. [Server Administration in its browser window](#8-server-administration-in-its-browser-window)
9. [The Fishbowl Client in its browser window](#9-the-fishbowl-client-in-its-browser-window)
10. [Day-to-day use](#10-day-to-day-use)
11. [Backups and your data](#11-backups-and-your-data)
12. [Updating to a new Fishbowl version](#12-updating-to-a-new-fishbowl-version), and the [weekly maintenance](#weekly-maintenance-set-it-up-once)
13. [The Compose stack](#13-the-compose-stack): several containers, none of them root, HTTPS, nightly backups
14. [Security](#14-security)
15. [Maintaining this repository](#15-maintaining-this-repository)
16. [Reference](#16-reference)
17. [Troubleshooting](#17-troubleshooting)
18. [Versions and verification](#18-versions-and-verification)

---

## 1. What this is, and the support position

This repository builds a Docker image for running Fishbowl Advanced Server on
Linux. It follows the knowledge article *Installing Fishbowl Advanced on Linux*
(validated on Fedora 44 with MySQL 8.4.10 and Temurin JDK 21; called "the
install guide" below) and adapts it to a container.
**[MAINTAINER: link the article here if it's public.]**

**Fishbowl does not support Linux.** Fishbowl's
[Fishbowl for Linux](https://help.fishbowlinventory.com/advanced/s/article/Fishbowl-for-Linux)
article says that "Linux is not officially supported, Fishbowl Support will not
install or troubleshoot Linux", and the
[release notes](https://help.fishbowlinventory.com/advanced/s/article/Release-Notes)
label the Linux installer "Documentation only". The same holds for Fishbowl
running in this container, whatever system the container runs on.

> **[MAINTAINER: state here whether this repository is official / endorsed by
> Fishbowl, and where people should report problems with it.]**

### How it fits together

| Piece | Where it comes from | When |
|---|---|---|
| Fedora 44 base | `registry.fedoraproject.org/fedora:44` | image build |
| MySQL 8.4.x | Fedora's `mysql-server` package, pinned to `8.4.*` | image build |
| Java 21 | Eclipse Temurin `temurin-21-jdk` from Adoptium's repository | image build |
| Fishbowl installer | the one `Fishbowl-*.sh` file on this repository's `fishbowl-installer` release | image build |
| The Fishbowl page | a small web server in the container (`portal.py`), port 6080 | always running |
| Browser windows | TigerVNC's `Xvnc` (a virtual screen that resizes with the browser tab), `openbox` (window manager), `websockify` and the noVNC viewer, all from Fedora | while a window is open |
| Fishbowl itself | Fishbowl's installer, run unattended | **after you accept the license agreement on the page** |
| Company database | restored or created in Fishbowl Server Administration | after setup |
| System updates | every package update published so far, applied inside the build; the weekly maintenance rebuilds | image build, weekly |

**Why Fedora 44 with Fedora's MySQL and Temurin?** Fedora is the distribution
the install guide lab-tested (it marks the others as tested conceptually), with
exactly these packages. The official `mysql:8.4` and `eclipse-temurin:21` images
would pin versions just as well, but neither the guide nor this repository
tested them with Fishbowl. Whatever the source, the image build **fails** unless
`mysqld` reports 8.4.x and Java reports 21 (per the guide, Fishbowl rejects
MySQL 9.x and MariaDB, and its installer accepts only Java 21).

## 2. Requirements

| | |
|---|---|
| Docker | **Linux:** Docker Engine (BuildKit, its default builder) plus the Docker Compose plugin (`docker compose`) if you use Compose, or Docker Desktop for Linux. **macOS:** Docker Desktop. **Windows:** Docker Desktop in its default **Linux containers** mode. Tested with Docker Engine 29.9.3 on Linux; see [what was verified](#what-was-verified-by-running-it-and-what-wasnt) for the rest. |
| Terminal | **Linux:** bash or zsh. **macOS:** Terminal (zsh) or any other shell. **Windows:** **PowerShell**, either the built-in Windows PowerShell 5.1 or PowerShell 7. Not Command Prompt or Git Bash: their quoting and paths differ from both sets of commands here. |
| CPU | x86-64 (`linux/amd64`). On a Mac with Apple Silicon, Docker Desktop runs the image under emulation (slower, and untested here); turn on **Use Rosetta for x86_64/amd64 emulation on Apple Silicon** in Docker Desktop's **General** settings for the faster kind. Running natively on ARM64 is untested, and so is Windows on ARM. |
| Internet | To build: access to GitHub, Fedora's package mirrors and Adoptium's repository. |
| Browser | A current browser on the computer that runs Docker, for the Fishbowl page. Tested with headless Chromium. |
| Disk | About **3.7 GB** for the image, about **1.2 GB** for a fresh install's volumes plus your databases and backups, and about **1.5 GB** of temporary space during install and upgrades. Plan on **10 GB free**. |
| RAM | Plan on **12 GB available to Docker** for Fishbowl Server and MySQL, plus about **2 GB** while the browser windows are open. Details below. |
| Ports | **2456** reachable by Fishbowl Clients. **6080** on 127.0.0.1 for the Fishbowl page. Both must be free on the computer ([a port is already in use](#a-port-is-already-in-use)). |

**Why 12 GB.** This is an estimate from the configured limits, not a
measurement under load. Fishbowl Server is set to an **8192 MB** Java heap (as
the install guide requires), and Java uses memory beyond the heap too (roughly
another 0.5–1 GB, an estimate). Fishbowl's own MySQL settings use a **2 GB**
InnoDB buffer pool plus per-connection buffers, so MySQL needs roughly
2.5–3 GB. That adds up to about 11–12 GB when both are fully used. At idle with
a new database the container used about 1.3–1.6 GB in testing, and it ran on a
test machine with 7.8 GB of RAM: the heap only grows as needed. With less
memory than the estimate, the container can be killed when Fishbowl gets busy.

**The browser windows** run real Fishbowl programs inside the container. In
testing, the Fishbowl Client window took roughly 1.5 GB while open (it has a
Chromium-based web view built in) and Server Administration a few hundred MB.
They stop using memory when you close them.

### How much memory Docker gets

- **Linux with Docker Engine:** no separate limit. Containers use the
  computer's memory.
- **macOS, Linux with Docker Desktop, and Windows with Docker Desktop's
  Hyper-V backend:** Docker Desktop runs containers in a virtual machine whose
  **Memory limit** defaults to 50% of the computer's memory. Raise it in Docker
  Desktop's settings under **Resources**, **Advanced** (Docker's documentation
  calls the section *VM resources*).
- **Windows with the WSL 2 backend** (Docker Desktop's usual setup): that
  setting isn't there, because the memory belongs to WSL itself, which also
  takes 50% of the computer's memory by default. It's set in a file named
  `.wslconfig` in your user folder. Open it in Notepad (Notepad offers to create
  it if it doesn't exist):

  ```powershell
  notepad "$env:USERPROFILE\.wslconfig"
  ```

  Put this in it, with the amount Docker should have, and save:

  ```ini
  [wsl2]
  memory=14GB
  ```

  Then quit Docker Desktop, run the command below, wait a few seconds, and
  start Docker Desktop again:

  ```powershell
  wsl --shutdown
  ```

Leave enough for the computer itself. On a computer with 16 GB of RAM that
also runs other programs, Fishbowl can run short of memory when it gets busy.

## 3. Get the image

### Build it from GitHub (recommended)

The same on Linux, macOS and Windows:

```sh
docker build --platform linux/amd64 -t fishbowl "https://github.com/cesiumskater/Docker_Testing.git#main"
docker tag fishbowl "fishbowl:$(docker run --rm --platform linux/amd64 fishbowl version)"
```

Docker downloads this repository from GitHub and builds the image. The build
also downloads the Fishbowl installer (about 721 MiB) from this repository's
`fishbowl-installer` release, checks it against the size and SHA-256 that GitHub
reports, and stops with a clear message if the release has no installer or more
than one. No credentials are needed while the repository is public.

The second command gives the image a second name with its Fishbowl version
(for example `fishbowl:2026.11`), so that version stays available after you
build a newer one.

The quotes around the address matter in zsh: without them, a zsh with the
`extendedglob` option reads `#main` as part of a file pattern.

### Or let Docker Compose build it

`compose.yaml` builds the same image from GitHub the first time it's needed
(`docker compose up -d`), or on request, in the folder that holds `compose.yaml`
(downloading it is in the [Quick start](#with-docker-compose-instead-of-docker-run)):

```sh
docker compose build
```

### Or pull a ready-made image (only once it's published)

If this repository's GitHub Actions workflow has published the image (see
[Maintaining this repository](#15-maintaining-this-repository)), you can skip
the build:

```sh
docker pull --platform linux/amd64 ghcr.io/cesiumskater/docker_testing:latest
docker tag ghcr.io/cesiumskater/docker_testing:latest fishbowl
```

## 4. Start it, and starting automatically

**Linux and macOS**

```bash
docker run -d --platform linux/amd64 --name fishbowl --restart always --stop-timeout 180 \
  -p 2456:2456 -p 28192:28192 -p 127.0.0.1:6080:6080 \
  -e TZ=America/Denver \
  -v fishbowl-mysql:/var/lib/mysql \
  -v fishbowl-app:/opt/Fishbowl \
  -v fishbowl-data:/var/lib/fishbowl \
  --read-only --tmpfs "/run:mode=0755" --tmpfs "/tmp:exec,mode=1777" --tmpfs "/var/tmp:mode=1777" \
  --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
  --cap-add KILL --cap-add SETGID --cap-add SETUID \
  --security-opt no-new-privileges:true --pids-limit 4096 \
  fishbowl
```

**Windows (PowerShell)**

```powershell
docker run -d --platform linux/amd64 --name fishbowl --restart always --stop-timeout 180 -p 2456:2456 -p 28192:28192 -p 127.0.0.1:6080:6080 -e TZ=America/Denver -v fishbowl-mysql:/var/lib/mysql -v fishbowl-app:/opt/Fishbowl -v fishbowl-data:/var/lib/fishbowl --read-only --tmpfs "/run:mode=0755" --tmpfs "/tmp:exec,mode=1777" --tmpfs "/var/tmp:mode=1777" --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER --cap-add KILL --cap-add SETGID --cap-add SETUID --security-opt no-new-privileges:true --pids-limit 4096 fishbowl
```

For the Compose stack instead (several containers, HTTPS, nightly backups), see
[section 13](#13-the-compose-stack).

| Option | Why |
|---|---|
| `-d` | Runs in the background. No terminal is needed at any point. |
| `--platform linux/amd64` | The image is x86-64. Changes nothing on an x86-64 computer; on a Mac with Apple Silicon, Docker runs it under emulation. |
| `--restart always` | Starts the container again whenever Docker starts, and whenever it stops for a reason other than `docker stop`. |
| `--stop-timeout 180` | Gives Fishbowl Server and MySQL up to 3 minutes to shut down cleanly. |
| `-p 2456:2456` | Fishbowl Clients connect here. |
| `-p 28192:28192` | Fishbowl's API ("Legacy Port"): integrated apps and integrations on other computers connect here. |
| `-p 127.0.0.1:6080:6080` | The Fishbowl page, reachable from this computer only. See [Security](#14-security) before changing it. |
| `-e TZ=…` | Your time zone, as a tz database name (Fishbowl and MySQL use it for dates). Defaults to UTC. |
| the three `-v` | Your installation and data. They outlive the container: remove and recreate it any time. |
| `--read-only` and the three `--tmpfs` | The image can't change while it runs; updates come from rebuilds ([section 12](#updates-to-the-system-inside-the-container-mysql-java-and-the-rest)). `/run`, `/tmp` and `/var/tmp` live in memory and start empty; everything that lasts is on the volumes. `/tmp` keeps the usual permission to run programs from it, as Java tools often expect (not tested without it). |
| `--cap-drop ALL` and the six `--cap-add` | Keeps only what start-up needs to hand MySQL, Fishbowl and the page their own users and files. |
| `--security-opt no-new-privileges:true` | No process in the container can gain privileges it didn't start with. |
| `--pids-limit 4096` | Caps processes and threads, so a runaway can't exhaust the computer. |

**Starting automatically.** `--restart always` (Compose: `restart: always`)
starts the container whenever Docker starts. Per Docker's documentation, a
container you stop by hand stays stopped only until Docker itself restarts, so
it comes back after a reboot even if you ran `docker stop` before. Docker itself
has to start with the computer:

- **macOS and Windows (Docker Desktop):** in Docker Desktop's **Settings →
  General**, turn on **Start Docker Desktop when you sign in to your computer**
  (off by default). Docker Desktop starts when you *sign in*, not at boot, so
  Fishbowl Server runs only while someone is signed in.
- **Linux with Docker Desktop:** the same setting, or
  `systemctl --user enable docker-desktop`. It also starts at sign-in.
- **Linux with Docker Engine** (no Desktop; starts at boot, before anyone signs
  in): `sudo systemctl enable --now docker`. That's the better fit for a server
  that should run with nobody signed in.

Whatever the system, a computer that sleeps takes Fishbowl Server with it, so
turn sleep off on the one that serves Fishbowl Clients.

A container you created without `--restart always` gets it with
`docker update --restart always fishbowl`. To keep it stopped for good,
`docker update --restart no fishbowl`, then `docker stop fishbowl`. Both work the
same on every system.

**Inside the container nothing waits on a terminal.** First-time setup, a
missing company database and new-version upgrades all wait on the Fishbowl page
while the container stays up. If Fishbowl Server or MySQL stops unexpectedly
(a crash, the out-of-memory killer), the container starts it again in place.
After four such stops within ten minutes it stops trying: for Fishbowl Server it
says so on the page, and for MySQL the container exits so that Docker's restart
policy starts it fresh. Otherwise the container only exits when MySQL can't
start at all, or when another container is already using the same volumes.

**Docker Desktop's Run button** (in the Images list) starts a container with no
published ports unless you fill them in under its optional settings, so the
page can't be reached, and with unnamed volumes (see the warning in
[First-time setup](#6-first-time-setup)). Use the command above instead.

## 5. The Fishbowl page

**http://localhost:6080/** on the computer that runs Docker.

The page is protected by an **access code** (three groups of four letters and
digits). The container makes one at its first start, keeps it on the data
volume, and prints a link that includes it each time it starts. These print the
link, the same on every system:

```sh
docker exec fishbowl fishbowl-link
docker exec fishbowl fishbowl-link admin
docker exec fishbowl fishbowl-link client
```

The first is the page; `admin` goes straight to the Server Administration
window and `client` to the Fishbowl Client window. The log has the same link:
`docker logs fishbowl | grep code=` on Linux and macOS,
`docker logs fishbowl | Select-String code=` in PowerShell.

Opening a link with the code signs that browser in for 30 days (a cookie) and
removes the code from the address bar. You can also type the code on the
sign-in page. `docker exec fishbowl fishbowl-link --new-code` replaces the code
and signs every browser out.

The page checks the container every two seconds and shows what it's doing and
what it needs from you:

| The page says | What's going on |
|---|---|
| Fishbowl isn't installed yet | First-time setup is waiting for you ([section 6](#6-first-time-setup)). |
| Installing Fishbowl… | Setup is running (about half a minute in testing). |
| No company database is selected yet | Restore a backup or create a database ([section 7](#7-your-company-database-restore-a-sql-backup-or-create-a-new-one)). |
| Fishbowl Server is starting… | Usually under a minute. After an upgrade, or with a database from an older Fishbowl version, it updates the database first. |
| Fishbowl Server is running | Buttons: **Open Fishbowl Client**, **Open Server Administration**, **Restart**, **Stop**. |
| Fishbowl Server is stopped | You pressed Stop (or used the `admin` command). MySQL keeps running. **Start** brings it back. |
| Fishbowl Server didn't start | With Fishbowl's own reason, for example that it can't update the selected database. |
| Upgrade Fishbowl / Upgrading… | A newer Fishbowl is in the image ([section 12](#12-updating-to-a-new-fishbowl-version)). |
| An upgrade didn't finish | Run it again on the page; Fishbowl Server stays stopped until then. |
| Nothing is running: … | The volumes hold data this container didn't set up, or the image is older than the installed Fishbowl. The page and `docker logs` say what to do. |

## 6. First-time setup

The first time the container starts on empty volumes, the page shows the setup
form. Nothing is accepted or installed until you submit it.

1. **Fishbowl's license agreement.** The page shows the same text Fishbowl's
   installer shows (and links to the other version of the terms the installer
   carries). Read it and tick **I have read and accept Fishbowl's license
   agreement**. Accepting is your own act; nothing in this image accepts it for
   you. The container records when and how it was accepted, with a checksum of
   the exact text, in `/var/lib/fishbowl/state/eula/`.
2. **Your Fishbowl license.** Your license key and the company name exactly as
   it appears on your license, or **Start the 14 Day Fishbowl Trial** (Fishbowl
   registers a trial under the name "Trial").
3. **Nothing else.** There's no MySQL password to choose: the image sets one
   itself (see [The MySQL root password](#the-mysql-root-password) below). It's
   never shown: Server Administration's Password fields come filled in with it.

Then **Install Fishbowl**. The container initializes MySQL, sets its root password,
checks that MySQL is 8.4.x with `lower_case_table_names = 1`, applies the
guide's security cleanup, runs Fishbowl's installer unattended and checks the
memory settings. **In testing that took 22 to 26 seconds.** If anything fails,
the page shows why, nothing is left half-installed, and you can try again.

**Set automatically:** "Server with Client" install in `/opt/Fishbowl`, MySQL on
`localhost:3306`, server memory **8192 MB**, client memory **2048 MB**, the
install guide's MySQL settings (`lower_case_table_names=1`,
`sql-mode=STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION`), Fishbowl's own MySQL
tuning from its `server/bin/my.cnf`, and Fishbowl's Auto Updates set to *Never*
(new versions come from new images, see [section 12](#12-updating-to-a-new-fishbowl-version)).

**Prefer a terminal?** `docker exec -it fishbowl fishbowl-setup` asks the same
three things (the agreement opens in a pager and only a typed `yes` accepts it),
then hands the answers to the container the same way the page does. It works the
same in PowerShell.

**"This container has no named volumes."** A container started without the
three `-v` options (for example from Docker Desktop's Run button) gets unnamed
volumes from Docker. Fishbowl works on them, but they belong to that one
container: a new container won't find them by itself, and removing the
container together with its volumes deletes your install and database. The page
warns about this and asks for an extra tick before installing; the log prints
the commands to start over with named volumes, or to reuse the unnamed ones.
The log writes them the Linux and macOS way, with `\` line breaks: in
PowerShell, put each command on one line and leave the `\` out.

## 7. Your company database: restore a .sql backup or create a new one

Fishbowl Server can't start without a company database. After setup the page
says **No company database is selected yet** and asks whether you have a
Fishbowl backup (a `.sql` file) to restore. Both ways happen in **Fishbowl
Server Administration**, which opens in its own browser tab; Fishbowl Server
starts by itself as soon as a database is selected.

**The image ships with no database**, not even a sample one. A new container's
MySQL holds only MySQL's own system databases until you restore or create one
here. Whatever you restore or create lives in the `fishbowl-mysql` volume, so it
stays when the container is recreated (`docker compose up -d --force-recreate`,
or `docker rm -f` and `docker run` again). To start over with no database at
all, remove the volumes as well. That also removes the Fishbowl installation, so
setup runs again (license agreement and license). Take a backup first if you
want to keep anything ([section 11](#11-backups-and-your-data)). With Docker
Compose:

```
docker compose down -v
docker compose up -d
```

If you started it with `docker run`, remove the container and its three volumes,
then start it again with the same `docker run` command:

```
docker rm -f fishbowl
docker volume rm fishbowl-mysql fishbowl-app fishbowl-data
```

These are the same in bash, zsh and PowerShell.

### Restore a .sql backup

Fishbowl's own backups are `.sql` files named like
`MyCompany_2026-11-15-15-42.sql`, made with **Backup Database** in Server
Administration or by the Client's Schedule module.

1. **Upload it** in the **Files and backups to restore** box on the page. Any file type can be uploaded, not only `.sql` (the page lists everything in the import folder and reads the Fishbowl version only from `.sql` files). It lands
   in the container's **import** folder, and the page shows which Fishbowl
   version made it (read from the file's `databaseversion` table). Larger files
   simply take longer. Copying one in works too, for example from your
   Downloads folder:

   **Linux and macOS**

   ```bash
   docker cp ~/Downloads/MyCompany_2026-11-15-15-42.sql fishbowl:/var/lib/fishbowl/import/
   ```

   **Windows (PowerShell)**

   ```powershell
   docker cp "$HOME\Downloads\MyCompany_2026-11-15-15-42.sql" fishbowl:/var/lib/fishbowl/import/
   ```

2. **Open Server Administration** (button on the page) and go to the
   **Restore** tab.
3. Click the **magnifier** next to **Restore File**. The file chooser opens in
   a folder that contains **import**: double-click it, pick your file, **Open**.
4. **Database:** Fishbowl fills in a name from the file name: the part before
   the last underscore (`MyCompany_2026-11-15-15-42.sql` becomes `MyCompany`).
   Keep it or type another name (letters, numbers and underscores). A **new
   name** restores the backup next to anything that's already there, which is
   the safe choice. An **existing name** replaces that database: Fishbowl warns
   that all data not in the backup will be lost.
5. **Password:** leave it as it is. Fishbowl fills it in, masked, and
   it's already the right one, so you never see or type it. (Cleared it by mistake? Close
   Server Administration and open it again from the page, and Fishbowl fills it in
   again.) Host `localhost`, Port `3306` and Username `root` stay as they are.
6. Click **Restore**, confirm with **Yes**, and wait for **"Database has been
   restored."** (a 54 MB backup took 44 seconds in testing). Click **OK**.
7. Go to the **Database** tab. The restore has already added the database to
   the list: click it, then **OK**, and **OK** again on "Database Connection has
   been changed to: …".

Server Administration closes and Fishbowl Server starts on that database.

**A backup from an older Fishbowl version** (the page shows the version next to
the file) is updated by Fishbowl Server the first time it starts on it. On a
large database that can take a while: the container waits as long as it takes
and logs a note every 5 minutes. **A trial installation can't do that.**
Fishbowl Server refuses with *"Trial accounts do not have access to update the
database"*: the page then says **Fishbowl Server didn't start** with that reason,
the container stays up, and the database is left exactly as restored (checked
table by table in testing). To use such a backup, enter a purchased license in
Server Administration (**License** tab) and start Fishbowl Server again, or
install with your license key in the first place. The page warns about this as
soon as you upload an older backup to a trial installation.

**A backup from a newer Fishbowl version** than the installed one: the page
warns that an older Fishbowl may not be able to use it. Restore it into the same
Fishbowl version or newer.

**Restoring while Fishbowl Server is running** works the same way, into a new
name. To switch Fishbowl to the restored database, select it on the Database
tab and click OK (step 7), then press **Restart Fishbowl Server** on the page.
Fishbowl Clients are disconnected for about 20 seconds.

**Replacing the database Fishbowl Server is using right now:** press **Stop
Fishbowl Server** on the page first, restore over it (its name in step 4), click
**Cancel** to close Server Administration, then press **Start Fishbowl Server**.

The import folder isn't cleaned up for you: **Remove** a file on the page when
you no longer need it. Files there aren't backups: they're copies of what you
uploaded.

`fishbowl-backup` files (`.sql.gz`, all of MySQL) aren't for the Restore tab;
use the `restore` command for those ([section 11](#11-backups-and-your-data)).

### Or create a new database

1. **Open Server Administration.** On the **Database** tab, click the green
   **+** on the right.
2. **Database:** a name for your company database (letters, numbers and
   underscores). Host `localhost`, Port `3306`, Username `root`.
3. **Password:** leave it as it is. Fishbowl fills it in, masked, and
   it's already the right one, so you never see or type it. (Cleared it by mistake? Click
   **Cancel** and **+** again, and Fishbowl fills it in again.) Click **Connect**.
4. Fishbowl asks for your **country** and **costing method** (Average,
   Standard, FIFO or LIFO costing). Fishbowl warns that *this setting cannot be
   changed once the wizard is complete.* Click **OK** and wait while Fishbowl
   creates the database (about a minute in testing).
5. Click **OK** to save, then **OK** on "Database Connection has been changed to: …".

Server Administration closes and Fishbowl Server starts. The first time someone
opens the Fishbowl Client on the new database, Fishbowl's first-time wizard
opens (Company, Admin Password, Next Steps).

## 8. Server Administration in its browser window

Fishbowl Server Administration is where Fishbowl's server settings live: the
company database, ports, memory, Auto Updates, the license, and restoring
backups. It's a desktop program, so the container runs it on a private virtual
screen and shows it in a browser tab.

### Opening and closing it

- **Open Server Administration** on the page, or the link from
  `docker exec fishbowl fishbowl-link admin`, or `docker exec fishbowl fishbowl-admin`
  (prints that link). It opens in a new tab, at the size of the tab.
- It can be opened while Fishbowl Server runs, while it's stopped or failed to
  start, and while no database is selected yet.
- **OK** saves your changes and closes it; **Cancel** closes it without saving.
  The tab then says it has closed and offers to open it again.
- Closing the browser tab doesn't close Server Administration: it keeps running
  in the container, and opening it again shows the same window. **Force close**
  (top right of the tab) ends it without saving.
- Everyone who opens it sees the same window.

**Steps and clipboard** (top right) opens a side panel with the restore and
create steps, the files in the import folder, and a clipboard box: to paste text
into a field, put it in the box, click the field in the window, and press
Ctrl+V. Text copied inside the window shows up in the box. It's Ctrl+V on a Mac
too, since the window is a Linux program.

### Changing settings while Fishbowl Server is running

When you click OK, Fishbowl says *"This setting will not take place until the
server is exited and restarted."* The page then shows **Changed settings are
waiting for a restart** (and the database Fishbowl will use afterwards, if that
changed). Press **Restart Fishbowl Server** when it suits you; Fishbowl Clients
are disconnected for about 20 seconds.

Fishbowl Server writes its settings file back from memory when it stops, which
would undo your changes. The container keeps a copy of what you changed and puts
it back before Fishbowl Server starts again (the log says `Applied the settings
changed in Server Administration`).

### The tabs

**Database:** your company databases. **+** adds one (a new name creates a
database through Fishbowl's wizard; an existing Fishbowl database is just
added), and the database selected when you click **OK** is the one Fishbowl
Server uses. A restore adds its database to this list by itself. The red bin is
Fishbowl's delete button (not tried here). Right-click a database for **Show
Version, Backup Database, Rebuild Database, Database Maintenance, Drop Database,
Optimize Database, Convert Character Sets, Run Support Queries** and **Send Copy
to Fishbowl**. Of those, only Backup Database was tried here
([section 11](#11-backups-and-your-data)).

**Server:**

| Setting | Notes for this container |
|---|---|
| Port (2456) | The port Fishbowl Clients use. If you change it, publish the new port instead (`-p NEW:NEW`, or the `ports:` line in `compose.yaml`) and recreate the container. |
| Secure Connection, Certificate, Certificate Password | Fishbowl uses a `.jks` certificate file for this. The file must be inside the container: copy it to the import folder like a `.sql` file. Not tested here. |
| Legacy Port (28192) | Not published. Publish it (`-p 28192:28192`) only if something you use still connects to it. |
| Inactivity Time | Fishbowl's inactivity timeout, in minutes. |
| Broadcast Server Location, Users can only be logged in once | Fishbowl's own options. |
| Server memory | Set to 8192 MB at install. A new value takes effect at the next restart; the log shows `Server memory changed in Server Administration: now …` and the heap in `Fishbowl Server is running (heap …)`. Keep Docker's memory limit above it ([section 2](#how-much-memory-docker-gets)). |
| Auto Updates | Set to *Never notify or update automatically* at install. Leave it: Fishbowl's download-and-apply options would update Fishbowl inside the container, skipping the license step and backup that new images do. |
| MySQL Server Location | `/usr/bin`. Leave it: Backup Database and Restore use MySQL's tools from there. |
| Enable read-only database user, Read-only user password | Fishbowl's read-only MySQL user. Fishbowl requires at least 8 characters with upper- and lower-case letters, a digit and a special character. |

**License:** the registered name and license key. This is where a purchased
license replaces the trial (not tested here: no real key was used). Restart
afterwards.

**Restore:** loads a `.sql` backup into a database
([section 7](#7-your-company-database-restore-a-sql-backup-or-create-a-new-one)).

## 9. The Fishbowl Client in its browser window

**Open Fishbowl Client** on the page (shown while Fishbowl Server runs) opens
the Fishbowl Client that's installed inside the container, connected to the
Fishbowl Server next to it, in a new tab. Its main window fills the tab and
follows it when you resize the tab.

- It's one Client: everyone who opens it shares the same window, and it uses
  about 1.5 GB of memory while open. It suits the person who looks after the
  server (a quick check, the first-time wizard on a new database). Everyone else
  installs the Fishbowl Client on their own computer and connects to port 2456.
- When the Client exits, the tab says so and offers to open it again. **Force
  close** ends it without asking Fishbowl.
- The clipboard box in **Steps and clipboard** works as in Server
  Administration.
- Restarting Fishbowl Server disconnects it like any other client; it then shows
  Fishbowl's login dialog.

**Fishbowl Clients on other computers** connect to the Docker host's **name or
IP address, port 2456** (or the computer's port you published instead, see
[a port is already in use](#a-port-is-already-in-use)). The client that comes
with 26.10 and 26.11 defaults to the server's web port (`ServerPort=2456`,
`UseWebConnection=true` in its `client.properties`).

The host's firewall has to let TCP 2456 in, and 28192 for integrated apps and
integrations on other computers. What Fishbowl itself needs to reach on the
internet is in [Network and firewall](#network-and-firewall-licenses-plugins-integrations).
None of the following was tried here:

- **Windows:** if other computers can't connect, add a rule in PowerShell
  opened with **Run as administrator**:

  ```powershell
  New-NetFirewallRule -DisplayName "Fishbowl Server (Docker)" -Direction Inbound -Protocol TCP -LocalPort 2456,28192 -Action Allow
  ```

- **macOS:** with the firewall on (**System Settings → Network → Firewall**),
  allow incoming connections for Docker when macOS asks.
- **Linux:** Docker usually opens published ports through its own firewall
  rules. If other computers still can't connect, open the port in your
  firewall, for example with firewalld:

  ```bash
  sudo firewall-cmd --permanent --add-port=2456/tcp --add-port=28192/tcp
  sudo firewall-cmd --reload
  ```

### Picture quality, and what it costs

The windows are drawn by a virtual screen (TigerVNC's Xvnc) inside the container
and sent to your browser, so the settings trade picture quality against CPU and
memory in the container. What this image does:

- **Full colour (24-bit)**, and text drawn with grey-scale smoothing. The
  Fishbowl windows start Java with `-Dawt.useSystemAAFontSettings=on` and
  `-Dswing.aatext=true`. Colour-fringed (LCD) text looks worse once the picture
  is compressed, so it isn't used.
- **High picture quality in the browser.** The viewer asks for JPEG quality 8 of
  9 (noVNC's own default is 6) for pictures such as item photos; text and flat
  colours are always sent exactly. Compression stays light (level 2), which is
  cheap for the container's CPU.
- **At most 30 screen updates a second** per viewer (the virtual screen's default
  is 60). Nothing is sent while nothing changes, and no GPU or OpenGL emulation
  runs, because without a graphics card that would burn CPU for no visible gain.
- **Memory goes back.** While a window sits idle, its Java hands unused memory
  back to the container every minute (`-XX:G1PeriodicGCInterval=60000`). This
  applies to the Server Administration and Client windows only. Fishbowl Server
  itself is not touched.
- **The window follows the size of its browser tab**, up to 3840 x 2160, and the
  virtual screen only exists while the window is open.

What it doesn't do: the picture is drawn at one pixel per CSS pixel, so on a
display with Windows or macOS scaling above 100% the browser enlarges it and it
can look a little soft. A crisper picture there needs the window drawn at the
display's real resolution, with Java's own scaling turned up to match, and noVNC
has no setting for that. This hasn't been attempted, because it needs a
high-resolution screen to test on.

## 10. Day-to-day use

These commands are the same on Linux, macOS and Windows.

| Task | How |
|---|---|
| Open the page | the link from `docker exec fishbowl fishbowl-link` (your browser remembers the sign-in for 30 days) |
| Start, stop, restart Fishbowl Server | the buttons on the page (MySQL and the page keep running) |
| Stop or start the whole container | `docker stop fishbowl` / `docker start fishbowl` (Compose, in its folder: `docker compose stop` / `docker compose up -d`) |
| Status | the page, or `docker ps` (shows *healthy* once Fishbowl Server accepts connections) |
| Log | `docker logs -f fishbowl` (Ctrl+C stops following it) |
| Fishbowl Server's own log | `docker exec fishbowl tail -n 100 /opt/Fishbowl/logs/fbserver.log` |
| Back up all of MySQL | `docker exec -it fishbowl fishbowl-backup` |
| Versions in the image | `docker run --rm --platform linux/amd64 fishbowl versions` |

## 11. Backups and your data

### Where everything lives

| Volume | Mounted at | Holds |
|---|---|---|
| `fishbowl-mysql` | `/var/lib/mysql` | MySQL's data directory: your Fishbowl database(s). |
| `fishbowl-app` | `/opt/Fishbowl` | Fishbowl as installed: program files, settings (`server/bin/eve.properties`, which holds the license key and Fishbowl's encrypted database password), Fishbowl's logs and reports, and Fishbowl's own backups (`data/backups/`). |
| `fishbowl-data` | `/var/lib/fishbowl` | The container's state (setup and license-agreement records, installed version, the page's access code), the import folder (`import/`), `fishbowl-backup` files (`backups/`), logs, and the installer's temporary files. |

Docker keeps volumes inside its own storage (on macOS and Windows, inside
Docker Desktop's virtual machine), not in a folder you can open. The commands
below copy things out to the folder your terminal is in.

### Fishbowl's own backups

In Server Administration, right-click your database on the **Database** tab →
**Backup Database**. Fishbowl reports "Successfully ran database backup." and
writes `/opt/Fishbowl/data/backups/<database>_<YYYY-MM-DD-HH-MM>.sql`. Copy it
off the server, on any system (the first command lists the files, the second
copies one, with its name from the list, into the current folder):

```sh
docker exec fishbowl ls -l /opt/Fishbowl/data/backups/
docker cp fishbowl:/opt/Fishbowl/data/backups/MyCompany_2026-11-15-15-42.sql .
```

These files restore with the **Restore** tab ([section 7](#7-your-company-database-restore-a-sql-backup-or-create-a-new-one)).
Backups scheduled in the Fishbowl Client's Schedule module probably land in the
same folder; that wasn't tested.

### Backup of all of MySQL while running

A consistent `mysqldump` of every database (including MySQL's users), gzipped and
readable by root only, kept in the data volume. It needs a terminal (`-it`), and
it asks for the MySQL root password only if your installation has one of its own
(see [The MySQL root password](#the-mysql-root-password)), so run it on its own:

```sh
docker exec -it fishbowl fishbowl-backup
```

It ends with the file's name (`Backup written: …`), something like
`fishbowl-backup-20261117T163000Z.sql.gz` (the time is UTC). To copy it into the
current folder, on any system, with your file's name:

```sh
docker cp fishbowl:/var/lib/fishbowl/backups/fishbowl-backup-20261117T163000Z.sql.gz .
```

To restore one, stop the container, run `restore`, and start the container
again, one step at a time: `restore` asks you to type `restore` (and the MySQL root password, if your
installation has one of its own), and lines pasted after it would land in its
questions.

```sh
docker stop fishbowl
```

**Linux and macOS**

```bash
docker run -it --rm --platform linux/amd64 \
  -v fishbowl-mysql:/var/lib/mysql -v fishbowl-app:/opt/Fishbowl -v fishbowl-data:/var/lib/fishbowl \
  fishbowl restore /var/lib/fishbowl/backups/fishbowl-backup-20261117T163000Z.sql.gz
```

**Windows (PowerShell)**

```powershell
docker run -it --rm --platform linux/amd64 -v fishbowl-mysql:/var/lib/mysql -v fishbowl-app:/opt/Fishbowl -v fishbowl-data:/var/lib/fishbowl fishbowl restore /var/lib/fishbowl/backups/fishbowl-backup-20261117T163000Z.sql.gz
```

```sh
docker start fishbowl
```

`restore` replaces the databases in the file. If the file isn't in the volume
already, `docker cp` it into `fishbowl:/var/lib/fishbowl/backups/` first; that
works on a stopped container.

### Whole-installation backup (all three volumes, container stopped)

The way to move the whole server to another machine, and the way back after an
upgrade you want to undo. It writes `fishbowl-volumes-<date>-<time>.tar.gz` into
the folder your terminal is in (the time in the name means a second backup never
overwrites the first):

**Linux and macOS**

```bash
docker stop fishbowl
docker run --rm --platform linux/amd64 --entrypoint tar \
  -v fishbowl-mysql:/volumes/mysql:ro -v fishbowl-app:/volumes/app:ro -v fishbowl-data:/volumes/data:ro \
  -v "$PWD":/backup fishbowl \
  -czf "/backup/fishbowl-volumes-$(date +%Y%m%d-%H%M%S).tar.gz" -C /volumes .
docker start fishbowl
```

**Windows (PowerShell)**

```powershell
docker stop fishbowl
docker run --rm --platform linux/amd64 --entrypoint tar -v fishbowl-mysql:/volumes/mysql:ro -v fishbowl-app:/volumes/app:ro -v fishbowl-data:/volumes/data:ro -v "${PWD}:/backup" fishbowl -czf "/backup/fishbowl-volumes-$(Get-Date -Format yyyyMMdd-HHmmss).tar.gz" -C /volumes .
docker start fishbowl
```

Restore into empty volumes with the same names (for example on a new machine,
which can run a different system than the old one). To go back after an upgrade,
when the volumes aren't empty, use [the steps in section
12](#if-something-goes-wrong-back-to-where-you-were) instead. Run it in the folder that
holds the file, with your file's name, then start the container normally:

**Linux and macOS**

```bash
docker run --rm --platform linux/amd64 --entrypoint tar \
  -v fishbowl-mysql:/volumes/mysql -v fishbowl-app:/volumes/app -v fishbowl-data:/volumes/data \
  -v "$PWD":/backup fishbowl \
  -xzpf /backup/fishbowl-volumes-20261117-093000.tar.gz -C /volumes
```

**Windows (PowerShell)**

```powershell
docker run --rm --platform linux/amd64 --entrypoint tar -v fishbowl-mysql:/volumes/mysql -v fishbowl-app:/volumes/app -v fishbowl-data:/volumes/data -v "${PWD}:/backup" fishbowl -xzpf /backup/fishbowl-volumes-20261117-093000.tar.gz -C /volumes
```

## 12. Updating to a new Fishbowl version

When a new Fishbowl Advanced version comes out, the installer on this
repository's GitHub release is replaced with the new one ([section
14](#15-maintaining-this-repository)). The steps below move your server to it.
Paste them one block at a time, in a terminal opened in the folder where the
backup file should go, and read what each block prints before going on.

Everything you have is in the three volumes: `fishbowl-mysql` (your databases),
`fishbowl-app` (Fishbowl, its settings and your license) and `fishbowl-data`
(the container's records, the import folder and backups). These steps replace
the image and the container around them and never delete a volume. Step 3 first
copies all three volumes into one file and reads it back, so you can always go
back to exactly where you were.

### Before you start: what keeps your data, and what deletes it

**Safe, and all that the steps use:** `docker build`, `docker tag`, `docker
stop`, `docker rm` without `-v`, `docker run` with the same three `-v`, `docker
compose build` and `docker compose up -d`.

**Deletes your data, so never run these during an update:** `docker compose
down -v` (or `--volumes`), `docker volume rm`, `docker volume prune`, `docker
system prune --volumes`, and in Docker Desktop **Troubleshoot → Clean / Purge
data** or **Reset to factory defaults**. Uninstalling Docker Desktop deletes its
volumes too.

**Disk space:** in testing, the backup file was 773 MB for a new installation
with a new company database. Yours adds your databases, compressed.

### Step 1: Keep the version you have

The same on every system:

```sh
docker tag fishbowl "fishbowl:$(docker run --rm --platform linux/amd64 fishbowl version)"
docker images fishbowl
```

The list shows the image twice: as `fishbowl`, and with its version, for
example `fishbowl:2026.11`. The version tag keeps it on your computer after the
new build takes the name `fishbowl`, and it's what you'd go back to.

### Step 2: Build the new version

Fishbowl keeps running while this builds, which takes a few minutes. The same
on every system:

```sh
docker build --platform linux/amd64 -t fishbowl "https://github.com/cesiumskater/Docker_Testing.git#main"
docker run --rm --platform linux/amd64 fishbowl version
```

With Compose, run `docker compose build` instead of the first line, in the
folder with `compose.yaml`. With the ready-made image from [section
3](#or-pull-a-ready-made-image-only-once-its-published), run its two lines
(`docker pull`, then `docker tag … fishbowl`) instead.

The last line prints the new version, for example `2026.11`. **Stop here if the
build ended with an error, or if it prints the version you already have:**
nothing has changed, and Fishbowl is still running as before. (The same version
means the release doesn't have the new installer yet.) Otherwise give the new
image its version tag too:

```sh
docker tag fishbowl "fishbowl:$(docker run --rm --platform linux/amd64 fishbowl version)"
```

### Step 3: Back up all three volumes

This stops Fishbowl, which disconnects Fishbowl Clients, and leaves it stopped
until step 4, so the backup holds exactly what you upgrade from. It writes
`fishbowl-volumes-<date>-<time>.tar.gz` into the folder your terminal is in,
then reads the whole file back and prints **Backup OK** with its name.

**Linux and macOS**

```bash
BACKUP="fishbowl-volumes-$(date +%Y%m%d-%H%M%S).tar.gz"
docker stop fishbowl
docker run --rm --platform linux/amd64 --entrypoint tar \
  -v fishbowl-mysql:/volumes/mysql:ro -v fishbowl-app:/volumes/app:ro -v fishbowl-data:/volumes/data:ro \
  -v "$PWD":/backup fishbowl -czf "/backup/$BACKUP" -C /volumes .
docker run --rm --platform linux/amd64 --entrypoint tar -v "$PWD":/backup fishbowl -tzf "/backup/$BACKUP" > /dev/null && echo "Backup OK: $BACKUP" || echo "BACKUP FAILED: don't go on"
```

**Windows (PowerShell)**

```powershell
$BACKUP = "fishbowl-volumes-$(Get-Date -Format yyyyMMdd-HHmmss).tar.gz"
docker stop fishbowl
docker run --rm --platform linux/amd64 --entrypoint tar -v fishbowl-mysql:/volumes/mysql:ro -v fishbowl-app:/volumes/app:ro -v fishbowl-data:/volumes/data:ro -v "${PWD}:/backup" fishbowl -czf "/backup/$BACKUP" -C /volumes .
docker run --rm --platform linux/amd64 --entrypoint tar -v "${PWD}:/backup" fishbowl -tzf "/backup/$BACKUP" > $null; if ($LASTEXITCODE -eq 0) { "Backup OK: $BACKUP" } else { "BACKUP FAILED: don't go on" }
```

**Go on only after Backup OK.** If it failed (a full disk is the usual reason),
free some space and run the block again. Until step 4, `docker start fishbowl`
brings your current version back up exactly as it was. The time in the name
means a later backup never overwrites this one. Keep the file until you're sure
the new version is fine, and keep a copy off this computer: it holds your
license key and all your data, so store it the way you'd store the database.

### Step 4: Start the new version on the same volumes

`docker rm` removes only the container; the volumes stay, and the new container
picks them up. Use the same `-p` and `TZ` values you started it with.

**Linux and macOS**

```bash
docker rm fishbowl
docker run -d --platform linux/amd64 --name fishbowl --restart always --stop-timeout 180 \
  -p 2456:2456 -p 28192:28192 -p 127.0.0.1:6080:6080 \
  -e TZ=America/Denver \
  -v fishbowl-mysql:/var/lib/mysql \
  -v fishbowl-app:/opt/Fishbowl \
  -v fishbowl-data:/var/lib/fishbowl \
  --read-only --tmpfs "/run:mode=0755" --tmpfs "/tmp:exec,mode=1777" --tmpfs "/var/tmp:mode=1777" \
  --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
  --cap-add KILL --cap-add SETGID --cap-add SETUID \
  --security-opt no-new-privileges:true --pids-limit 4096 \
  fishbowl
```

**Windows (PowerShell)**

```powershell
docker rm fishbowl
docker run -d --platform linux/amd64 --name fishbowl --restart always --stop-timeout 180 -p 2456:2456 -p 28192:28192 -p 127.0.0.1:6080:6080 -e TZ=America/Denver -v fishbowl-mysql:/var/lib/mysql -v fishbowl-app:/opt/Fishbowl -v fishbowl-data:/var/lib/fishbowl --read-only --tmpfs "/run:mode=0755" --tmpfs "/tmp:exec,mode=1777" --tmpfs "/var/tmp:mode=1777" --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER --cap-add KILL --cap-add SETGID --cap-add SETUID --security-opt no-new-privileges:true --pids-limit 4096 fishbowl
```

**With Compose**, in the folder with `compose.yaml`, on every system:

```sh
docker compose up -d
```

### Step 5: Upgrade

**Nothing is upgraded until you accept it.** The new image starts your
installed version as before, and the Fishbowl page (`docker exec fishbowl
fishbowl-link` prints its link) offers **Upgrade to Fishbowl X**: read and
accept the new version's license agreement and press **Back up and upgrade**.
At a terminal instead: `docker exec -it fishbowl fishbowl-upgrade`. Only an
installation made by an earlier version of this image, which let you choose a
MySQL password, is asked for that password too; a wrong one is caught before
anything is stopped.

Then the container stops Fishbowl Server, **dumps every database** to
`/var/lib/fishbowl/backups/pre-upgrade-…sql.gz` (with Fishbowl's settings files),
runs the new installer over `/opt/Fishbowl`, and starts Fishbowl Server again.
It keeps your company name, license key, memory settings and data, and never
re-initializes MySQL. On its first start on the new version, Fishbowl Server
**updates your database**. On a large database that can take a while, and the
container waits as long as it takes.

### Step 6: Check it

- The page shows **Fishbowl X installed** and **Fishbowl Server is running** on
  your company database.
- Log in with a Fishbowl Client and look at a few recent orders and items.

Once you're sure, you can delete the old image to save space, for example
`docker image rm fishbowl:2026.10` once 26.11 runs well. That removes the image only, never data.

### If something goes wrong: back to where you were

Fishbowl won't run an older version on volumes it has upgraded, so going back
means putting the step 3 backup into the volumes and starting the old image.
**This replaces everything in the three volumes with the backup:** anything
entered after the backup is gone. To keep that too, run step 3 once more first;
its new file won't overwrite the first one.

Put your backup's file name (the one **Backup OK** printed) and your old version
into the first two lines, then run the block in the folder that holds the file.
The restore reads the whole file back before it deletes anything. If it prints
**BACKUP FAILED**, the volumes are as they were and `docker start fishbowl`
starts the container again. If anything else stops it (a full disk, say), free
space and run the block again: it starts over from the file each time.

**Linux and macOS**

```bash
BACKUP="fishbowl-volumes-20261117-093000.tar.gz"
OLD="fishbowl:2026.10"   # the version you came from
docker stop fishbowl
docker run --rm --platform linux/amd64 --entrypoint sh -e BACKUP="$BACKUP" \
  -v fishbowl-mysql:/volumes/mysql -v fishbowl-app:/volumes/app -v fishbowl-data:/volumes/data \
  -v "$PWD":/backup "$OLD" -c 'tar -tzf /backup/$BACKUP > /dev/null || { echo BACKUP FAILED, the volumes were not changed; exit 1; }; find /volumes/mysql /volumes/app /volumes/data -mindepth 1 -delete && tar -xzpf /backup/$BACKUP -C /volumes && echo Restored from $BACKUP' && docker tag "$OLD" fishbowl && docker rm fishbowl
```

**Windows (PowerShell)**

```powershell
$BACKUP = "fishbowl-volumes-20261117-093000.tar.gz"
$OLD = "fishbowl:2026.10"   # the version you came from
docker stop fishbowl
docker run --rm --platform linux/amd64 --entrypoint sh -e "BACKUP=$BACKUP" -v fishbowl-mysql:/volumes/mysql -v fishbowl-app:/volumes/app -v fishbowl-data:/volumes/data -v "${PWD}:/backup" $OLD -c 'tar -tzf /backup/$BACKUP > /dev/null || { echo BACKUP FAILED, the volumes were not changed; exit 1; }; find /volumes/mysql /volumes/app /volumes/data -mindepth 1 -delete && tar -xzpf /backup/$BACKUP -C /volumes && echo Restored from $BACKUP'
if ($LASTEXITCODE -eq 0) { docker tag $OLD fishbowl; docker rm fishbowl }
```

After **Restored from …**, start it with step 4's `docker run` command, or
`docker compose up -d`. The page shows your old version, running on your data
as it was at the backup.

### More about upgrades

- **Trial installations are not offered the upgrade.** Fishbowl Server refuses
  to update a trial's database to a new version ("Trial accounts do not have
  access to update the database"; seen going from 26.9.1 to 26.10). The page
  explains and the installed version keeps running. Enter a purchased license
  first (Server Administration → License), restart the container, and the
  upgrade is offered.
- **An upgrade that stopped half-way** (for example the computer lost power
  while the installer ran) leaves Fishbowl Server stopped, and the page offers to
  run the upgrade again. It never starts Fishbowl on half-updated program files.
- **Downgrades are refused:** an older image on newer volumes starts nothing,
  changes nothing, and the page says why. That's why going back uses the backup.
- If Fishbowl Server reports that it can't update the database, the page shows
  Fishbowl's reason ([Troubleshooting](#17-troubleshooting)).

### Updates to the system inside the container (MySQL, Java and the rest)

Separate from Fishbowl's own versions above. The system inside the image (the
operating system's libraries, MySQL 8.4, Java 21 and the pieces behind the
browser windows) gets its updates in two places, so they never wait for someone
to remember them:

- **Every image build applies every update published so far.** `update-all.sh
  --build` runs inside the build, keeps MySQL on 8.4 and Java on 21, runs the
  same runtime check as always, and fails the build if a package repository
  can't be read. An image never ships quietly unpatched. It records when that
  happened: `docker exec fishbowl cat /usr/local/share/fishbowl/image-built`.
- **The weekly maintenance rebuilds the image and swaps it in**, with a backup
  first and an automatic rollback (next part).
- **If neither has happened for 14 days**, the container's log says so once a
  day and the Fishbowl page shows a warning. `-e FISHBOWL_IMAGE_MAX_AGE_DAYS=…`
  changes the 14.

The container runs read-only ([section 14](#14-security)), so nothing changes
its packages while it runs. That's on purpose: what runs is exactly what was
built and checked.

**A container started without `--read-only`** (an older command, or one you
changed) still updates itself at every start, as before: `update-all.sh` waits
90 seconds, runs at low priority, only replaces files, writes its details to
`/var/lib/fishbowl/logs/update-*.log` (the five newest are kept) and never
restarts anything; the new files are used from the next start.
`-e FISHBOWL_AUTO_UPDATE=0` turns that off, and `docker exec fishbowl
update-all.sh` runs it by hand. On a read-only container that command says
updates come from rebuilds and changes nothing.

A MySQL update is a patch release inside 8.4, which MySQL installs over an
existing data directory by itself the next time it starts. The weekly
maintenance takes its backup before that start. I tested this once by hand: a
data directory made by 8.4.10 started on 8.4.13 after the update, upgraded
itself, and kept its data (see section 18).

### Weekly maintenance (set it up once)

`fishbowl-maintain.sh` (Linux and macOS) and `fishbowl-maintain.ps1` (Windows)
do a whole update in one go, and a scheduled task runs them every week. They
work with [the Compose stack](#13-the-compose-stack), from the folder that holds
`compose.yaml`; its setup downloads them there. One run:

1. Builds new images with every package update, all in one go: Fishbowl
   Server's as `fishbowl-server:candidate`, and the stack's others (page,
   desktop, db, backup, edge, edge-tcp, egress), each keeping its current image
   as `:previous`. The running containers aren't touched, and a failed build
   changes nothing.
2. If Fishbowl Server's container isn't running, the new images wait for the
   next start, and that's all.
3. Backs up every MySQL database (`fishbowl-backup --label weekly-maintenance
   --keep 4`, into `/var/lib/fishbowl/backups`). No backup, no change.
4. Keeps the current server image as `fishbowl-server:previous`, recreates the
   containers on the new images with the same volumes, and waits up to 20
   minutes for them to be back where they were (healthy, if they were healthy
   before).
5. If they aren't, saves the failed containers' logs next to `compose.yaml`, puts
   every `:previous` back and recreates the containers again.

**This restarts Fishbowl once a week.** Clients are disconnected for the few
minutes the swap takes, so pick a time nobody works. Earlier versions of this
image never restarted anything for an update; that changed on purpose, because
an update that waits for a convenient moment tends to wait forever. A new Fishbowl version on the
release arrives the same way, and the page then offers the upgrade; nothing
changes until you accept it there ([Step 5](#step-5-upgrade)).

**Linux and macOS** (cron, Sundays at 03:17, as a user who can run `docker`):

```bash
(crontab -l 2>/dev/null; echo '17 3 * * 0 cd "$HOME/fishbowl" && /bin/bash fishbowl-maintain.sh >> fishbowl-maintain.log 2>&1') | crontab -
```

**Windows (PowerShell)**, Sundays at 03:17, as you (Docker Desktop only runs
while you're signed in):

```powershell
$dir = "$HOME\fishbowl"
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}\fishbowl-maintain.ps1" -Dir "{0}"' -f $dir)
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 3:17am
Register-ScheduledTask -TaskName 'Fishbowl weekly maintenance' -Action $action -Trigger $trigger
```

Check that it's there with `crontab -l` or `Get-ScheduledTask -TaskName 'Fishbowl
weekly maintenance'`. To run it now, in that folder: `bash fishbowl-maintain.sh`,
or on Windows `Start-ScheduledTask -TaskName 'Fishbowl weekly maintenance'`.

**What it tells you.** Everything goes to `fishbowl-maintain.log` in that folder.
Exit status 0 means done. 1 means it stopped before changing anything, and the
log says why (Docker not running, a failed build, a failed backup, Fishbowl busy
with a setup or an upgrade). 2 means the new image failed and the previous one
runs again. 3 means the previous one didn't come back either: restore from the
backup the log names ([If something goes wrong](#if-something-goes-wrong-back-to-where-you-were)).

**Two limits.** An installation that still has a MySQL root password of its own
(set up by an earlier version of this image) can't be backed up unattended, so
the run stops at step 3 and says so; run `docker exec -it fishbowl
fishbowl-backup` and then the script by hand. And on macOS and Windows, Docker
Desktop has to be running, which needs someone signed in; a Linux server with
Docker Engine doesn't.

## 13. The Compose stack

`compose.yaml` runs Fishbowl as a set of small containers instead of one: the
layout for a server that runs for years. Nothing that runs for long is root,
each part reaches only the networks it needs, the page is behind HTTPS, every
database gets a verified dump each night, and every part restarts by itself.
Sections 3 to 12 describe the single container, which stays as it is; a given
set of volumes is used by one or the other.

| Container | What it does | Runs as | Networks |
|---|---|---|---|
| `fishbowl` | Fishbowl Server, first-time setup, upgrades | uid 1000 (`fishbowl`) | app, data |
| `fishbowl-page` | The Fishbowl page | uid 1001 (`fbweb`, in Fishbowl's group) | app |
| `fishbowl-desktop` | Server Administration and the Fishbowl Client, each on its own virtual screen | uid 1000 | app, data |
| `fishbowl-db` | MySQL 8.4 (the official `mysql:8.4` image) | uid 27 | data |
| `fishbowl-backup` | A verified dump of every database, every night | uid 1000 | data |
| `fishbowl-edge` | HTTPS for the page (443), the page on this computer (127.0.0.1:6080), TLS for Clients if you want it | uid 1002 | public, app |
| `fishbowl-edge-tcp` | Ports 2456 (Fishbowl Clients) and 28192 (integrated apps) | `haproxy` | public, app |
| `fishbowl-egress` | The only way out: Fishbowl's own servers, by name | `squid` | app, outbound |
| `fishbowl-volume-init` | Runs first, hands the volumes to the users above, exits | root with three capabilities, no network | none |

Every long-running container has a read-only image, no Linux capabilities at
all, `no-new-privileges`, a process limit, rotated logs and `restart: always`.
Only the two edge containers publish ports. `app` and `data` are internal
networks with no route out, and the page is never on `data`: the container that
faces browsers can't reach MySQL and never holds a password. The images are
Red Hat's UBI 9 (server and page), AlmaLinux 9 (desktop), the official MySQL 8.4
image (db and backup), Caddy, HAProxy and Alpine (the edges and egress), all
built from this repository with every package update applied, as the single
container is.

### Set it up

Edit `.env` before the first `docker compose up -d`: at least `FB_TZ` (your time
zone) and `FB_PUBLIC_HOST` (the name or IP address people type to reach this
computer; the HTTPS certificate is made for it). The first start builds the
images from GitHub, which takes a while (the Fishbowl installer alone is about
750 MB). Tested on Docker Engine on Linux; not yet on Docker Desktop.

**Linux and macOS**

```bash
mkdir -p ~/fishbowl/secrets && cd ~/fishbowl
for f in compose.yaml .env.example tools/fishbowl-maintain.sh rootfs/usr/local/lib/fishbowl/mysql-root-password.txt; do curl -fsSLO "https://raw.githubusercontent.com/cesiumskater/Docker_Testing/main/$f"; done
mv mysql-root-password.txt secrets/ && chmod 644 secrets/mysql-root-password.txt
cp .env.example .env
for v in mysql app data backups dbconf edge; do docker volume create "fishbowl-$v"; done
docker compose up -d
docker exec fishbowl fishbowl-link
```

**Windows (PowerShell)**

```powershell
New-Item -ItemType Directory -Force "$HOME\fishbowl\secrets" | Out-Null
cd "$HOME\fishbowl"
foreach ($f in 'compose.yaml', '.env.example', 'tools/fishbowl-maintain.ps1', 'rootfs/usr/local/lib/fishbowl/mysql-root-password.txt') { curl.exe -fsSLO "https://raw.githubusercontent.com/cesiumskater/Docker_Testing/main/$f" }
Move-Item mysql-root-password.txt secrets\
Copy-Item .env.example .env
foreach ($v in 'mysql', 'app', 'data', 'backups', 'dbconf', 'edge') { docker volume create "fishbowl-$v" }
docker compose up -d
docker exec fishbowl fishbowl-link
```

`fishbowl-link` prints two links: one for this computer
(`http://localhost:6080/...`) and one for your network
(`https://FB_PUBLIC_HOST/...`). From there it's the same as the single
container: [first-time setup](#6-first-time-setup), then [your company
database](#7-your-company-database-restore-a-sql-backup-or-create-a-new-one).
In Server Administration's **+** dialog leave **Host** as `localhost`, as
everywhere else: in the desktop container, `localhost:3306` leads to the
database container. Then set up the [weekly
maintenance](#weekly-maintenance-set-it-up-once) with the script you downloaded.

**The volumes are created outside Compose on purpose**, so `docker compose down
--volumes` can't delete them (tested). Only `fishbowl_fishbowl-ipc`, a small
in-memory volume the containers use to talk to each other, belongs to Compose;
it holds nothing to keep.

**The MySQL root password file** is the repository's, the same one the single
container carries ([The MySQL root password](#the-mysql-root-password)): Fishbowl
fills its own copy of it into Server Administration's Password fields, so keep
it. Compose hands it to `fishbowl`, `db` and `backup` as a secret at
`/run/secrets/mysql_root`; no image carries it, and the page and the desktop
never see it. It has to be readable by the containers' users (hence `chmod
644`); keep the `secrets` folder itself private. In the database container root
can sign in only from `localhost` and the data network (`172.31.240.0/24` unless
you change `FB_DATA_SUBNET`), never from anywhere.

### Moving from the single container

The stack uses the single container's three volumes as they are, so a site
moves over with its data:

```bash
docker stop fishbowl && docker rm fishbowl
for v in backups dbconf edge; do docker volume create "fishbowl-$v"; done
docker compose up -d
```

(PowerShell: the same three lines, with `foreach ($v in 'backups', 'dbconf',
'edge') { docker volume create "fishbowl-$v" }` for the second; `&&` needs
PowerShell 7, so in Windows PowerShell 5.1 run the two `docker` commands one
after the other.)

`volume-init` hands the files to the stack's users, the page keeps its access
code (saved links keep working), the database container adds root's account for
its network, and Fishbowl Server starts against it with no questions. Going back
works the same way in reverse (`docker compose down`, then the `docker run` from
[section 4](#4-start-it-and-starting-automatically)): the single container takes
the files back and points Fishbowl at its own MySQL again. Root's account for the
data network stays in MySQL then; the single container's MySQL listens on its
own loopback only, so nothing can use it. (Moving over was tested; going back
wasn't run end to end.)

### The HTTPS front door

The edge serves the page over HTTPS on `FB_HTTPS_PORT` (443) and, for the
computer that runs Docker, over plain HTTP on `127.0.0.1:FB_PAGE_PORT` (6080).
The page's sign-in cookie is marked Secure over HTTPS. Old TLS versions (1.1 and
below) are refused. `FB_TLS` says where the certificate comes from:

- `internal` (default): the edge's own certificate authority, kept in the
  `fishbowl-edge` volume (back that volume up: it holds the authority's key).
  Browsers and Clients have to trust its root certificate once. Copy it out with
  `docker compose cp edge:/data/caddy/pki/authorities/local/root.crt
  ./fishbowl-edge-root.crt` and import that file into the computers' trust
  stores. Its server certificates last 12 hours and renew by themselves.
- `/certs/tls.crt /certs/tls.key`: your own certificate and key, as files in
  `FB_TLS_DIR` (`./certs` by default).
- an email address: a public certificate from Let's Encrypt. That needs
  `FB_PUBLIC_HOST` in public DNS and ports 80 and 443 reachable from the
  internet; port 80 isn't published by this `compose.yaml`, so it isn't set up
  for that out of the box. **Not tested.**

Fishbowl Clients connect to `edge-tcp` on 2456 as they always have. With
`FB_CLIENT_TLS=edge`, the edge terminates TLS on 2456 with its certificate
instead, and Clients connect to `FB_PUBLIC_HOST` with **Secure Connection** on.
Tested: Fishbowl Server's web app and its API answer through that TLS. **Not
tested:** a Fishbowl Client signing in over Secure Connection. Integrated apps on
28192 always get plain TCP, so keep that port to your network. Fishbowl Server
sees the edge's address, not the Client's (the edge-tcp log has the Client's).

### The egress allowlist

The containers have no route to the internet. Fishbowl Server and the windows
go out through `egress`, a proxy that only lets through, by name:
`fishbowlconnect.com`, `www.fishbowlconnect.com`, `artanis.fishbowldev.com`,
`files.fishbowlinventory.com` and `www.fishbowlinventory.com` (licenses,
plugins, Fishbowl's own update checks), HTTPS on 443 and plain HTTP on 80 and 81
only. A name off the list, an IP address or another port is refused, and the
proxy's log (`docker logs fishbowl-egress`) says so.

- `FB_EGRESS_EXTRA` adds names, separated by spaces or commas: an integration's
  servers, or a plugin's. Two plugin hosts Fishbowl 26.11 knows about aren't on
  the default list: `metadata.fishbowlinventory.app` (AI Insights) and
  `pi-metrics.fishbowlinventory.app` (ShipExpress metrics).
- `FB_EGRESS_UPSTREAM=host:port` sends everything through your network's own
  proxy, if it requires one.
- `docker exec fishbowl fishbowl-netcheck` shows what gets through, and confirms
  there's no direct way out.

### Backups in the Compose stack

The `backup` container dumps every database each night at `FB_BACKUP_TIME` (in
`FB_TZ`) into the `fishbowl-backups` volume. One set is a folder named after its
UTC time, holding `all-databases.sql.gz` (for a full restore), one dump per
company database (rows in primary-key order, no dump date, so the same data gives
the same file), Fishbowl's `eve.properties` and `dbsettings.properties` (your
License Key is in them), `reports.tar.gz` (Fishbowl's report files: the database
only holds each report's name and path) and `MANIFEST.sha256`. Files are readable
by the backup container's user only. It keeps 14 daily, 8 weekly and 12 monthly
sets (`FB_BACKUP_KEEP_*`), checks free space first, and reports unhealthy when the
newest set is over 26 hours old.

| Command | |
|---|---|
| `docker exec fishbowl-backup fishbowl-backup --now` | A set now. |
| `docker exec fishbowl-backup fishbowl-backup --verify` | Checks the newest set: gzip, the dump's completion line, the manifest's hashes. |
| `docker exec fishbowl-backup fishbowl-backup --list` | The sets. |
| `docker exec fishbowl-backup fishbowl-backup --latest DATABASE` | The newest dump of one database, for a restore. |

**Copy the sets offsite.** The backup container has no route out, on purpose, so
the computer that runs Docker copies the `fishbowl-backups` volume somewhere
else, encrypted, on its own schedule (for example
`docker run --rm -v fishbowl-backups:/b:ro -v "$PWD":/out alpine tar -czf /out/fishbowl-backups.tar.gz -C /b .`
and your usual offsite tool). Where those copies should live is your call.

**Restoring a company database** from a set (bad data, computer fine): stop
Fishbowl Server on the page, then restore the dump in Server Administration's
**Restore** tab (upload it on the page first, uncompressed) or load it with the
`mysql` client, and start Fishbowl Server again. A drill restore of the newest
set into a throwaway MySQL matched the live database row for row (tested; the
comparison uses data-only dumps, since MySQL 8.4 writes table definitions
slightly differently after a reload).

### Fishbowl's own updates

Normally new Fishbowl versions arrive as new images and wait for you on the page
([section 12](#12-updating-to-a-new-fishbowl-version)). With `FB_NATIVE_UPDATES=1`
Fishbowl may also download and apply its own updates (Server Administration →
**Server** → **Auto Updates**). The container then:

- tells Fishbowl it runs in a container (`FishbowlContainerized=true`), so
  Fishbowl leaves database backups to the backup container;
- takes a database backup before Fishbowl applies a downloaded update, and holds
  the update back if that backup fails;
- shows **updating** on the page while Fishbowl's updater works, and starts
  Fishbowl Server again afterwards (Fishbowl's own restart script is replaced by
  one that hands the restart to the container);
- removes the Java debug port Fishbowl's service launcher opens on 127.0.0.1:7770
  before every start, as it always does.

Trial installations never look for updates (Fishbowl skips the check for them),
and Fishbowl's first check runs 50 to 250 hours after a start. Tested with
Fishbowl's own updater and a stand-in update package in the single container.
**Not tested with a real Fishbowl update**, which needs a purchased license, or in
the stack. To test it: set
`FB_NATIVE_UPDATES=1`, choose **Automatically download and apply updates** with a
day and hour in Server Administration, and when the time has passed check
`docker logs fishbowl` (the backup and the restart), the version on the page, and
`/opt/Fishbowl/logs/update.log`.

### When something fails

- **Fishbowl Server hangs** (Java still accepts connections but doesn't answer):
  the supervisor asks it for an HTTP answer every 5 seconds, and after three
  misses in a row stops it and starts it again in the same container. Tested: a
  frozen Java was restarted 26 to 30 seconds after it froze, and ran again within
  a minute.
- **Fishbowl Server or the container crashes:** started again in place, or by
  Docker within half a second. After four unplanned stops within ten minutes it
  stays stopped and the page says why, so a crash loop doesn't run forever.
- **MySQL restarts under it:** Fishbowl Server doesn't get new database
  connections by itself (tested: sign-ins failed until it restarted), so the
  supervisor watches for a MySQL restart, even one too quick to see it gone, and
  starts Fishbowl Server again. Tested: back within half a minute, and a Client
  could sign in.
- **The computer restarts:** every container comes back by itself; Fishbowl
  Server waits for the database. Tested by restarting Docker: everything healthy
  again 30 seconds later, with no command.

Every container has a health check that tests real work (an HTTP answer from
Fishbowl Server, MySQL's ping, the page's sign-in page, the desktop's request
loop, the age of the newest backup). Docker only reports health; for alerts, feed
`docker events --filter event=health_status --filter event=die` to your
monitoring.

**Logs:** every line in `docker logs` of the stack's Fishbowl containers starts
with a UTC timestamp and a tag (`[fishbowl]`, `[fbserver]` for Fishbowl Server's
own output, `[watchdog]`, `[warning]`, ...), one event per line, Java stack
traces included. Logs rotate at 10 MB, five files per container. The MySQL root
password and the page's access code never appear in them (tested).

### What's different inside

- **Fishbowl's installer runs as Fishbowl's user.** It refuses to run unless the
  user is named root, and that's all it checks (Java's `user.name`), so the server
  container tells it that name. It still runs as uid 1000 and can only write
  Fishbowl's own folders. Setup and an upgrade on the page both work that way
  (tested). Two of the installer's steps fail harmlessly as a result: creating
  the `fishbowl` group (it exists) and registering a system service (containers
  have none).
- **Server Administration's `localhost` is the database container** inside the
  desktop container, through a small relay that only that container can reach,
  so the **+** dialog and the **Restore** tab work exactly as in the single
  container (tested: a new database, and the 54 MB reference backup restored
  through the page). Fishbowl's settings then say `localhost`, and the server
  container points them at `db` before every start.
- **The windows look the same:** the desktop and server images use the single
  container's fonts (Noto Sans for Java's sans-serif), so window sizes and the
  reports that ask for Arial or SansSerif come out the same. Without that, Server
  Administration came out 70 pixels wider.
- **Java is the Temurin 21 JRE**, not the JDK, and the server image has no
  window libraries or compilers. Fishbowl Server, setup, upgrades, Server
  Administration and the Client ran on it in the tests; printing reports from the
  Client on it wasn't compared with the single container's output.

## 14. Security

- **The page is the only way in** to the setup form, the browser windows and the
  buttons, and it needs the access code. The windows' virtual screens listen on
  private sockets inside the container, not on network ports. Wrong codes are
  refused, and after ten in a minute the page stops accepting codes for a minute.
- **Port 6080 is published on 127.0.0.1 only**, so the page works on the
  computer that runs Docker and nowhere else. It's plain HTTP: if you publish it
  on the network (`-p 6080:6080`), the access code and everything you type in the windows travel unencrypted, and the page says
  so at the top. To use it from another computer, an SSH tunnel keeps it
  private: `ssh -L 6080:localhost:6080 you@docker-host`, then open
  `http://localhost:6080/` there. The `ssh` command comes with Linux, macOS and
  Windows 10 and 11, and the Docker host has to run an SSH server.
- Requests that change something must come from the page itself (a header only
  the page sends, and the browser's Origin); a link or form on another website
  can't press its buttons.
- The page's web server runs as its own unprivileged user (`fbweb`). It never
  runs anything itself: it hands requests to the container's main process, which
  checks every value again. Fishbowl Server, Server Administration and the
  Client run as `fishbowl`, MySQL as `mysql`. None of them is root. The main
  process itself starts as root, because it has to hand each of them its own
  user and files; that's the one root process left.
- **The container runs read-only, with the fewest privileges that work.** The
  commands in this README (and `compose.yaml`) start it with a read-only root
  filesystem and memory-only `/run`, `/tmp` and `/var/tmp`, so nothing that runs
  inside can change the image; everything that lasts is on the three volumes.
  Of Linux's capabilities it keeps the six that start-up needs (`CHOWN`,
  `DAC_OVERRIDE`, `FOWNER`, `KILL`, `SETGID`, `SETUID`). `no-new-privileges`
  stops any process from gaining more than it started with, and
  `--pids-limit 4096` caps processes and threads. Updates come from rebuilds
  ([section 12](#updates-to-the-system-inside-the-container-mysql-java-and-the-rest)).
- **Your license key** goes from the form to the container through memory
  (`/dev/shm`, owner-only, deleted as soon as it's read) and never appears in the
  logs. The MySQL root password is never shown on the page, in its data or in the logs
  (next section); the checks in `tests/` make sure
  it isn't written to the logs or into the volumes.
- MySQL listens on 127.0.0.1 inside the container only.
- **In the Compose stack, nothing that runs for long is root**
  ([section 13](#13-the-compose-stack)): Fishbowl Server, the page, the windows,
  MySQL, the backup and the edges each run as their own user with no Linux
  capabilities at all, and no process in any of them is uid 0 (tested). The one
  exception is `volume-init`, which runs for a second before the others, with
  three capabilities and no network, to hand the volumes to those users. The MySQL
  root password reaches only the containers that need it, as a Compose secret.

### The MySQL root password

Nobody chooses one: every new installation gets the same MySQL root password,
which is in `rootfs/usr/local/lib/fishbowl/mysql-root-password.txt`. It is
secret information, so this image never shows it: not on the Fishbowl page, not
in the page's data (`/api/status`), not in the logs, not in this README, and not
in the messages `fishbowl-setup` prints. It never goes to your browser either.

You don't need it anyway. Setup doesn't hand Fishbowl's installer a database
password, so the installer stores its own default, and that default is this same
string. So Server Administration's Password fields (the **+** dialog and the
**Restore** tab) come filled in with the right password, masked with dots. Leave
them as they are. I tested this: a new database and a restore both worked with
the field untouched. If you clear one by mistake, **Cancel** and **+** brings it
back in the new-database dialog, and closing and reopening Server Administration
brings it back on the Restore tab.

**It's the one exception, on purpose.** Everything else that protects an
installation is made when it starts (the page's access code) or typed by you (your
License Key). This password is the only credential that ships in the repository
and the image. You decided to keep it that way so Fishbowl's pre-filled fields
just work. What protects it is reachability: MySQL listens on 127.0.0.1 inside the
container, port 3306 is never published, and setup removes every root account
except the local ones. `fishbowl-netcheck` reports 3306 as not allowed if MySQL
ever listens for the network.

**Think about who can read this repository.** The password sits in a file in the
repository (at your request), so if the repository is public, so is the password. In the one installation I looked at, the
same string appears in Fishbowl's own installer settings (as `mysql8Password`,
in `/opt/Fishbowl/.install4j/i4jparams.conf`), which suggests it is Fishbowl's
default and not something new; I haven't confirmed that with Fishbowl. It also
protects less than it looks like it does, because MySQL listens on 127.0.0.1 inside the container and port 3306
isn't published, so only someone with a shell in the container (or in
Docker on the host) can use it. If you publish 3306, or want a password only you
know, change it: put your own into that file before building (new installations
use it), or for an existing one run `docker exec -it fishbowl mysql -u root -p`
and `ALTER USER 'root'@'localhost' IDENTIFIED BY '...';`, and remember that
Fishbowl keeps its own copy of the database password in `eve.properties`, so
that second route also needs the new password entered in Server Administration.
Not verified: that second step. Try it on a copy first.

Installations made by an earlier version of this image kept the password their
owner chose. The page and the terminal commands notice that (the image's
password is turned down) and ask for it; nothing changes it for you. On those,
the page's steps say to clear Server Administration's Password field and type
your own password, because the pre-filled value is Fishbowl's default and not
yours (I haven't run that path in a GUI test).

### Network and firewall (licenses, plugins, Integrations)

There's no firewall inside the container. Docker lets in only the ports you
publish, and everything may go out, so when a connection is blocked, it's blocked
outside the container: by the firewall on the computer that runs Docker, the
router, or the network.

**The allowlist.** These are the only connections Fishbowl 26.11 needs here (the same as 26.10).
Allow them, and nothing else:

| Direction | Port | For |
|---|---|---|
| In, from your network | 2456 | Fishbowl Clients and the REST API |
| In, from your network (not the internet) | 28192 | Fishbowl's API, the "Legacy Port": integrated apps and integrations |
| In, this computer only | 6080 | The Fishbowl page (published on 127.0.0.1) |
| Out | 81, 443 | `fishbowlconnect.com` |
| Out | 443 | `artanis.fishbowldev.com` and `www.fishbowlinventory.com` |
| Out | 80, 443 | `files.fishbowlinventory.com` |

Integrations with other companies need their servers too, for example Intuit's
(`quickbooks.api.intuit.com`, `appcenter.intuit.com` and others) for QuickBooks
Online.

**Closed in both directions: 28292, 28182, 28282, 3305 and 8080.** Nothing here
listens on them and nothing here connects out to them, so a firewall rule that
opens any of them, either way, can go:

- **28182 and 28282** ("Fishbowl Anywhere"): the HTTP and HTTPS ports of the web
  client Fishbowl ships in `/opt/Fishbowl/webclient`, a Webswing server. Nothing
  starts it here. It's left off on purpose: it would accept connections from any
  address, its user file ships with the same two accounts in every Fishbowl
  installation, and the Fishbowl page already shows the Client in a browser behind
  its access code.
- **28292** ("Fishbowl Nexus QuickBooks"): the port of `Fishbowl Nexus.exe`, a
  Windows program that can't run in this Linux container. A Nexus setup runs on a
  Windows computer, and that computer's firewall is a separate question.
- **3305**: MySQL 5.7's port. This image has MySQL 8.4 only.
- **8080**: nothing in Fishbowl 26.10 or 26.11 uses it.

If something ever listens for the network on a port outside the allowlist,
`fishbowl-netcheck` reports it as **not allowed** and exits with 1. Opening a new
port is then a deliberate change to this list, not a default.

**What Fishbowl Server reaches on the internet, and why.** Licenses and plugins
depend on Fishbowl's servers, and so do modules in the Client's **Integrations**
group (Accounting, Merchant Services, Plugins, and plugins such as ShipExpress).
Fishbowl 26.11 contacts its servers by these names (26.10's are the same), taken from its own program
files:

| Name | Port | For |
|---|---|---|
| `fishbowlconnect.com` | 81 (HTTP) | Plugins: the list in the Plugins module and the plugin update check, which runs at every start |
| `fishbowlconnect.com` | 443 | Plugin downloads, payments, what's new |
| `artanis.fishbowldev.com` | 443 | License, subscription, feature and plugin checks |
| `files.fishbowlinventory.com` | 80, 443 | The security patch list, file downloads |
| `www.fishbowlinventory.com` | 443 | Fishbowl's web pages (help and sales links) |

Fishbowl's help site doesn't publish a list of these servers or their addresses,
so the allowlist is by name. Allow them by name if your firewall can, because the
addresses behind them change: on 17 November 2026 the first four names all
pointed at **74.63.56.90**, and `www.fishbowlinventory.com` is behind Cloudflare.
A rule written for fixed addresses breaks the license and plugin checks the day
those addresses move. Port 81 is the one most often blocked. When it is, Fishbowl
writes `Stream is invalid` followed by `java.net.ConnectException` to
`/opt/Fishbowl/logs/fbserver.log` a few seconds after every start: that's the
plugin update check failing.

**Check it from the container:**

```
docker exec fishbowl fishbowl-netcheck
```

It tries each name and port from inside the container, says what's blocked and
how (refused, no answer, or a name that doesn't resolve), and shows what listens
for the network, flagging anything outside the allowlist. The container also runs
it once, a minute after every start, and writes a warning to its log (`docker logs
fishbowl`) only when something can't be reached; `-e FISHBOWL_NETCHECK=0` turns
that off. It tests whether a connection opens, so a proxy that lets the
connection open and then stops the request can still get in the way.

**What comes in.** Replies to Fishbowl Server's own connections come back on
their own, through Docker and any ordinary (stateful) firewall, so they need no
inbound rule and no port forward. From your network, only the allowlist's inbound
ports matter:

- **2456**, Fishbowl Clients: published.
- **28192**, Fishbowl's API, for integrated apps and integrations on other
  computers: published. Keep it to your network and don't forward it from the
  internet: it's plain, unencrypted TCP.
- **3306**, MySQL: not published, on purpose. MySQL listens on the container's
  own loopback, its root user can only log in from inside the container, and its
  password is in this repository (see [The MySQL root
  password](#the-mysql-root-password)). Fishbowl Clients don't need it: their
  settings point only at Fishbowl Server on 2456, and Fishbowl Server reaches the
  database itself.
- **80, 81 and 443**: nothing listens on them here. They matter only outbound, to
  the servers above.

**The firewall on the computer that runs Docker** has to let 2456 and 28192 in
for other computers; the commands are under [the Fishbowl
Client](#9-the-fishbowl-client-in-its-browser-window). Outgoing connections are
allowed by default on Windows, macOS and Linux. If a policy or security software
blocks them, allow exactly the outbound names and ports in the allowlist.

## 15. Maintaining this repository

### Putting the files on GitHub

The repository lives at **https://github.com/cesiumskater/Docker_Testing**
(public, default branch `main`). To replace its files with a new copy from a zip,
work in a clone of the repository. These assume the clone is in your home
folder (`git clone https://github.com/cesiumskater/Docker_Testing.git` there
makes one, on every system) and the zip is in Downloads:

**Linux and macOS**

```bash
cd ~/Docker_Testing
git pull
git rm -rq .
rm -rf /tmp/fishbowl-new
unzip -q ~/Downloads/Docker_Testing.zip -d /tmp/fishbowl-new
cp -a /tmp/fishbowl-new/Docker_Testing/. .
git add -A
git commit -m "Describe the change"
git push origin main
```

On a Mac, Safari may have unzipped the download already. Then leave out the
`unzip` line and copy from `~/Downloads/Docker_Testing/.` instead.

**Windows (PowerShell)**

```powershell
cd "$HOME\Docker_Testing"
git pull
git rm -rq .
Remove-Item -Recurse -Force "$env:TEMP\fishbowl-new" -ErrorAction SilentlyContinue
Expand-Archive "$HOME\Downloads\Docker_Testing.zip" -DestinationPath "$env:TEMP\fishbowl-new"
robocopy "$env:TEMP\fishbowl-new\Docker_Testing" . /E /NFL /NDL /NJH /NJS /NP
git add -A
git commit -m "Describe the change"
git push origin main
```

`git rm` first makes sure files that the new copy no longer has are deleted
too (the `.git` folder stays). The repository's `.gitattributes` keeps Linux
line endings in a Windows checkout: the scripts run inside Linux and break with
Windows line endings if you ever build from a local copy.

Uploading through GitHub's web page also works: **Add file → Upload files**,
drag in everything *inside* the unzipped folder (show hidden files so
`.github`, `.dockerignore`, `.gitattributes` and `.gitignore` come along),
commit. GitHub's upload page takes up to 100 files at a time and 25 MiB per
file. It doesn't keep the executable bit, which doesn't matter here: the
Dockerfile sets permissions itself.

### The installer release (one time, then once per Fishbowl version)

The installer lives on **one permanently named release**: tag
**`fishbowl-installer`**, holding **exactly one** file named
`Fishbowl-<version>.sh`, exactly as Fishbowl publishes it (for example
`Fishbowl-2026.11.sh`).

- **First time:** **Releases → Draft a new release**. Choose a tag: type
  `fishbowl-installer` and create it on publish. Give it a title, attach the
  installer, and click **Publish release** (a draft isn't visible to the build).
- **New Fishbowl version:** edit that release, delete the old installer, upload
  the new one, and save. That's all: no file in the repository changes. People
  rebuild to get it.

The build reads the version from the file name and fails with a clear message
if the release has **no** `Fishbowl-*.sh` file or **more than one**, or if the
download doesn't match the size and SHA-256 GitHub reports.

**File size.** GitHub doesn't limit a release's total size or download
bandwidth. Its *About releases* page says each file must be under 2 GiB; its
*About large files* page ties the limit to the plan's Git LFS maximum, which is
at least 2 GB on every plan. Either way, Fishbowl's installer (about 721 MiB)
fits.

### Optional: ready-made images on ghcr.io

The workflow in `.github/workflows/build.yml` (**Build and publish the image**)
builds the image on GitHub and publishes `ghcr.io/cesiumskater/docker_testing:<version>`
and `:latest`:

- on its schedule, **every 6 hours** (it builds only when the installer changed);
- **every Monday** at 04:41 UTC, always, so the published image carries every
  package update published since the week before;
- when you press **Actions → Build and publish the image → Run workflow** (tick
  *force* to rebuild an unchanged installer);
- on every push to `main` that changes the image's files.

After the first run, **make the package public**: a new ghcr.io package starts
**private** and doesn't inherit the repository's visibility. On the package's
page: **Package settings → Danger Zone → Change visibility → Public**. GitHub
also turns off scheduled workflows in a public repository after **60 days**
without repository activity; re-enable it on the Actions tab if that happens.

### The acceptance checks

`tests/run-checks.sh` builds the image against a local stand-in for GitHub's
release, then starts throwaway containers the way this README does (detached,
no terminal), fills in the page's forms, and clicks through Server
Administration. It prints PASS or FAIL per check. The checks run on **Linux
only** (bash, Python 3 and Docker Engine); they weren't tried on macOS or in
WSL. They drive Server Administration with vncdotool, installed here in a
Python virtual environment, since some Linux distributions refuse a
system-wide `pip install`:

**Linux**

```bash
python3 -m venv ~/.venvs/fishbowl-checks
~/.venvs/fishbowl-checks/bin/pip install vncdotool
export VNCDO="$HOME/.venvs/fishbowl-checks/bin/vncdo"
bash tests/run-checks.sh --installer ~/Downloads/Fishbowl-2026.11.sh
bash tests/run-checks.sh --installer ~/Downloads/Fishbowl-2026.11.sh \
  --reference-sql ~/Backups/MyCompany_2026-08-10-14-37.sql
```

`--reference-sql` adds the **reference restore checks**: a known-good backup
made by Fishbowl is uploaded on the page, restored in the Restore tab under the
name Fishbowl suggests, compared table by table with a direct load of the same
file, and selected; then the checks expect Fishbowl Server to start on it, or,
for a backup from an older Fishbowl version on the trial installation the
checks use, Fishbowl's refusal to be shown with the database left unchanged.
The file is only read, and stays out of the repository. The checks accept
Fishbowl's license agreement on your behalf in throwaway trial installations;
run them only if that's acceptable to you. About 15 GB of free disk and 35
minutes. `--only update` runs just the system-update checks: update-all.sh against a
stand-in dnf (what it leaves out, how it ends, how it behaves when the container
stops), then once for real with dnf in a fresh container, which needs network
access to the Fedora repositories. `bash tests/run-checks.sh --help` lists the
options.

To run every check on containers started the hardened way, as this README starts
them, put the extra `docker run` options in `FBCHECK_RUN_ARGS`:

```bash
FBCHECK_RUN_ARGS='--read-only --tmpfs /run:mode=0755 --tmpfs /tmp:exec,mode=1777 --tmpfs /var/tmp:mode=1777 --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER --cap-add KILL --cap-add SETGID --cap-add SETUID --security-opt no-new-privileges:true --pids-limit 4096' \
  bash tests/run-checks.sh --installer ~/Downloads/Fishbowl-2026.11.sh
```

`tests/maintain-check.sh --installer FILE` checks the weekly maintenance end to
end on a Compose stack of its own: a normal run (every image rebuilt, a backup
first, every container recreated and back where it was), then a new Fishbowl
Server image that never comes back, after which every image is put back. With
`--powershell mcr.microsoft.com/powershell:latest` it runs the Windows version,
`fishbowl-maintain.ps1`, in PowerShell 7 instead. It uses the stack's real names
(the `fishbowl` and `fishbowl-*` containers, volumes and images), so it refuses
to run where any of them exists. It needs about 15 GB of free disk. On a test
machine whose base images exist only locally, set `FB_MAINTAIN_PULL=0` and name
them in `FBCHECK_BUILD_ARGS`, as for `run-checks.sh`.

## 16. Reference

### Ports

| Port | Published | What |
|---|---|---|
| 2456 | `-p 2456:2456` | Fishbowl Server's client port ("Port" in Server Administration; `webPort` in `eve.properties`). |
| 6080 | `-p 127.0.0.1:6080:6080` | The Fishbowl page, including the browser windows (their screens travel over the page's WebSocket). |
| 28192 | `-p 28192:28192` | Fishbowl's API, the "Legacy Port" (`port` in `eve.properties`): integrated apps and integrations connect here. |
| 3306, 33060 | never | MySQL, bound to 127.0.0.1 inside the container. |
| 28182, 28282, 28292, 3305, 8080 | never | Closed in both directions: nothing here listens on them or connects out to them, and `fishbowl-netcheck` flags any listener (see [Network and firewall](#network-and-firewall-licenses-plugins-integrations)). |
| 80, 81, 443 | never | Nothing listens on them here; outbound, they reach Fishbowl's servers (same section). |
| 7770 | never | A Java debug port Fishbowl builds into its service launcher, bound to 127.0.0.1 inside the container. |

The browser windows' VNC servers have no ports at all: they listen on Unix
sockets in `/run/fishbowl/`.

In the Compose stack only the edge containers publish ports: `FB_HTTPS_PORT`
(443, the page over HTTPS), `127.0.0.1:FB_PAGE_PORT` (6080), `FB_CLIENT_PORT`
(2456) and `FB_API_PORT` (28192), each on `FB_LAN_IP`. MySQL (3306) is reachable
only on the internal data network.

### Commands

The same on Linux, macOS and Windows.

| Command | |
|---|---|
| `docker exec fishbowl fishbowl-link` | The page's link with its access code (`admin` or `client` for a window's link; `--new-code` to replace the code). |
| `docker exec -it fishbowl fishbowl-setup` | First-time setup at a terminal instead of the page. |
| `docker exec -it fishbowl fishbowl-upgrade` | An upgrade at a terminal instead of the page. |
| `docker exec fishbowl fishbowl-admin` | Opens Server Administration and prints its link. |
| `docker exec -it fishbowl fishbowl-backup` | Back up all of MySQL. Without `-it` (a scheduled task) it uses the image's MySQL password and stops with exit status 3 if the installation has its own; `--label NAME --keep N` names the file and keeps only the newest N with that name. |
| `docker exec fishbowl fishbowl-netcheck` | Can the container reach the servers Fishbowl uses for licenses and plugins, and what listens for the network? Changes nothing. |
| `docker exec fishbowl update-all.sh` | On a writable container: update its Fedora packages now (also runs by itself at every start; applies from the next start). On a read-only one it says updates come from rebuilds. |
| `bash fishbowl-maintain.sh` / `fishbowl-maintain.ps1` | The weekly maintenance, by hand: rebuild with every update, back up, swap the container, roll back on failure ([section 12](#weekly-maintenance-set-it-up-once)). In the folder with `compose.yaml`. |
| `docker run -it --rm --platform linux/amd64 <the three -v> fishbowl restore FILE` | Restore a `fishbowl-backup` file (container stopped). |
| `docker run --platform linux/amd64 … fishbowl admin` | Like the normal start, but Fishbowl Server stays stopped until you press Start on the page. |
| `docker run --rm --platform linux/amd64 fishbowl version` | The image's Fishbowl version, for tagging (`2026.11`). |
| `docker run --rm --platform linux/amd64 fishbowl versions` | Fishbowl, MySQL and Java versions in the image. |
| `docker exec fishbowl-page fishbowl-link --new-code` | In the Compose stack: replace the page's access code (the page container keeps it). |
| `docker exec fishbowl-backup fishbowl-backup --now` | In the Compose stack: a backup set now (`--verify`, `--list`, `--latest DATABASE`: [Backups in the Compose stack](#backups-in-the-compose-stack)). |

### Environment variables

| Variable | Default | |
|---|---|---|
| `TZ` | `UTC` | Time zone for Fishbowl and MySQL, as a tz database name, e.g. `America/Denver`. |
| `FISHBOWL_PROMPT_TIMEOUT` | `1800` | Seconds each question of `fishbowl-setup` / `fishbowl-upgrade` waits before giving up. |
| `FISHBOWL_ALLOW_TRIAL_UPGRADE` | `0` | `1` offers the upgrade to a trial installation. Fishbowl Server refuses to update a trial's database, so this only works when the new version doesn't change the database; the test suite uses it. |
| `FISHBOWL_AUTO_UPDATE` | `1` | `0` turns off the update of a writable container's Fedora packages at each start (read-only containers get updates from rebuilds; see section 12). |
| `FISHBOWL_IMAGE_MAX_AGE_DAYS` | `14` | After this many days without a rebuild, the log (once a day) and the page warn that the image's packages are getting old. |
| `FISHBOWL_UPDATE_DELAY` | `90` | Seconds after the container starts before the update begins. |
| `FISHBOWL_NETCHECK` | `1` | `0` turns off the network check a minute after each start (it only writes a warning to the log when Fishbowl's servers can't be reached). |
| `FISHBOWL_NETCHECK_DELAY` | `60` | Seconds after the container starts before that check. |
| `FISHBOWL_UPDATE_TIMEOUT` | `1800` | Seconds before an update is given up on. |
| `FISHBOWL_ALLOW_NO_VOLUMES` | `0` | `1` skips the check that the three data paths are volumes (throwaway tests only). |
| `FISHBOWL_SERVER_XMX` | (empty) | Fishbowl Server's heap, such as `6g` or `4096m`, written into its launcher before every start; it wins over Server Administration's memory field. Empty: that field stands. |

### Compose settings (`.env`)

Read by `compose.yaml` from a file named `.env` next to it; `.env.example` lists
them with notes. Without the file, the defaults apply.

| Setting | Default | |
|---|---|---|
| `FB_TZ` | `UTC` | The containers' time zone (it becomes `TZ`); also the backup schedule's. |
| `FB_LAN_IP` | `0.0.0.0` | The address of this computer the edge publishes on; `0.0.0.0` is every IPv4 address. |
| `FB_PUBLIC_HOST` | `localhost` | The name or IP address people type; the HTTPS certificate is made for it. |
| `FB_HTTPS_PORT` | `443` | The page over HTTPS, for your network. |
| `FB_PAGE_PORT` | `6080` | The page on this computer only (127.0.0.1). |
| `FB_CLIENT_PORT` | `2456` | Fishbowl Clients and the REST API. |
| `FB_API_PORT` | `28192` | Fishbowl's legacy API, for integrated apps. |
| `FB_TLS` | `internal` | Where the certificate comes from ([The HTTPS front door](#the-https-front-door)). |
| `FB_TLS_DIR` | `./certs` | The folder with your own certificate and key, for `FB_TLS=/certs/tls.crt /certs/tls.key`. |
| `FB_CLIENT_TLS` | `off` | `edge`: TLS for Fishbowl Clients on 2456, with the edge's certificate. |
| `FB_EGRESS_EXTRA` | (none) | More names the egress proxy lets through ([The egress allowlist](#the-egress-allowlist)). |
| `FB_EGRESS_UPSTREAM` | (none) | `host:port` of your network's own proxy, if it requires one. |
| `FB_SERVER_XMX` | (empty) | Fishbowl Server's heap, such as `6g`; written before every start, so it wins over Server Administration's memory field. Empty: that field stands (8 GB from setup). |
| `FB_MEM_LIMIT` | `0` | A memory cap for Fishbowl Server's container, such as `12g`; `0` means none. Fishbowl Server alone may use 8 GB; keep the cap well above the heap. |
| `FB_DESKTOP_MEM_LIMIT` | `0` | The same for the windows' container (each window's Java may use 2 GB). |
| `FB_DB_MEM_LIMIT` | `0` | The same for MySQL's container. |
| `FB_BACKUP_TIME` | `01:17` | When the nightly backup runs, in `FB_TZ`. |
| `FB_BACKUP_KEEP_DAILY`, `_WEEKLY`, `_MONTHLY` | `14`, `8`, `12` | How many backup sets to keep. |
| `FB_NATIVE_UPDATES` | `0` | `1` lets Fishbowl download and apply its own updates ([Fishbowl's own updates](#fishbowls-own-updates)). |
| `FB_MYSQL_ROOT_PASSWORD_FILE` | `./secrets/mysql-root-password.txt` | The MySQL root password file, handed to fishbowl, db and backup as a secret. |
| `FB_DATA_SUBNET`, `FB_DATA_ROOT_HOST` | `172.31.240.0/24`, `172.31.240.%` | MySQL's internal network, and where root may sign in from. Change both only if that range is in use on your network. |
| `FB_SOURCE` | GitHub | Build from a clone of this repository instead (for example `.`). |

### Exit codes

The normal start doesn't exit to ask for anything. It exits `1` when MySQL
can't start, or stopped unexpectedly four times within ten minutes (the restart
policy then starts the container again), and `6` when another container is
using the same volumes. `fishbowl-setup`, `fishbowl-upgrade` and
`restore` exit `1` when declined or failed and `3` when nobody answered;
`fishbowl-upgrade` exits `7` for a trial installation.

### File locations

| Path | |
|---|---|
| `/opt/Fishbowl/server/bin/eve.properties` | Fishbowl Server settings (license key, database connection, ports, Auto Updates). Owner-only. |
| `/opt/Fishbowl/logs/fbserver.log` | Fishbowl Server's log. |
| `/opt/Fishbowl/data/backups/` | Backups made with Backup Database in Server Administration. |
| `/opt/Fishbowl/server/bin/*.vmoptions` | Server memory (`-Xmx…`); client memory is in `client/bin/`. |
| `/var/lib/fishbowl/import/` | Files of any type, mainly `.sql` backups for the Restore tab (uploaded on the page or copied in); shown as `import` in Server Administration's file chooser. |
| `/var/lib/fishbowl/backups/` | `fishbowl-backup` and pre-upgrade backups. |
| `/var/lib/fishbowl/logs/` | `mysqld.log`, setup and upgrade logs, `update-*.log` (system updates), and `session-admin.log` / `session-client.log` (the browser windows). |
| `/var/lib/fishbowl/state/` | Setup and upgrade state, license-agreement records, the page's access code, settings waiting for a restart. |
| `/etc/my.cnf.d/90-fishbowl.cnf` | The guide's MySQL settings (in the image). |
| `/run/fishbowl-mysql.d/50-fishbowl-server.cnf` | Fishbowl's `server/bin/my.cnf` tuning (`max_connections`, `innodb_buffer_pool_size`, `max_allowed_packet`, …), regenerated whenever MySQL starts, minus the two settings the guide controls. It lives under `/run` so the image can run read-only; `/etc/my.cnf.d/50-fishbowl-tuning.cnf` includes it. |
| `/usr/local/share/fishbowl/image-built` | When the image's system packages were last brought up to date (UTC), written by every build. |
| `/opt/fishbowl-installer/` | The bundled installer, its license texts, `installer.env`. |
| `/usr/local/lib/fishbowl/portal.py`, `/usr/local/share/fishbowl/web/` | The Fishbowl page. |

These are paths inside the container (Linux paths, on every system).

Fishbowl's installer also keeps the license key in plain text in
`/opt/Fishbowl/installSettings`, `/opt/Fishbowl/.install4j/response.varfile` and
`/opt/Fishbowl/.install4j/installation.log`. The container makes these
owner-only (as it does `eve.properties`); it doesn't delete Fishbowl's own files.

### Build arguments

| Argument | Default | |
|---|---|---|
| `INSTALLER_REPO` | `cesiumskater/Docker_Testing` | Repository whose release holds the installer. |
| `INSTALLER_RELEASE_TAG` | `fishbowl-installer` | That release's tag. |
| `GITHUB_API_URL` | `https://api.github.com` | For GitHub Enterprise Server. |
| `EXPECTED_ASSET_ID` | (empty) | Set by the workflow: fail if the installer changed mid-build. |
| `FISHBOWL_IMAGE` | `fishbowl` | Image name shown in the container's printed commands. |
| `FEDORA_IMAGE` | `registry.fedoraproject.org/fedora:44` | The single container's base image (also noVNC's files for the stack's page). |
| `UBI_IMAGE` | `registry.access.redhat.com/ubi9/ubi-minimal:latest` | The stack's server and page base image (targets `server`, `page`). |
| `DESKTOP_BASE_IMAGE` | `quay.io/almalinuxorg/almalinux:9` | The stack's desktop base image (target `desktop`), and where the server's Noto Sans font comes from. |
| `MYSQL_IMAGE` | `mysql:8.4` | Where the stack's MySQL client tools come from; also the base of `images/db` and `images/backup`. |
| `CADDY_IMAGE`, `HAPROXY_IMAGE`, `ALPINE_IMAGE` | `caddy:2`, `haproxy:lts-alpine`, `alpine:3` | The bases of `images/edge`, `images/edge-tcp` and `images/egress`. |
| `PACKAGES_REFRESH` | (empty) | Any new value makes the build apply every package update again instead of reusing its cache. The weekly maintenance and the weekly CI build pass the time. |

## 17. Troubleshooting

### Commands on Linux, macOS and Windows

| Message | Fix |
|---|---|
| PowerShell: `docker: invalid reference format`, then `The term '-p' is not recognized …` | A Linux and macOS command, with its `\` line breaks, went into PowerShell. Use the **Windows (PowerShell)** version: one line, no `\`. Nothing was created, so just run that. |
| PowerShell: `A parameter cannot be found that matches parameter name 'fsSLO'` | In Windows PowerShell 5.1, `curl` is another name for `Invoke-WebRequest`. Type `curl.exe`, as the Windows commands do. |
| PowerShell: `The token '&&' is not a valid statement separator in this version.` | Windows PowerShell 5.1 has no `&&` (PowerShell 7 does). Run the commands one after the other. |
| zsh: `command not found: #` | A comment line was pasted. The commands here have none; `setopt interactivecomments` makes zsh skip them. |
| zsh: `no matches found: https://github.com/…#main` | The address lost its quotes, and zsh's `extendedglob` option read `#` as part of a pattern. Keep the quotes. |
| Linux: `permission denied while trying to connect to the Docker daemon socket` | Docker Engine needs root. Put `sudo` in front of every `docker`, including the one inside `$( )`, or add yourself to the `docker` group (`sudo usermod -aG docker $USER`, then sign out and in). Members of that group effectively have root on the computer. |
| `Cannot connect to the Docker daemon …` (Linux, macOS) or `error during connect … pipe …` (Windows) | Docker isn't running. Start Docker Desktop, or on Linux with Docker Engine `sudo systemctl start docker`. |
| Windows: `no matching manifest for windows/amd64 …` while building | Docker Desktop is in Windows containers mode. Right-click its icon in the notification area and choose **Switch to Linux containers…**. |
| Mac with Apple Silicon: `exec format error`, or a warning that the image's platform (linux/amd64) doesn't match the host's (linux/arm64) | The image was built or started without `--platform linux/amd64`. Build it again with the commands here; turning on Rosetta in Docker Desktop's General settings makes the emulation faster. |
| `Error response from daemon: container … is not running` right after starting it | The container was created but couldn't start: `docker ps -a` lists it as *Created*, and the command that started it (`docker run` or `docker compose up -d`) printed why. Usually a port is already in use (below). |

### A port is already in use

Docker says `port is already allocated`, `address already in use` or
`Ports are not available`, and on Windows also `Only one usage of each socket
address …` or `An attempt was made to access a socket in a way forbidden by its
access permissions`. Something else on the computer already has 2456 or 6080.
On a computer used for Fishbowl work, that's often a Fishbowl Server installed
on the computer itself, which listens on 2456 too.

See what's listening on 2456 (use 6080 for the page's port):

**Linux**

```bash
sudo ss -ltnp 'sport = :2456'
```

**macOS**

```bash
sudo lsof -nP -iTCP:2456 -sTCP:LISTEN
```

**Windows (PowerShell)**

```powershell
Get-NetTCPConnection -LocalPort 2456 -State Listen | ForEach-Object { Get-Process -Id $_.OwningProcess }
netsh interface ipv4 show excludedportrange protocol=tcp
```

The first Windows command names the program. The second lists the port ranges
Windows has reserved (Hyper-V and WSL reserve some): a port inside one of them
shows no program, and Docker still can't have it. Restarting the Windows NAT
service in PowerShell opened with **Run as administrator** (`net stop winnat`,
then `net start winnat`) often frees them.

To fix it, stop the other program, or give this container different ports on
the computer. In `-p` and in `compose.yaml`'s `ports:`, the left number is the
computer's and the right one stays as it is:

- `-p 2457:2456` (Compose: `"2457:2456"`): Fishbowl Clients connect to port
  2457 instead. Not tested here; if Clients have trouble, free 2456 instead.
- `-p 127.0.0.1:6081:6080` (Compose: `"127.0.0.1:6081:6080"`): the page is at
  http://localhost:6081/, so change 6080 to 6081 in the links `fishbowl-link`
  prints.

Either way, **recreate** the container rather than starting it again. In testing
(Docker Engine 29.9.3), a container that had failed this way and was started
again ran without its published ports, so the page and port 2456 stayed out of
reach even after the port was free. A container that never started holds no
data, so recreating it costs nothing:

- With `docker run`: `docker rm fishbowl`, then the `docker run` command again
  (with the new numbers, if you changed them).
- With Compose: change the numbers in `compose.yaml` if you're changing them,
  then `docker compose up -d --force-recreate`.

### From the install guide's troubleshooting section, in a container

| Guide symptom | In this container |
|---|---|
| MySQL won't start after adding `lower_case_table_names` (9.1) | Shouldn't happen: the setting is in the image before MySQL initializes, the container resets the option files' permissions before each MySQL start (MySQL ignores world-writable ones), and setup stops before installing Fishbowl if MySQL doesn't report `1`. |
| Config file permission denied, SELinux (9.2) | Not inside the container. On a Fedora/RHEL host with SELinux, named volumes work; for bind mounts add `:Z` (for example `-v /srv/fishbowl/mysql:/var/lib/mysql:Z`). |
| Can't reach the MySQL socket as a regular user (9.3) | Use `docker exec -it fishbowl mysql -u root -p`. |
| "No suitable Java Virtual Machine could be found" (9.4) | Not applicable: the image has only Java 21 and points the installer at it. |
| Installer window blank or white (9.5) | Not applicable: the installer runs unattended. |
| Bash error with `!` in the password (9.6) | Not applicable: the image's password has `!`, `$`, `^`, `%` and `=` in it, and every script handles them. |
| MySQL 9.x instead of 8.4 (9.7) | Not possible: the image build fails unless MySQL is 8.4.x. |

### Container-specific

| Symptom | Fix |
|---|---|
| The page doesn't load | The container needs `-p 127.0.0.1:6080:6080` (or Compose's `ports:`), and you must open it on the computer that runs Docker. `docker ps` shows the published ports. Recreate the container with the port; your data is on the volumes. |
| The Integrations group, the Plugins list or a plugin is missing or empty | Run `docker exec fishbowl fishbowl-netcheck`. It shows whether the container reaches Fishbowl's license and plugin servers, and what blocks them. See [Network and firewall](#network-and-firewall-licenses-plugins-integrations). |
| "That access code isn't right" / the link stopped working | Get the current link: `docker exec fishbowl fishbowl-link`. Someone may have replaced the code (`--new-code`). |
| Fishbowl Server didn't start: "Trial accounts do not have access to update the database" | The selected database was made by an older Fishbowl version, and a trial installation can't update it. Enter a purchased license (Server Administration → License) and press Start, or select another database. Nothing was changed in the database. |
| Fishbowl Server didn't start, with another reason from Fishbowl | Open Server Administration from the page to check the license and the database, then press Start. Fishbowl's own log: `docker exec fishbowl tail -n 50 /opt/Fishbowl/logs/fbserver.log`. |
| "Fishbowl Server is still starting after …s" | Normal after an upgrade or with an older database: Fishbowl updates the database before it listens. Let it finish; don't stop the container. |
| Setup failed: "The Fishbowl installer exited with status 1 … Docker is out of disk space" | Free some disk (`docker system df` shows what's using it; `docker builder prune` removes old build cache) or give Docker Desktop a bigger disk, then submit the form again. An unfinished setup starts over cleanly. |
| An upload fails with "Not enough free disk space in Docker" | The same: free disk, then upload again. |
| Server Administration's tab shows a closed window right away | Server Administration was closed (OK or Cancel) or failed to start; `docker exec fishbowl tail /var/lib/fishbowl/logs/session-admin.log`. Press **Open it again**. |
| Changes made in Server Administration didn't take effect | Press **Restart Fishbowl Server** on the page. The log should show `Applied the settings changed in Server Administration`. |
| The Restore tab doesn't list the file | The Restore tab lists `.sql` files only: unzip a zipped backup first. Other file types you uploaded are in the same `import` folder for Fishbowl's other file choosers. Uploaded or copied files are in the `import` folder; type the full path in File Name if needed: `/var/lib/fishbowl/import/<file>.sql`. |
| "Another container is already using these volumes" (exit 6) | Stop the other container first; two MySQL servers on one data directory would corrupt it. |
| "This container has no named volumes" | See [First-time setup](#6-first-time-setup). The log prints the commands to fix it. |
| The container keeps restarting with exit code 137 under load | Usually out of memory (`docker inspect -f '{{.State.OOMKilled}}' fishbowl` says `true`, on every system): give Docker more memory ([section 2](#how-much-memory-docker-gets)). |
| Warning: "Fishbowl … reports version X, but this container last installed Y" | Fishbowl updated itself. Set Auto Updates to *Never* in Server Administration → Server and update through new images. |
| The log shows `java.net.ConnectException: Connection refused` at each Fishbowl Server start | Fishbowl Server makes an outgoing web request when it starts. In testing the container had no direct internet access, this error appeared every time, and the server worked normally. |
| `OpenJDK … warning: Options -Xverify:none and -noverify were deprecated` | Comes from the Java options in Fishbowl's own launchers. Fishbowl ran normally with it in testing. |
| `docker stop` takes long | Fishbowl Server and MySQL are shutting down cleanly: `--stop-timeout 180` (Compose: `stop_grace_period`) gives them time. |
| `Read-only file system` in the log, or `mkdir: cannot create directory '/run/…'` at start | The container was started with `--read-only` but without the three `--tmpfs` options (or with an older `compose.yaml`). Use the full command from [section 4](#4-start-it-and-starting-automatically); your data is on the volumes. |
| "This image's system packages are N days old" (log or page) | The weekly maintenance hasn't rebuilt the image for a while. Check the scheduled task and `fishbowl-maintain.log` ([Weekly maintenance](#weekly-maintenance-set-it-up-once)), or run it once by hand. |
| `fishbowl-maintain.log` says "STOPPED" | It changed nothing and says why on that line. A failed build or backup is safe to retry; "busy" means a setup or an upgrade was running, and the next run tries again. |
| `fishbowl-maintain.log` says "Rolled back" (exit status 2) | The new images didn't come back where they were, so every container runs its previous image again. The containers' logs are in `fishbowl-maintain-failed-*.log` next to `compose.yaml`, and the new images are kept as `:failed` (`fishbowl-server:failed`, `fishbowl-page:failed` and so on). |

### Build problems

| Message | Fix |
|---|---|
| `No Fishbowl installer found on the release …` | Upload the installer to the `fishbowl-installer` release. |
| `Found 2 Fishbowl installers …` | Delete the old one; keep exactly one. |
| `Can't read a version from the asset name …` | Keep Fishbowl's file name, `Fishbowl-<version>.sh`. |
| `SHA-256 mismatch` / size mismatch | The upload or download was damaged; upload again. |
| `This installer requires Java X …` | A Fishbowl version moved off Java 21: the Dockerfile's Java package needs updating and re-testing. |
| `invalid response status 404` on the `ADD …/releases/tags/…` step | The release doesn't exist, is a draft, or the repository is private. |
| `invalid response status 403` or `429` on that step | Most likely GitHub's limit for unauthenticated API requests (60 an hour, counted per IP address). Wait and build again. |
| The build can't fetch the repository (an error mentioning git) | The repository name or branch in the build URL is wrong, or the repository is private. |

## 18. Versions and verification

| | |
|---|---|
| Fishbowl Advanced | **26.11** (`Fishbowl-2026.11.sh`, 756,290,571 bytes, SHA-256 `9094bc0c4961214c1156c21ca9a502350539b6ecd1d8f7e2bb81e4c063d85a2c`, released 17 November 2026) |
| MySQL | **8.4.13** (Fedora 44 `mysql-server-8.4.13-2.fc44`) |
| Java | **Eclipse Temurin 21.0.13.1+2** (`temurin-21-jdk`) |
| Browser windows | TigerVNC 1.16.2 (`Xvnc`), openbox 3.6.1, noVNC 1.5.0, websockify 0.12.0 (Fedora 44) |
| The Compose stack | Fishbowl Server and the page on Red Hat UBI 9 minimal (Python 3.9), Java **Temurin 21.0.13.1+2 JRE** (`temurin-21-jre` from Adoptium's EL9 repository), MySQL **8.4.13** (official `mysql:8.4`, Oracle Linux 9, also the client tools), the windows on AlmaLinux 9 (TigerVNC 1.16.2, openbox 3.6.1 from EPEL, websockify 0.12.0 from PyPI, pinned by hash), Caddy 2, HAProxy LTS, Squid on Alpine 3 |

The versions above are what the image was tested with; a rebuild picks up
Fedora's and Adoptium's current 8.4.x and 21.x updates (the build refuses
anything else). Each build downloads the installer again.

### What was verified by running it, and what wasn't

Tested on Docker Engine 29.9.3 (Linux, x86-64) with the 26.11 installer (and 26.10
before it), using
the 14 Day Trial, with the pages in headless Chromium. `tests/run-checks.sh`
repeats the checks marked *(suite)*.

| Check | Status |
|---|---|
| Build finds the one installer on the release, verifies size and SHA-256, reads the version from the file name; fails clearly with zero or two installers; a replaced installer builds the new version with the same command | Verified against a local stand-in for GitHub's API *(suite)* |
| Image build proves MySQL 8.4.x and Java 21 and stops on anything else, and finds the browser-window pieces | Verified *(suite)* |
| Started detached with no terminal: stays up and waits on the page; also when started with no volumes at all (Docker's unnamed volumes, with the warning) | Verified *(suite)* |
| The page needs its access code; wrong codes refused; requests not from the page refused; `--new-code` signs browsers out | Verified *(suite)* |
| Setup form: shows the installer's license text; refuses without acceptance or with a stale text; trial install with no password to choose; acceptance recorded with how it was given | Verified *(suite)*, and clicked through in Chromium |
| `fishbowl-setup` at a terminal: declining, end of input or "y" installs nothing; a full setup | Verified *(suite: declines)*; full setup verified once |
| Server Administration in its browser window: create a database, Restore tab with the uploaded file, select a database, the OK dialogs; Fishbowl Server starts by itself | Verified in Chromium through the page, and over VNC *(suite)* |
| The Fishbowl Client in its browser window: opens connected to Fishbowl Server, fills and follows the tab, force close and reopen | Verified in Chromium; opening it *(suite)*. Working in the Client beyond its first-time wizard wasn't tested. |
| Pasting into a Fishbowl window through the clipboard box | Verified in Chromium |
| The MySQL password is never in the page's status data, its pages or its scripts; Server Administration's pre-filled Password field is right as it is: a new database, a restore, and the 54 MB reference restore all worked with the field untouched | Verified *(suite)* |
| A cleared Password field comes back: **Cancel** and **+** in the new-database dialog; closing and reopening Server Administration on the Restore tab | Verified once by hand (screenshots), not in the suite |
| **Restoring a real Fishbowl backup** (54 MB, made by Fishbowl 2026.7: 320 tables, 48 views, 423,215 rows) through the page and the Restore tab | Verified: the restored database is identical to a direct load of the file, table by table; Fishbowl suggested the name from the file name; the restore added it to the Database tab *(suite with `--reference-sql`)* |
| Selecting that 2026.7 database on a trial installation | Fishbowl Server refused ("Trial accounts do not have access to update the database"); the page showed it within seconds, the container stayed up, the database was unchanged, Server Administration still opened *(suite with `--reference-sql`)* |
| A backup made by the same Fishbowl version: upload, restore into a new database, select it, Restart on the page → runs on it | Verified *(suite)* |
| Settings changed in Server Administration while Fishbowl runs take effect with the page's Restart button | Verified *(suite)* |
| Stop and Start on the page | Verified *(suite)* |
| Fishbowl Server or MySQL killed: started again in place | Verified *(suite)* |
| Killed without a clean shutdown, with a stale MySQL lock file that used to stop MySQL from starting | Reproduced the failure, then verified the fix *(suite)* |
| Docker restarted (the test machine rebooted three times): the container came back to running by itself with `--restart always` | Observed |
| Recreating the container on the same volumes: no questions, same data; a second container on the same volumes refused | Verified *(suite)* |
| No database ships in the image: the folders that become its volumes hold no files, and its only `.sql` files are two that MySQL's own package installs | Verified *(suite)* |
| A new installation starts with no database: after setup MySQL holds only its system databases (`information_schema`, `mysql`, `performance_schema`, `sys`), none is selected, the import folder is empty | Verified *(suite)* |
| `docker compose down -v` removes the three fixed-name volumes; `docker compose up -d --force-recreate` keeps them | Checked with a stand-in compose project (Docker Compose v5.7.0) |
| Network: there's no firewall inside the container; Fishbowl Server listens for the network on 2456 and 28192 only (MySQL and 7770 on the container's loopback); both answer through their published ports | Verified *(suite)*, and the listeners listed by hand with Fishbowl Server running |
| `fishbowl-netcheck` and the warning a minute after start: they report Fishbowl's servers by name and what listens for the network, flag anything outside 2456, 28192 and 6080 (a test listener on 8080 is caught and fails the check), and warn exactly when a server is blocked | Verified *(suite)* in a network that refuses outbound port 81, as a firewall would. Not run where Fishbowl's servers are reachable (this test network passes 80 and 443 through a proxy). |
| What Fishbowl 26.10 and 26.11 contact: the names and ports read from their program files (the same 21 names and ports in both, compared on 23 November 2026); on 17 November 2026 the license and plugin names pointed at 74.63.56.90; the plugin update check fails at every start when port 81 is blocked (`Stream is invalid` in `fbserver.log`) | Checked by hand |
| The Windows and Linux firewall commands for 2456 and 28192 | **Not run** (no Windows here, and no firewalld in the test machine) |
| Updating (section 12), run end to end in bash from the README's own blocks, on a trial installation with a company database: steps 1 to 6 (the old image kept by tag, the new one built, the backup written and read back, the new image on the same volumes, the upgrade, every table checksum unchanged), a damaged backup refused with the volumes untouched and `docker start` bringing it back, then going back to the backup (the old version runs on the data exactly as at the backup) | Verified once. The build read a local copy of this repository and a stand-in for the GitHub release, and the "new version" was the same installer named 2026.10.1, so Fishbowl's own database update at first start of a really new version wasn't exercised. |
| The same blocks in zsh and in PowerShell 7 hand `docker` exactly the same arguments as in bash | Checked against a stand-in `docker` that records its arguments. Not run on Windows, in Windows PowerShell 5.1 or on a Mac; Compose's `docker compose build` from GitHub not run here. |
| After setup: MySQL 8.4.10, `lower_case_table_names = 1`, heap 8192 MB, client 2048 MB, non-root processes, *healthy* | Verified *(suite)* |
| License key and the MySQL password absent from `docker logs`; the password not written into the volumes | Verified *(suite)* |
| Upgrade on the page (a stand-in newer version): offered, not without acceptance, a wrong password given on the page caught early, backup, upgrade, data and memory kept; an interrupted upgrade is finished before Fishbowl starts; downgrade refused; a trial isn't offered the upgrade | Verified *(suite)* |
| `fishbowl-upgrade` at a terminal | Verified once |
| The update at start on a writable container (`update-all.sh`): runs once in the background after the start delay, never restarts anything or asks, changes only files, skips MySQL and Java versions outside 8.4 and 21, stays off with `FISHBOWL_AUTO_UPDATE=0`, fails clearly when offline, keeps a few logs, waits for setup and upgrade jobs, and a real update of MySQL 8.4.10 to 8.4.13 still passes the runtime check | Verified *(suite: stand-in `dnf` tests, plus one real update)* |
| **The hardened start** (read-only root filesystem, memory-only `/run`, `/tmp` and `/var/tmp`, `--cap-drop ALL` plus six, `no-new-privileges`, `--pids-limit 4096`): every check in this table marked *(suite)* passes on containers started that way, and nothing in the setup, MySQL, Fishbowl or session logs ran into the read-only root | Verified *(suite with `FBCHECK_RUN_ARGS` set to the README's flags: 94 passed, 0 failed)* |
| The single container after the Compose stack's changes to the shared scripts: the whole suite again, with the hardened flags | Verified *(suite: 93 of 94 on the full run; the one miss was a build message I had reworded, put back as it was, and the 10 build checks then passed)* |
| Each of the six kept capabilities is needed: without `CHOWN` or `FOWNER` the first start stops; without `DAC_OVERRIDE` the page never gets a state; without `KILL` setup never finishes and `docker stop` has to kill the container after 180 seconds; without `SETUID` or `SETGID` nothing can start as its own user | Verified once (a fresh container per capability left out) |
| `fishbowl-backup` without a terminal: uses the image's password, keeps only the newest N of its label, stops with status 3 when the installation has a password of its own | Verified *(suite)* |
| README commands: bash, zsh and PowerShell hand `docker run` identical arguments, the hardened flags included; the scheduling commands parse in all three; the maintenance script runs under macOS's bash 3.2 | Verified with a stand-in `docker` (PowerShell 7 in a container, not Windows PowerShell 5.1). The bash 3.2 run was before the maintenance script learned the Compose stack's other images; it still uses only what bash 3.2 has, but this version wasn't run in bash 3.2 again. |
| `update-all.sh --build` in every image build: strict about a repository it can't read (the build stops), always runs the runtime check and the `mysqld` fix, writes no log files; on a read-only container `update-all.sh` changes nothing and says updates come from rebuilds | Verified *(suite: stand-in `dnf`)*; every suite build also runs it for real |
| An image not rebuilt for over 14 days: the container's log warns, and the page's data carries the image's age for its warning | Verified *(suite)*; the warning card itself wasn't clicked through in a browser |
| A MySQL data directory made by 8.4.10 started on 8.4.13 after the update: data kept, server upgrade completed | Verified once by hand, not in the suite |
| Picture settings (30 frames a second, higher noVNC quality, smoother text in Java, idle memory returned) | The windows still open and work in the suite. I didn't measure CPU or memory before and after, and I didn't compare screenshots on a high-resolution screen. |
| `fishbowl-backup`, the `restore` command | Verified *(suite)* |
| The commands in this README for each system: Linux and macOS blocks run in bash and pasted into an interactive zsh 5.9 with its default options; Windows blocks parsed and run in PowerShell 7 (on Linux), each against a stand-in `docker` that records its arguments; `--platform linux/amd64` and `compose.yaml` checked against Docker Engine 29.9.3 | Checked that way. Not run on a Mac, on Windows, or in Windows PowerShell 5.1. |
| Docker Desktop on Windows 11 | The build from GitHub completed in the maintainer's own run. Starting the container there isn't confirmed yet. |
| A purchased license: licensed setup, licensed upgrade, Fishbowl updating an older database (such as the 2026.7 backup) at its first start | **Untested** (needs a real license key) |
| The real GitHub repository: the `docker build` URL, the release download, the web upload, the Actions workflow, ghcr.io | The build URL and release download worked in the maintainer's runs on Linux and Windows; the rest is untested from here |
| Docker Desktop on macOS and Linux, Apple Silicon (x86-64 emulation), Windows on ARM, Firefox and Safari, more than one person using the windows at once | Untested |
| Running natively on `linux/arm64`; rootless Docker; Podman; behavior under production load (memory figures are estimates) | Untested |

### The Compose stack: what was verified

Tested on Docker Engine 29.9.3 (Linux, x86-64) and Docker Compose 5.7.0 with the
26.11 installer and the 14 Day Trial, in a test network whose way out is another
proxy that passes HTTPS only. Apart from `tests/maintain-check.sh`, the scripts
that ran these checks aren't in `tests/` yet.

| Check | Status |
|---|---|
| A new site on six empty volumes: setup on the page, Fishbowl installed by the server container as uid 1000 (30 s), a company database created in Server Administration in the desktop container with **Host** left as `localhost` and the Password as Fishbowl filled it in, Fishbowl Server running 16 s after Server Administration closed; no file of the installation owned by root | Verified (through the edge and the page's WebSocket, the way a browser does it) |
| An upgrade on the page to a stand-in newer version (the same installer named 2026.11.1): backup first, the installer as uid 1000, data kept, running and healthy afterwards | Verified. A real new Fishbowl version's database update wasn't exercised. |
| The Restore tab: the 54 MB reference backup uploaded on the page and restored through `localhost` into the database container | Verified (368 tables in 66 s) |
| Moving a single container's volumes into the stack: no setup, the page's access code kept, Fishbowl Server running 26 s after `docker compose up -d`, no refused first start | Verified. Going back to the single container wasn't run end to end. |
| Every long-running container: non-root user, read-only image, no capabilities, `no-new-privileges`, no uid-0 process; no setuid or setgid files in the server, page and desktop images; no image carries the MySQL root password file; the server image has no compiler, GTK or X server | Verified. Trivy and Docker Bench for Security weren't run here. |
| Networks: only the edge publishes ports (6080 on 127.0.0.1 only); `app` and `data` internal; the page isn't on `data` and can't reach MySQL; no direct way out from any Fishbowl container; root signs in only from `localhost` and the data network | Verified |
| The egress proxy: Fishbowl Server's own calls arrive there; names off the list, IP addresses and other ports refused; `FB_EGRESS_EXTRA` | Verified. The test network's own proxy relays HTTPS only, so Fishbowl's plain-HTTP calls (80, 81) failed past the egress proxy here. |
| HTTPS: the page over TLS with the edge's own certificate authority, Secure cookie, same-origin checks, TLS 1.1 and older refused; TLS for Clients on 2456 (`FB_CLIENT_TLS=edge`) reaches Fishbowl Server's web app and API | Verified. A Fishbowl Client signing in over Secure Connection, and a public certificate, weren't tested. |
| Server Administration and the Client in the desktop container, drawn through the edge and the page at the browser's size; the Client signed in to Fishbowl Server in its own container | Verified |
| A frozen Fishbowl Server (TCP still connects, HTTP doesn't answer): restarted in place 26 to 30 s after it froze, running again within a minute, 10 of 10 over two series | Verified |
| The server container's main process killed from the host: Docker restarted it within 2.5 s and it was healthy again within 21 s, 10 of 10 over two series | Verified |
| MySQL killed from the host (Docker restarts it within a second): Fishbowl Server restarted by itself and a Client could sign in afterwards, 6 of 6 over two series | Verified (before the fix, Fishbowl Server didn't notice and sign-ins failed) |
| Four unplanned stops within ten minutes: Fishbowl Server stays stopped, the container stays up for the page | Verified |
| Docker restarted, and once the test machine itself: every container healthy again with no command (25 to 30 s after a Docker restart; 62 s for Fishbowl Server after the machine's cold start) | Verified |
| Start-up time: container start to healthy 16 to 23 s over ten restarts (two series of five) | Measured |
| `FB_SERVER_XMX` in `.env` (for example `6g`): Fishbowl Server's heap at its next start, over Server Administration's memory setting; removed again, Server Administration's setting is back | Verified with `4096m` and `6g` (Java ran with that `-Xmx`, and the log says what changed), then back to 8192 MB |
| Logs: every line timestamped in UTC, the same events in the same order over two restarts, no password or access code in any container's log, rotation set | Verified |
| `docker compose down --volumes` keeps the six volumes; the dumps and settings files identical after a rebuild; Fishbowl back without setup | Verified |
| The backup container: a set with every database, each company database alone, the settings files and the reports; owner-only; `--verify`; a damaged dump caught; a drill restore matching the live database row for row | Verified |
| The weekly maintenance on the stack (`fishbowl-maintain.sh`): every image rebuilt with the package updates, a backup first, every container recreated on its new image and back where it was, the old images kept as `:previous`. A new Fishbowl Server image that never comes back: status 2, the new images kept as `:failed`, the containers' logs saved, every container back on the image it ran before | Verified *(`tests/maintain-check.sh`: 12 passed, 0 failed)*. Its first run here found that the backup step refused to run as the server container's user, so every weekly run stopped before changing anything; fixed. |
| The same with `fishbowl-maintain.ps1` | Verified in PowerShell 7.4 on Linux, against the same Docker *(`tests/maintain-check.sh --powershell`: 12 passed, 0 failed)*. Its first run here found that the wait for the stack to come back counted a failure as success (a PowerShell function returns everything it writes along with its result), so a broken image would have stayed; fixed. Not run in Windows PowerShell 5.1, which the scheduled task uses, or on Windows. |
| Fishbowl's own updates in the stack, Docker Desktop | **Not run** with the stack (Fishbowl's own updates need a purchased license) |

