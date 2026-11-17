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
  fishbowl
docker exec fishbowl fishbowl-link
```

**Windows (PowerShell)**

```powershell
docker build --platform linux/amd64 -t fishbowl "https://github.com/cesiumskater/Docker_Testing.git#main"
docker tag fishbowl "fishbowl:$(docker run --rm --platform linux/amd64 fishbowl version)"
docker run -d --platform linux/amd64 --name fishbowl --restart always --stop-timeout 180 -p 2456:2456 -p 28192:28192 -p 127.0.0.1:6080:6080 -e TZ=America/Denver -v fishbowl-mysql:/var/lib/mysql -v fishbowl-app:/opt/Fishbowl -v fishbowl-data:/var/lib/fishbowl fishbowl
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

`compose.yaml` holds the same settings. Keep it in a folder of its own and run
Compose from that folder; it builds the image from GitHub too, if it isn't
there yet.

**Linux and macOS**

```bash
mkdir -p ~/fishbowl
cd ~/fishbowl
curl -fsSLO https://raw.githubusercontent.com/cesiumskater/Docker_Testing/main/compose.yaml
docker compose up -d
docker exec fishbowl fishbowl-link
```

**Windows (PowerShell)**

```powershell
New-Item -ItemType Directory -Force "$HOME\fishbowl" | Out-Null
cd "$HOME\fishbowl"
curl.exe -fsSLO https://raw.githubusercontent.com/cesiumskater/Docker_Testing/main/compose.yaml
docker compose up -d
docker exec fishbowl fishbowl-link
```

`compose.yaml` sets `TZ` to UTC. To change it, edit `TZ:` in the file with any
text editor and run `docker compose up -d` again; the data stays on the
volumes.

