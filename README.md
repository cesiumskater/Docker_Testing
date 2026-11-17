# Fishbowl Advanced in Docker (Linux)

One container that runs **Fishbowl Advanced Server** on Linux with everything it
needs: **Java 21**, **MySQL 8.4**, and **Fishbowl's own Linux installer**. It
comes with a web page, **the Fishbowl page**, where you do everything else in
your browser:

- first-time setup: Fishbowl's license agreement, your license key (or the
  14 Day Trial) and a MySQL root password
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

```bash
# 1. Build the image straight from GitHub (this also downloads the Fishbowl installer)
docker build -t fishbowl https://github.com/cesiumskater/Docker_Testing.git#main
docker tag fishbowl "fishbowl:$(docker run --rm fishbowl version)"

# 2. Start it. It starts again by itself whenever Docker starts.
docker run -d --name fishbowl --restart always --stop-timeout 180 \
  -p 2456:2456 -p 127.0.0.1:6080:6080 \
  -e TZ=America/Denver \
  -v fishbowl-mysql:/var/lib/mysql \
  -v fishbowl-app:/opt/Fishbowl \
  -v fishbowl-data:/var/lib/fishbowl \
  fishbowl

# 3. Print the link to the Fishbowl page (it includes the page's access code)
docker exec fishbowl fishbowl-link
```

Open the link in a browser on the same computer. The page walks you through
the rest: setup (about half a minute), then your company database (restore a
`.sql` backup or create a new one), after which Fishbowl Server starts by
itself. Fishbowl Clients connect to this computer's name or IP address on
**port 2456**.

With Docker Compose instead of step 2:

```bash
curl -fsSLO https://raw.githubusercontent.com/cesiumskater/Docker_Testing/main/compose.yaml
docker compose up -d          # builds the image from GitHub too, if it isn't there yet
docker exec fishbowl fishbowl-link
```

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
running in this container.

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
| Docker | Docker Engine with BuildKit, and the Docker Compose plugin (`docker compose`) if you use Compose. Tested with Docker Engine 29.9.3. |
| CPU | x86-64 (`linux/amd64`) only. ARM64 (including Apple Silicon running it natively) is untested. |
| Internet | To build: access to GitHub, Fedora's package mirrors and Adoptium's repository. |
| Browser | A current browser on the computer that runs Docker, for the Fishbowl page. Tested with headless Chromium. |
| Disk | About **3.7 GB** for the image, about **1.2 GB** for a fresh install's volumes plus your databases and backups, and about **1.5 GB** of temporary space during install and upgrades. Plan on **10 GB free**. |
| RAM | Plan on **12 GB available to Docker** for Fishbowl Server and MySQL, plus about **2 GB** while the browser windows are open. Details below. |
| Ports | **2456** reachable by Fishbowl Clients. **6080** on 127.0.0.1 for the Fishbowl page. |

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

**Docker Desktop runs containers in a VM with its own memory limit**, which
defaults to 50% of your computer's memory. Raise it with **Memory limit** under
**Settings → Resources → Advanced**. On Windows with the WSL 2 backend that
setting isn't there; the memory is set for WSL itself (Microsoft's WSL
configuration, `.wslconfig`). Docker Desktop wasn't tested here.

## 3. Get the image

### Build it from GitHub (recommended)

```bash
docker build -t fishbowl https://github.com/cesiumskater/Docker_Testing.git#main
docker tag fishbowl "fishbowl:$(docker run --rm fishbowl version)"
```

Docker downloads this repository from GitHub and builds the image. The build
also downloads the Fishbowl installer (about 721 MiB) from this repository's
`fishbowl-installer` release, checks it against the size and SHA-256 that GitHub
reports, and stops with a clear message if the release has no installer or more
than one. No credentials are needed while the repository is public.

The second command gives the image a second name with its Fishbowl version
(for example `fishbowl:2026.10`), so that version stays available after you
build a newer one.

### Or let Docker Compose build it

`compose.yaml` builds the same image from GitHub the first time it's needed
(`docker compose up -d`), or on request:

```bash
curl -fsSLO https://raw.githubusercontent.com/cesiumskater/Docker_Testing/main/compose.yaml
docker compose build
```

### Or pull a ready-made image (only once it's published)

If this repository's GitHub Actions workflow has published the image (see
[Maintaining this repository](#14-maintaining-this-repository)), you can skip
the build:

```bash
docker pull ghcr.io/cesiumskater/docker_testing:latest
docker tag ghcr.io/cesiumskater/docker_testing:latest fishbowl
```

## 4. Start it, and starting automatically

```bash
docker run -d --name fishbowl --restart always --stop-timeout 180 \
  -p 2456:2456 -p 127.0.0.1:6080:6080 \
  -e TZ=America/Denver \
  -v fishbowl-mysql:/var/lib/mysql \
  -v fishbowl-app:/opt/Fishbowl \
  -v fishbowl-data:/var/lib/fishbowl \
  fishbowl
```

or `docker compose up -d` with `compose.yaml` (edit `TZ` in it first).

| Option | Why |
|---|---|
| `-d` | Runs in the background. No terminal is needed at any point. |
| `--restart always` | Starts the container again whenever Docker starts, and whenever it stops for a reason other than `docker stop`. |
| `--stop-timeout 180` | Gives Fishbowl Server and MySQL up to 3 minutes to shut down cleanly. |
| `-p 2456:2456` | Fishbowl Clients connect here. |
| `-p 127.0.0.1:6080:6080` | The Fishbowl page, reachable from this computer only. See [Security](#13-security) before changing it. |
| `-e TZ=…` | Your time zone (Fishbowl and MySQL use it for dates). Defaults to UTC. |
| the three `-v` | Your installation and data. They outlive the container: remove and recreate it any time. |

**Starting automatically.** `--restart always` (Compose: `restart: always`)
starts the container whenever Docker starts. Per Docker's documentation, a
container you stop by hand stays stopped only until Docker itself restarts, so
it comes back after a reboot even if you ran `docker stop` before. Docker itself
has to start with the computer:

- **Docker Desktop:** in **Settings → General**, turn on **Start Docker Desktop
  when you sign in to your computer** (off by default). On Linux,
  `systemctl --user enable docker-desktop` does the same. Docker Desktop starts
  when you *sign in*, not at boot.
- **Docker Engine** (no Desktop; starts at boot, before anyone signs in):
  `sudo systemctl enable --now docker`. That's the better fit for a server that
  should run with nobody signed in.

A container you created without `--restart always` gets it with
`docker update --restart always fishbowl`. To keep it stopped for good,
`docker update --restart no fishbowl`, then `docker stop fishbowl`.

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
volume, and prints a link that includes it each time it starts:

```bash
docker exec fishbowl fishbowl-link          # the page
docker exec fishbowl fishbowl-link admin    # straight to the Server Administration window
docker exec fishbowl fishbowl-link client   # straight to the Fishbowl Client window
docker logs fishbowl | grep code=           # the same link, from the log
```

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
3. **MySQL root password**, twice. At least 8 characters with upper- and
   lower-case letters, a digit and a special character (MySQL's MEDIUM policy);
   any special character works, including `!`, quotes and `$`. You'll type it
   again in Server Administration to create or restore a database, and to
   upgrade, so store it safely: **it isn't saved anywhere in plain text**, and
   this image has no way to reset it.

Then **Install Fishbowl**. The container initializes MySQL, sets your password,
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
four things (the agreement opens in a pager and only a typed `yes` accepts it),
then hands the answers to the container the same way the page does.

**"This container has no named volumes."** A container started without the
three `-v` options (for example from Docker Desktop's Run button) gets unnamed
volumes from Docker. Fishbowl works on them, but they belong to that one
container: a new container won't find them by itself, and removing the
container together with its volumes deletes your install and database. The page
warns about this and asks for an extra tick before installing; the log prints
the commands to start over with named volumes, or to reuse the unnamed ones.

## 7. Your company database: restore a .sql backup or create a new one

Fishbowl Server can't start without a company database. After setup the page
says **No company database is selected yet** and asks whether you have a
Fishbowl backup (a `.sql` file) to restore. Both ways happen in **Fishbowl
Server Administration**, which opens in its own browser tab; Fishbowl Server
starts by itself as soon as a database is selected.

### Restore a .sql backup

Fishbowl's own backups are `.sql` files named like
`MyCompany_2026-11-15-15-42.sql`, made with **Backup Database** in Server
Administration or by the Client's Schedule module.

1. **Upload it** in the **Backups to restore (.sql)** box on the page. It lands
   in the container's **import** folder, and the page shows which Fishbowl
   version made it (read from the file's `databaseversion` table). Larger files
   simply take longer; copying one in works too:
   `docker cp ./MyCompany_2026-11-15-15-42.sql fishbowl:/var/lib/fishbowl/import/`
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
5. **Password:** clear the pre-filled value and type your MySQL root password.
   Host `localhost`, Port `3306` and Username `root` stay as they are.
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
3. **Password:** clear the long pre-filled value first, then type your MySQL
   root password. Click **Connect**.
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
Ctrl+V. Text copied inside the window shows up in the box.

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
| Server memory | Set to 8192 MB at install. A new value takes effect at the next restart; the log shows `Server memory changed in Server Administration: now …` and the heap in `Fishbowl Server is running (heap …)`. Keep Docker's memory limit above it ([section 2](#2-requirements)). |
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
IP address, port 2456**. The client that comes with 26.10 defaults to the
server's web port (`ServerPort=2456`, `UseWebConnection=true` in its
`client.properties`). Allow TCP 2456 through the host's firewall.

## 10. Day-to-day use

| Task | How |
|---|---|
| Open the page | the link from `docker exec fishbowl fishbowl-link` (your browser remembers the sign-in for 30 days) |
| Start, stop, restart Fishbowl Server | the buttons on the page (MySQL and the page keep running) |
| Stop or start the whole container | `docker stop fishbowl` / `docker start fishbowl` (Compose: `docker compose stop` / `up -d`) |
| Status | the page, or `docker ps` (shows *healthy* once Fishbowl Server accepts connections) |
| Log | `docker logs -f fishbowl` |
| Fishbowl Server's own log | `docker exec fishbowl tail -n 100 /opt/Fishbowl/logs/fbserver.log` |
| Back up all of MySQL | `docker exec -it fishbowl fishbowl-backup` |
| Versions in the image | `docker run --rm fishbowl versions` |

## 11. Backups and your data

### Where everything lives

| Volume | Mounted at | Holds |
|---|---|---|
| `fishbowl-mysql` | `/var/lib/mysql` | MySQL's data directory: your Fishbowl database(s). |
| `fishbowl-app` | `/opt/Fishbowl` | Fishbowl as installed: program files, settings (`server/bin/eve.properties`, which holds the license key and Fishbowl's encrypted database password), Fishbowl's logs and reports, and Fishbowl's own backups (`data/backups/`). |
| `fishbowl-data` | `/var/lib/fishbowl` | The container's state (setup and license-agreement records, installed version, the page's access code), the import folder (`import/`), `fishbowl-backup` files (`backups/`), logs, and the installer's temporary files. |

### Fishbowl's own backups

In Server Administration, right-click your database on the **Database** tab →
**Backup Database**. Fishbowl reports "Successfully ran database backup." and
writes `/opt/Fishbowl/data/backups/<database>_<YYYY-MM-DD-HH-MM>.sql`. Copy it
off the server:

```bash
docker exec fishbowl ls -l /opt/Fishbowl/data/backups/
docker cp fishbowl:/opt/Fishbowl/data/backups/MyCompany_2026-11-15-15-42.sql .
```

These files restore with the **Restore** tab ([section 7](#7-your-company-database-restore-a-sql-backup-or-create-a-new-one)).
Backups scheduled in the Fishbowl Client's Schedule module probably land in the
same folder; that wasn't tested.

### Backup of all of MySQL while running

```bash
docker exec -it fishbowl fishbowl-backup          # asks for the MySQL root password
docker cp fishbowl:/var/lib/fishbowl/backups/fishbowl-backup-<timestamp>.sql.gz .
```

A consistent `mysqldump` of every database (including MySQL's users), gzipped and
readable by root only, kept in the data volume. Restore it with the container
stopped:

```bash
docker stop fishbowl
docker run -it --rm -v fishbowl-mysql:/var/lib/mysql -v fishbowl-app:/opt/Fishbowl \
  -v fishbowl-data:/var/lib/fishbowl fishbowl restore /var/lib/fishbowl/backups/fishbowl-backup-<timestamp>.sql.gz
docker start fishbowl
```

(If the file isn't in the volume already: `docker cp` it into
`fishbowl:/var/lib/fishbowl/backups/` first; that works on a stopped
container.) `restore` asks you to type `restore` and the MySQL root password. It
replaces the databases in the file.

### Whole-installation backup (all three volumes, container stopped)

The way to move the whole server to another machine, and the way back after an
upgrade you want to undo:

```bash
docker stop fishbowl
docker run --rm --entrypoint tar \
  -v fishbowl-mysql:/volumes/mysql:ro -v fishbowl-app:/volumes/app:ro -v fishbowl-data:/volumes/data:ro \
  -v "$PWD":/backup fishbowl \
  -czf /backup/fishbowl-volumes-$(date +%Y%m%d).tar.gz -C /volumes .
docker start fishbowl
```

Restore into empty volumes with the same names (for example on a new machine),
then start the container normally:

```bash
docker run --rm --entrypoint tar \
  -v fishbowl-mysql:/volumes/mysql -v fishbowl-app:/volumes/app -v fishbowl-data:/volumes/data \
  -v "$PWD":/backup fishbowl \
  -xzpf /backup/fishbowl-volumes-YYYYMMDD.tar.gz -C /volumes
```

## 12. Updating to a new Fishbowl version

Each Fishbowl version is a new image, built after the installer on this
repository's release is replaced ([section 14](#14-maintaining-this-repository)).

```bash
docker build -t fishbowl https://github.com/cesiumskater/Docker_Testing.git#main
docker tag fishbowl "fishbowl:$(docker run --rm fishbowl version)"
docker rm -f fishbowl
# then the same docker run command as in section 4
```

With Compose: `docker compose build && docker compose up -d`.

**Nothing is upgraded until you say so.** The new image starts the installed
version as before, and the page offers **Upgrade to Fishbowl X**: read and
accept the new version's license agreement, give the MySQL root password, and
press **Back up and upgrade**. (At a terminal: `docker exec -it fishbowl
fishbowl-upgrade`.) A wrong password is caught before anything is stopped.

Then the container stops Fishbowl Server (Fishbowl Clients are disconnected),
**backs up every database** to
`/var/lib/fishbowl/backups/pre-upgrade-…sql.gz` (plus Fishbowl's settings files),
runs the new installer over `/opt/Fishbowl` and starts Fishbowl Server again. It
keeps your company name, license key, memory settings and data, and never
re-initializes MySQL. On its first start after a new version, Fishbowl Server
**updates your database**; on a large database that can take a while, and the
container waits as long as it takes.

**Before upgrading a production server, make a
[whole-installation backup](#whole-installation-backup-all-three-volumes-container-stopped).**
Downgrades are refused, so it's the way back if the new version doesn't work out.

- **Trial installations are not offered the upgrade.** Fishbowl Server refuses
  to update a trial's database to a new version ("Trial accounts do not have
  access to update the database"; seen going from 26.9.1 to 26.10). The page
  explains and the installed version keeps running. Enter a purchased license
  first (Server Administration → License), restart the container, and the
  upgrade is offered.
- **An upgrade that stopped half-way** (for example the computer lost power
  while the installer ran) leaves Fishbowl Server stopped, and the page offers to
  run the upgrade again. It never starts Fishbowl on half-updated program files.
- **Keeping the old version:** that's what the version tag is for. Start the old
  image (`fishbowl:2026.10`, or `image: fishbowl:2026.10` in `compose.yaml`).
- **Downgrades are refused:** an older image on newer volumes starts nothing,
  changes nothing, and the page says why.
- If Fishbowl Server reports that it can't update the database, the page shows
  Fishbowl's reason ([Troubleshooting](#16-troubleshooting)).

## 13. Security

- **The page is the only way in** to the setup form, the browser windows and the
  buttons, and it needs the access code. The windows' virtual screens listen on
  private sockets inside the container, not on network ports. Wrong codes are
  refused, and after ten in a minute the page stops accepting codes for a minute.
- **Port 6080 is published on 127.0.0.1 only**, so the page works on the
  computer that runs Docker and nowhere else. It's plain HTTP: if you publish it
  on the network (`-p 6080:6080`), the access code, your MySQL root password
  and everything you type in the windows travel unencrypted, and the page says
  so at the top. To use it from another computer, an SSH tunnel keeps it
  private: `ssh -L 6080:localhost:6080 you@docker-host`, then open
  `http://localhost:6080/` there.
- Requests that change something must come from the page itself (a header only
  the page sends, and the browser's Origin); a link or form on another website
  can't press its buttons.
- The page's web server runs as its own unprivileged user (`fbweb`). It never
  runs anything itself: it hands requests to the container's main process, which
  checks every value again. Fishbowl Server, Server Administration and the
  Client run as `fishbowl`, MySQL as `mysql`. Neither is root.
- **Your MySQL root password and license key** go from the form to the container
  through memory (`/dev/shm`, owner-only, deleted as soon as they're read) and
  never appear in the logs. The checks in `tests/` look for both in the logs and
  for the password in the container's data and system folders.
- MySQL listens on 127.0.0.1 inside the container only.

## 14. Maintaining this repository

### Putting the files on GitHub

The repository lives at **https://github.com/cesiumskater/Docker_Testing**
(public, default branch `main`). To replace its files with a new copy from a zip,
in a clone of the repository:

```bash
cd ~/Docker_Testing
git pull
git rm -rq .                                   # remove every tracked file (the .git folder stays)
unzip -q ~/Downloads/Docker_Testing.zip -d /tmp/fishbowl-new
cp -a /tmp/fishbowl-new/Docker_Testing/. .
git add -A
git commit -m "Describe the change"
git push origin main
```

(`git rm` first makes sure files that the new copy no longer has are deleted
too.) Uploading through GitHub's web page also works: **Add file → Upload
files**, drag in everything *inside* the unzipped folder (show hidden files so
`.github`, `.dockerignore` and `.gitignore` come along), commit. GitHub's upload
page takes up to 100 files at a time and 25 MiB per file. It doesn't keep the
executable bit, which doesn't matter here: the Dockerfile sets permissions
itself.

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
Administration. It prints PASS or FAIL per check:

```bash
pip install vncdotool          # drives Server Administration over VNC in the checks
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
minutes. `bash tests/run-checks.sh --help` lists the options.

## 15. Reference

### Ports

| Port | Published | What |
|---|---|---|
| 2456 | `-p 2456:2456` | Fishbowl Server's client port ("Port" in Server Administration; `webPort` in `eve.properties`). |
| 6080 | `-p 127.0.0.1:6080:6080` | The Fishbowl page, including the browser windows (their screens travel over the page's WebSocket). |
| 28192 | not published | "Legacy Port" (`port` in `eve.properties`). |
| 3306, 33060 | never | MySQL, bound to 127.0.0.1 inside the container. |
| 7770 | never | A Java debug port Fishbowl builds into its service launcher, bound to 127.0.0.1 inside the container. |

The browser windows' VNC servers have no ports at all: they listen on Unix
sockets in `/run/fishbowl/`.

### Commands

| Command | |
|---|---|
| `docker exec fishbowl fishbowl-link` | The page's link with its access code (`admin` or `client` for a window's link; `--new-code` to replace the code). |
| `docker exec -it fishbowl fishbowl-setup` | First-time setup at a terminal instead of the page. |
| `docker exec -it fishbowl fishbowl-upgrade` | An upgrade at a terminal instead of the page. |
| `docker exec fishbowl fishbowl-admin` | Opens Server Administration and prints its link. |
| `docker exec -it fishbowl fishbowl-backup` | Back up all of MySQL. |
| `docker run -it --rm <the three -v> fishbowl restore FILE` | Restore a `fishbowl-backup` file (container stopped). |
| `docker run … fishbowl admin` | Like the normal start, but Fishbowl Server stays stopped until you press Start on the page. |
| `docker run --rm fishbowl version` | The image's Fishbowl version, for tagging (`2026.10`). |
| `docker run --rm fishbowl versions` | Fishbowl, MySQL and Java versions in the image. |

### Environment variables

| Variable | Default | |
|---|---|---|
| `TZ` | `UTC` | Time zone for Fishbowl and MySQL, e.g. `America/Denver`. |
| `FISHBOWL_PROMPT_TIMEOUT` | `1800` | Seconds each question of `fishbowl-setup` / `fishbowl-upgrade` waits before giving up. |
| `FISHBOWL_ALLOW_TRIAL_UPGRADE` | `0` | `1` offers the upgrade to a trial installation. Fishbowl Server refuses to update a trial's database, so this only works when the new version doesn't change the database; the test suite uses it. |
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
| `/var/lib/fishbowl/import/` | `.sql` files for the Restore tab (uploaded on the page or copied in); shown as `import` in Server Administration's file chooser. |
| `/var/lib/fishbowl/backups/` | `fishbowl-backup` and pre-upgrade backups. |
| `/var/lib/fishbowl/logs/` | `mysqld.log`, setup and upgrade logs, and `session-admin.log` / `session-client.log` (the browser windows). |
| `/var/lib/fishbowl/state/` | Setup and upgrade state, license-agreement records, the page's access code, settings waiting for a restart. |
| `/etc/my.cnf.d/90-fishbowl.cnf` | The guide's MySQL settings (in the image). |
| `/etc/my.cnf.d/50-fishbowl-server.cnf` | Fishbowl's `server/bin/my.cnf` tuning (`max_connections`, `innodb_buffer_pool_size`, `max_allowed_packet`, …), regenerated whenever MySQL starts, minus the two settings the guide controls. |
| `/opt/fishbowl-installer/` | The bundled installer, its license texts, `installer.env`. |
| `/usr/local/lib/fishbowl/portal.py`, `/usr/local/share/fishbowl/web/` | The Fishbowl page. |

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

### From the install guide's troubleshooting section, in a container

| Guide symptom | In this container |
|---|---|
| MySQL won't start after adding `lower_case_table_names` (9.1) | Shouldn't happen: the setting is in the image before MySQL initializes, the container resets the option files' permissions before each MySQL start (MySQL ignores world-writable ones), and setup stops before installing Fishbowl if MySQL doesn't report `1`. |
| Config file permission denied, SELinux (9.2) | Not inside the container. On a Fedora/RHEL host with SELinux, named volumes work; for bind mounts add `:Z` (for example `-v /srv/fishbowl/mysql:/var/lib/mysql:Z`). |
| Can't reach the MySQL socket as a regular user (9.3) | Use `docker exec -it fishbowl mysql -u root -p`. |
| "No suitable Java Virtual Machine could be found" (9.4) | Not applicable: the image has only Java 21 and points the installer at it. |
| Installer window blank or white (9.5) | Not applicable: the installer runs unattended. |
| Bash error with `!` in the password (9.6) | Not applicable: any character works. |
| MySQL 9.x instead of 8.4 (9.7) | Not possible: the image build fails unless MySQL is 8.4.x. |

### Container-specific

| Symptom | Fix |
|---|---|
| The page doesn't load | The container needs `-p 127.0.0.1:6080:6080` (or Compose's `ports:`), and you must open it on the computer that runs Docker. `docker ps` shows the published ports. Recreate the container with the port; your data is on the volumes. |
| "That access code isn't right" / the link stopped working | Get the current link: `docker exec fishbowl fishbowl-link`. Someone may have replaced the code (`--new-code`). |
| Fishbowl Server didn't start: "Trial accounts do not have access to update the database" | The selected database was made by an older Fishbowl version, and a trial installation can't update it. Enter a purchased license (Server Administration → License) and press Start, or select another database. Nothing was changed in the database. |
| Fishbowl Server didn't start, with another reason from Fishbowl | Open Server Administration from the page to check the license and the database, then press Start. Fishbowl's own log: `docker exec fishbowl tail -n 50 /opt/Fishbowl/logs/fbserver.log`. |
| "Fishbowl Server is still starting after …s" | Normal after an upgrade or with an older database: Fishbowl updates the database before it listens. Let it finish; don't stop the container. |
| Setup failed: "The Fishbowl installer exited with status 1 … Docker is out of disk space" | Free some disk (`docker system df` shows what's using it; `docker builder prune` removes old build cache) or give Docker Desktop a bigger disk, then submit the form again. An unfinished setup starts over cleanly. |
| An upload fails with "Not enough free disk space in Docker" | The same: free disk, then upload again. |
| Server Administration's tab shows a closed window right away | Server Administration was closed (OK or Cancel) or failed to start; `docker exec fishbowl tail /var/lib/fishbowl/logs/session-admin.log`. Press **Open it again**. |
| Changes made in Server Administration didn't take effect | Press **Restart Fishbowl Server** on the page. The log should show `Applied the settings changed in Server Administration`. |
| The Restore tab doesn't list the file | It lists `.sql` files only: unzip a zipped backup first. Uploaded or copied files are in the `import` folder; type the full path in File Name if needed: `/var/lib/fishbowl/import/<file>.sql`. |
| "Another container is already using these volumes" (exit 6) | Stop the other container first; two MySQL servers on one data directory would corrupt it. |
| "This container has no named volumes" | See [First-time setup](#6-first-time-setup). The log prints the commands to fix it. |
| The container keeps restarting with exit code 137 under load | Usually out of memory (`docker inspect -f '{{.State.OOMKilled}}' fishbowl` says `true`): give Docker more memory ([section 2](#2-requirements)). |
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
| Setup form: shows the installer's license text; refuses without acceptance, with a stale text or a weak password; trial install; acceptance recorded with how it was given | Verified *(suite)*, and clicked through in Chromium |
| `fishbowl-setup` at a terminal: declining, end of input or "y" installs nothing; a full setup | Verified *(suite: declines)*; full setup verified once |
| Server Administration in its browser window: create a database, Restore tab with the uploaded file, select a database, the OK dialogs; Fishbowl Server starts by itself | Verified in Chromium through the page, and over VNC *(suite)* |
| The Fishbowl Client in its browser window: opens connected to Fishbowl Server, fills and follows the tab, force close and reopen | Verified in Chromium; opening it *(suite)*. Working in the Client beyond its first-time wizard wasn't tested. |
| Pasting into a Fishbowl window through the clipboard box | Verified in Chromium |
| **Restoring a real Fishbowl backup** (54 MB, made by Fishbowl 2026.7: 320 tables, 48 views, 423,215 rows) through the page and the Restore tab | Verified: the restored database is identical to a direct load of the file, table by table; Fishbowl suggested the name from the file name; the restore added it to the Database tab *(suite with `--reference-sql`)* |
| Selecting that 2026.7 database on a trial installation | Fishbowl Server refused ("Trial accounts do not have access to update the database"); the page showed it within seconds, the container stayed up, the database was unchanged, Server Administration still opened *(suite with `--reference-sql`)* |
| A backup made by the same Fishbowl version: upload, restore into a new database, select it, Restart on the page → runs on it | Verified *(suite)* |
| Settings changed in Server Administration while Fishbowl runs take effect with the page's Restart button | Verified *(suite)* |
| Stop and Start on the page | Verified *(suite)* |
| Fishbowl Server or MySQL killed: started again in place | Verified *(suite)* |
| Killed without a clean shutdown, with a stale MySQL lock file that used to stop MySQL from starting | Reproduced the failure, then verified the fix *(suite)* |
| Docker restarted (the test machine rebooted three times): the container came back to running by itself with `--restart always` | Observed |
| Recreating the container on the same volumes: no questions, same data; a second container on the same volumes refused | Verified *(suite)* |
| After setup: MySQL 8.4.10, `lower_case_table_names = 1`, heap 8192 MB, client 2048 MB, non-root processes, *healthy* | Verified *(suite)* |
| License key and MySQL password absent from `docker logs`; password not stored in plain text anywhere | Verified *(suite)* |
| Upgrade on the page (a stand-in newer version): offered, not without acceptance, wrong password caught early, backup, upgrade, data and memory kept; an interrupted upgrade is finished before Fishbowl starts; downgrade refused; a trial isn't offered the upgrade | Verified *(suite)* |
| `fishbowl-upgrade` at a terminal | Verified once |
| `fishbowl-backup`, the `restore` command | Verified *(suite)* |
| A purchased license: licensed setup, licensed upgrade, Fishbowl updating an older database (such as the 2026.7 backup) at its first start | **Untested** (needs a real license key) |
| The real GitHub repository: the `docker build` URL, the release download, the web upload, the Actions workflow, ghcr.io | Untested from here |
| Docker Desktop (Linux, Mac, Windows), Firefox and Safari, more than one person using the windows at once | Untested |
| `linux/arm64`; rootless Docker; Podman; behavior under production load (memory figures are estimates) | Untested |