Pick either `docker run` or Compose for this container, not both: both want the
name `fishbowl`. They use the same volumes, so switching is fine once the old
container is gone (`docker compose down`, or `docker stop fishbowl` and then
`docker rm fishbowl`).

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
12. [Updating to a new Fishbowl version](#12-updating-to-a-new-fishbowl-version)
13. [Security](#13-security)
14. [Maintaining this repository](#14-maintaining-this-repository)
15. [Reference](#15-reference)
16. [Troubleshooting](#16-troubleshooting)
17. [Versions and verification](#17-versions-and-verification)

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
(for example `fishbowl:2026.10`), so that version stays available after you
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
[Maintaining this repository](#14-maintaining-this-repository)), you can skip
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
  fishbowl
```

**Windows (PowerShell)**

```powershell
docker run -d --platform linux/amd64 --name fishbowl --restart always --stop-timeout 180 -p 2456:2456 -p 28192:28192 -p 127.0.0.1:6080:6080 -e TZ=America/Denver -v fishbowl-mysql:/var/lib/mysql -v fishbowl-app:/opt/Fishbowl -v fishbowl-data:/var/lib/fishbowl fishbowl
```

or `docker compose up -d` in the folder with `compose.yaml` (edit `TZ` in it
first).

| Option | Why |
|---|---|
| `-d` | Runs in the background. No terminal is needed at any point. |
| `--platform linux/amd64` | The image is x86-64. Changes nothing on an x86-64 computer; on a Mac with Apple Silicon, Docker runs it under emulation. |
| `--restart always` | Starts the container again whenever Docker starts, and whenever it stops for a reason other than `docker stop`. |
| `--stop-timeout 180` | Gives Fishbowl Server and MySQL up to 3 minutes to shut down cleanly. |
| `-p 2456:2456` | Fishbowl Clients connect here. |
| `-p 28192:28192` | Fishbowl's API ("Legacy Port"): integrated apps and integrations on other computers connect here. |
| `-p 127.0.0.1:6080:6080` | The Fishbowl page, reachable from this computer only. See [Security](#13-security) before changing it. |
| `-e TZ=…` | Your time zone, as a tz database name (Fishbowl and MySQL use it for dates). Defaults to UTC. |
| the three `-v` | Your installation and data. They outlive the container: remove and recreate it any time. |

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
with 26.10 defaults to the server's web port (`ServerPort=2456`,
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
14](#14-maintaining-this-repository)). The steps below move your server to it.
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
example `fishbowl:2026.10`. The version tag keeps it on your computer after the
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
  fishbowl
```

**Windows (PowerShell)**

```powershell
docker rm fishbowl
docker run -d --platform linux/amd64 --name fishbowl --restart always --stop-timeout 180 -p 2456:2456 -p 28192:28192 -p 127.0.0.1:6080:6080 -e TZ=America/Denver -v fishbowl-mysql:/var/lib/mysql -v fishbowl-app:/opt/Fishbowl -v fishbowl-data:/var/lib/fishbowl fishbowl
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
`docker image rm fishbowl:2026.10`. That removes the image only, never data.

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
OLD="fishbowl:2026.10"
docker stop fishbowl
docker run --rm --platform linux/amd64 --entrypoint sh -e BACKUP="$BACKUP" \
  -v fishbowl-mysql:/volumes/mysql -v fishbowl-app:/volumes/app -v fishbowl-data:/volumes/data \
  -v "$PWD":/backup "$OLD" -c 'tar -tzf /backup/$BACKUP > /dev/null || { echo BACKUP FAILED, the volumes were not changed; exit 1; }; find /volumes/mysql /volumes/app /volumes/data -mindepth 1 -delete && tar -xzpf /backup/$BACKUP -C /volumes && echo Restored from $BACKUP' && docker tag "$OLD" fishbowl && docker rm fishbowl
```

**Windows (PowerShell)**

```powershell
$BACKUP = "fishbowl-volumes-20261117-093000.tar.gz"
$OLD = "fishbowl:2026.10"
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
  Fishbowl's reason ([Troubleshooting](#16-troubleshooting)).

### Updates to the system inside the container (MySQL, Java and the rest)

Separate from Fishbowl's own versions above. **Every time the container starts,
it updates its own Fedora packages in the background**: the operating system
libraries, MySQL 8.4, Java 21 (Eclipse Temurin) and the pieces behind the browser
windows. This is `update-all.sh`, a container edition of the update script it
was modeled on.

- **It never restarts anything and never asks.** It starts 90 seconds after the
  container does (after MySQL and Fishbowl Server have had their turn), at low
  priority, and only replaces files. Programs that are already running keep
  using the old ones; the new ones are used the next time the container starts
  (`docker restart fishbowl`, or whenever Docker starts it). Nothing on the page
  or in the log asks you to restart.
- **It's quiet.** The details are in `/var/lib/fishbowl/logs/update-*.log` (the
  five newest are kept). The container's own log gets one line, and only when
  packages changed or something went wrong.
- **It gets out of the way.** A first-time setup or a Fishbowl upgrade that
  starts while an update is running waits for it to finish (a few minutes at
  most), and an update that comes due while one of those runs waits for it.
  Stopping the container ends an update that is still waiting at once, and lets
  a package that is being installed finish first.
- **It keeps Fishbowl's requirements.** An update that would move MySQL off 8.4
  or Java off 21 is left out and the rest still updates. After an update it puts
  back the change to `mysqld` that the image makes at build time (a newer MySQL
  package undoes it, and `mysqld` then refuses to start under Docker's default
  settings) and runs the same MySQL 8.4 / Java 21 / browser-window check as the
  image build. If that check fails, the log says so and the container's log gets
  a warning. Recreate the container from the image to get back to the tested
  versions; your data is in the volumes and isn't affected.
- **It doesn't upgrade Fishbowl.** A new Fishbowl version needs someone to accept
  its license agreement, so that stays on the page (or `fishbowl-upgrade`).
  It doesn't touch your computer either: the Docker host's own updates are yours
  to run.
- **It needs a network connection from inside the container** to Fedora's package
  servers and to `packages.adoptium.net`. Without one it says so in the log,
  changes nothing and tries again at the next start. Packages are checked with
  the repositories' signatures (`gpgcheck=1`).
- **Updates live in the container, not in a volume.** They survive
  `docker restart`, but a container that is removed and created again (a new
  image, `docker compose up --force-recreate`) starts from the image's package
  versions and updates again 90 seconds later. Rebuild the image now and then
  and the image carries the newer versions.
- **To turn it off:** start the container with `-e FISHBOWL_AUTO_UPDATE=0` (or
  `environment:` in `compose.yaml`). **To run it by hand:**
  `docker exec fishbowl update-all.sh` (it prints what it does; the changes are
  used from the next container start, as always).

A MySQL update is a patch release inside 8.4, which MySQL installs over an
existing data directory by itself the next time it starts. **Take a backup
(`fishbowl-backup`) before you restart after MySQL was updated**, as you would
before any MySQL update. I tested this once by hand: a data directory made by
8.4.10 started on 8.4.13 after the update, upgraded itself, and kept its data
(see section 17).

## 13. Security

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
  Client run as `fishbowl`, MySQL as `mysql`. Neither is root.
- **Your license key** goes from the form to the container through memory
  (`/dev/shm`, owner-only, deleted as soon as it's read) and never appears in the
  logs. The MySQL root password is never shown on the page, in its data or in the logs
  (next section); the checks in `tests/` make sure
  it isn't written to the logs or into the volumes.
- MySQL listens on 127.0.0.1 inside the container only.

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

There's no firewall inside the container. Everything may go out, and Docker lets
in only the ports you publish. So when a connection is blocked, it's blocked
outside the container: by the firewall on the computer that runs Docker, the
router, or the network.

**What Fishbowl Server reaches on the internet.** Licenses and plugins depend on
Fishbowl's servers, and so do modules in the Client's **Integrations** group
(Accounting, Merchant Services, Plugins, and plugins such as ShipExpress).
Fishbowl 26.10 contacts its servers by name. These names come from its own
program files:

| Name | Port | For |
|---|---|---|
| `fishbowlconnect.com` | 81 (HTTP) | Plugins: the list in the Plugins module and the plugin update check, which runs at every start |
| `fishbowlconnect.com` | 443 | Plugin downloads, payments, what's new |
| `artanis.fishbowldev.com` | 443 | License, subscription, feature and plugin checks |
| `files.fishbowlinventory.com` | 80, 443 | The security patch list, file downloads |
| `www.fishbowlinventory.com` | 443 | Fishbowl's web pages (help and sales links) |

Integrations with other companies need their servers too, for example Intuit's
(`quickbooks.api.intuit.com`, `appcenter.intuit.com` and others) for QuickBooks
Online.

Allow these by name if your firewall can. On 17 November 2026 the first four
names all pointed at **74.63.56.90**. That isn't one of the addresses on
Fishbowl's network cutsheet (97.75.181.39, 97.75.181.50 and 199.79.55.108), so a
firewall that allows only the cutsheet's addresses blocks the license and plugin
checks. `www.fishbowlinventory.com` is behind Cloudflare, whose addresses change.
Port 81 is the one most often blocked. When it is, Fishbowl writes `Stream is
invalid` followed by `java.net.ConnectException` to
`/opt/Fishbowl/logs/fbserver.log` a few seconds after every start: that's the
plugin update check failing.

**Check it from the container:**

```
docker exec fishbowl fishbowl-netcheck
```

It tries each of these, and the cutsheet's addresses, from inside the container,
shows what listens for the network, and says what's blocked and how (refused,
no answer, or a name that doesn't resolve). The container also runs it once, a
minute after every start, and writes a warning to its log (`docker logs
fishbowl`) only when something can't be reached; `-e FISHBOWL_NETCHECK=0` turns
that off. It tests whether a connection opens, so a proxy that lets the
connection open and then stops the request can still get in the way.

**What comes in.** Replies to Fishbowl Server's own connections come back on
their own, through Docker and any ordinary (stateful) firewall. So the
cutsheet's inbound lines from Fishbowl's servers need no rule and no port
forward, and the same goes for its outbound lines from the server to the
Clients. From your network:

- **2456**, Fishbowl Clients: published.
- **28192**, Fishbowl's API (the "Legacy Port"), for integrated apps and
  integrations on other computers: published.
- **3306**, MySQL: not published, on purpose. MySQL listens on the container's
  own loopback, its root user can only log in from inside the container, and its
  password is in this repository. Fishbowl Clients don't need it: their settings
  point only at Fishbowl Server on 2456, and Fishbowl Server reaches the database
  itself. **3305** is MySQL 5.7's port, which this image doesn't have.
- **28182 and 28282** (the cutsheet's "Fishbowl Anywhere"): the HTTP and HTTPS
  ports of the web client Fishbowl ships in `/opt/Fishbowl/webclient`, a Webswing
  server. Nothing starts it here, so nothing listens. It's left off on purpose:
  it would accept connections from any address, its user file ships with the same
  two accounts in every Fishbowl installation, and the Fishbowl page already
  shows the Client in a browser behind its access code.
- **28292** (the cutsheet's "Fishbowl Nexus QuickBooks"): the port of
  `Fishbowl Nexus.exe`, a Windows program. It can't run in this Linux container,
  so a Nexus setup runs on a Windows computer, whose firewall then needs 28292.
- **80, 81, 443 and 8080**: nothing in Fishbowl 26.10 listens on them here.
  Publishing them would only hold those ports on your computer, and 80, 443 and
  8080 are often taken already, which stops the container from starting.

If a later Fishbowl version or feature listens on one of these, `fishbowl-netcheck`
shows it. Publish it like 28192: `-p 28182:28182` on `docker run`, or a line
under `ports:` in `compose.yaml`.

**The firewall on the computer that runs Docker** has to let 2456 and 28192 in
for other computers; the commands are under [the Fishbowl
Client](#9-the-fishbowl-client-in-its-browser-window). Outgoing connections are
allowed by default on Windows, macOS and Linux, so only a policy or security
software that blocks them needs the names above added.

## 14. Maintaining this repository

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
`Fishbowl-2026.10.sh`).

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
bash tests/run-checks.sh --installer ~/Downloads/Fishbowl-2026.10.sh
bash tests/run-checks.sh --installer ~/Downloads/Fishbowl-2026.10.sh \
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

## 15. Reference

### Ports

| Port | Published | What |
|---|---|---|
| 2456 | `-p 2456:2456` | Fishbowl Server's client port ("Port" in Server Administration; `webPort` in `eve.properties`). |
| 6080 | `-p 127.0.0.1:6080:6080` | The Fishbowl page, including the browser windows (their screens travel over the page's WebSocket). |
| 28192 | `-p 28192:28192` | Fishbowl's API, the "Legacy Port" (`port` in `eve.properties`): integrated apps and integrations connect here. |
| 3306, 33060 | never | MySQL, bound to 127.0.0.1 inside the container. |
| 80, 81, 443, 3305, 8080, 28182, 28282, 28292 | not published | On Fishbowl's network cutsheet, but nothing listens on them in Fishbowl 26.10 (see [Network and firewall](#network-and-firewall-licenses-plugins-integrations)). |
| 7770 | never | A Java debug port Fishbowl builds into its service launcher, bound to 127.0.0.1 inside the container. |

The browser windows' VNC servers have no ports at all: they listen on Unix
sockets in `/run/fishbowl/`.

### Commands

The same on Linux, macOS and Windows.

| Command | |
|---|---|
| `docker exec fishbowl fishbowl-link` | The page's link with its access code (`admin` or `client` for a window's link; `--new-code` to replace the code). |
| `docker exec -it fishbowl fishbowl-setup` | First-time setup at a terminal instead of the page. |
| `docker exec -it fishbowl fishbowl-upgrade` | An upgrade at a terminal instead of the page. |
| `docker exec fishbowl fishbowl-admin` | Opens Server Administration and prints its link. |
| `docker exec -it fishbowl fishbowl-backup` | Back up all of MySQL. |
| `docker exec fishbowl fishbowl-netcheck` | Can the container reach the servers Fishbowl uses for licenses and plugins, and what listens for the network? Changes nothing. |
| `docker exec fishbowl update-all.sh` | Update the container's Fedora packages now (also runs by itself at every start). Applies from the next start. |
| `docker run -it --rm --platform linux/amd64 <the three -v> fishbowl restore FILE` | Restore a `fishbowl-backup` file (container stopped). |
| `docker run --platform linux/amd64 … fishbowl admin` | Like the normal start, but Fishbowl Server stays stopped until you press Start on the page. |
| `docker run --rm --platform linux/amd64 fishbowl version` | The image's Fishbowl version, for tagging (`2026.10`). |
| `docker run --rm --platform linux/amd64 fishbowl versions` | Fishbowl, MySQL and Java versions in the image. |

### Environment variables

| Variable | Default | |
|---|---|---|
| `TZ` | `UTC` | Time zone for Fishbowl and MySQL, as a tz database name, e.g. `America/Denver`. |
| `FISHBOWL_PROMPT_TIMEOUT` | `1800` | Seconds each question of `fishbowl-setup` / `fishbowl-upgrade` waits before giving up. |
| `FISHBOWL_ALLOW_TRIAL_UPGRADE` | `0` | `1` offers the upgrade to a trial installation. Fishbowl Server refuses to update a trial's database, so this only works when the new version doesn't change the database; the test suite uses it. |
| `FISHBOWL_AUTO_UPDATE` | `1` | `0` turns off the update of the container's Fedora packages at each start (see section 12). |
| `FISHBOWL_UPDATE_DELAY` | `90` | Seconds after the container starts before the update begins. |
| `FISHBOWL_NETCHECK` | `1` | `0` turns off the network check a minute after each start (it only writes a warning to the log when Fishbowl's servers can't be reached). |
| `FISHBOWL_NETCHECK_DELAY` | `60` | Seconds after the container starts before that check. |
| `FISHBOWL_UPDATE_TIMEOUT` | `1800` | Seconds before an update is given up on. |
| `FISHBOWL_ALLOW_NO_VOLUMES` | `0` | `1` skips the check that the three data paths are volumes (throwaway tests only). |

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
| `/etc/my.cnf.d/50-fishbowl-server.cnf` | Fishbowl's `server/bin/my.cnf` tuning (`max_connections`, `innodb_buffer_pool_size`, `max_allowed_packet`, …), regenerated whenever MySQL starts, minus the two settings the guide controls. |
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
| `FEDORA_IMAGE` | `registry.fedoraproject.org/fedora:44` | Base image. |

## 16. Troubleshooting

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

## 17. Versions and verification

| | |
|---|---|
| Fishbowl Advanced | **26.10** (`Fishbowl-2026.10.sh`, 756,097,431 bytes, SHA-256 `25a0a0d3109c429264afe0af4f69ed49e89fd84fd1cad5c19030b59cfe40d2b5`) |
| MySQL | **8.4.10** (Fedora 44 `mysql-server-8.4.10-1.fc44`) |
| Java | **Eclipse Temurin 21.0.13+9** (`temurin-21-jdk`) |
| Browser windows | TigerVNC 1.16.2 (`Xvnc`), openbox 3.6.1, noVNC 1.5.0, websockify 0.12.0 (Fedora 44) |

The versions above are what the image was tested with; a rebuild picks up
Fedora's and Adoptium's current 8.4.x and 21.x updates (the build refuses
anything else). Each build downloads the installer again.

### What was verified by running it, and what wasn't

Tested on Docker Engine 29.9.3 (Linux, x86-64) with the 26.10 installer, using
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
| `fishbowl-netcheck` and the warning a minute after start: they report Fishbowl's servers by name, the cutsheet's addresses and what listens, and warn exactly when something is blocked | Verified *(suite)* in a network that refuses outbound port 81, as a firewall would. Not run where Fishbowl's servers are reachable (this test network passes 80 and 443 through a proxy). |
| What Fishbowl 26.10 contacts: the names and ports read from its program files; on 17 November 2026 the license and plugin names pointed at 74.63.56.90; the plugin update check fails at every start when port 81 is blocked (`Stream is invalid` in `fbserver.log`) | Checked by hand |
| The Windows and Linux firewall commands for 2456 and 28192 | **Not run** (no Windows here, and no firewalld in the test machine) |
| Updating (section 12), run end to end in bash from the README's own blocks, on a trial installation with a company database: steps 1 to 6 (the old image kept by tag, the new one built, the backup written and read back, the new image on the same volumes, the upgrade, every table checksum unchanged), a damaged backup refused with the volumes untouched and `docker start` bringing it back, then going back to the backup (the old version runs on the data exactly as at the backup) | Verified once. The build read a local copy of this repository and a stand-in for the GitHub release, and the "new version" was the same installer named 2026.10.1, so Fishbowl's own database update at first start of a really new version wasn't exercised. |
| The same blocks in zsh and in PowerShell 7 hand `docker` exactly the same arguments as in bash | Checked against a stand-in `docker` that records its arguments. Not run on Windows, in Windows PowerShell 5.1 or on a Mac; Compose's `docker compose build` from GitHub not run here. |
| After setup: MySQL 8.4.10, `lower_case_table_names = 1`, heap 8192 MB, client 2048 MB, non-root processes, *healthy* | Verified *(suite)* |
| License key and the MySQL password absent from `docker logs`; the password not written into the volumes | Verified *(suite)* |
| Upgrade on the page (a stand-in newer version): offered, not without acceptance, a wrong password given on the page caught early, backup, upgrade, data and memory kept; an interrupted upgrade is finished before Fishbowl starts; downgrade refused; a trial isn't offered the upgrade | Verified *(suite)* |
| `fishbowl-upgrade` at a terminal | Verified once |
| The automatic update (`update-all.sh`): runs once in the background after the start delay, never restarts anything or asks, changes only files, skips MySQL and Java versions outside 8.4 and 21, stays off with `FISHBOWL_AUTO_UPDATE=0`, fails clearly when offline, keeps a few logs, waits for setup and upgrade jobs, and a real update of MySQL 8.4.10 to 8.4.13 still passes the runtime check | Verified *(suite: stand-in `dnf` tests, plus one real update)* |
| A MySQL data directory made by 8.4.10 started on 8.4.13 after the update: data kept, server upgrade completed | Verified once by hand, not in the suite |
| Picture settings (30 frames a second, higher noVNC quality, smoother text in Java, idle memory returned) | The windows still open and work in the suite. I didn't measure CPU or memory before and after, and I didn't compare screenshots on a high-resolution screen. |
| `fishbowl-backup`, the `restore` command | Verified *(suite)* |
| The commands in this README for each system: Linux and macOS blocks run in bash and pasted into an interactive zsh 5.9 with its default options; Windows blocks parsed and run in PowerShell 7 (on Linux), each against a stand-in `docker` that records its arguments; `--platform linux/amd64` and `compose.yaml` checked against Docker Engine 29.9.3 | Checked that way. Not run on a Mac, on Windows, or in Windows PowerShell 5.1. |
| Docker Desktop on Windows 11 | The build from GitHub completed in the maintainer's own run. Starting the container there isn't confirmed yet. |
| A purchased license: licensed setup, licensed upgrade, Fishbowl updating an older database (such as the 2026.7 backup) at its first start | **Untested** (needs a real license key) |
| The real GitHub repository: the `docker build` URL, the release download, the web upload, the Actions workflow, ghcr.io | The build URL and release download worked in the maintainer's runs on Linux and Windows; the rest is untested from here |
| Docker Desktop on macOS and Linux, Apple Silicon (x86-64 emulation), Windows on ARM, Firefox and Safari, more than one person using the windows at once | Untested |
| Running natively on `linux/arm64`; rootless Docker; Podman; behavior under production load (memory figures are estimates) | Untested |
