# Fishbowl Advanced in Docker (Linux)

One container that runs **Fishbowl Advanced Server** on Linux with everything it
needs: **Java 21**, **MySQL 8.4**, and **Fishbowl's own Linux installer**.

Fishbowl isn't baked into the image. It installs the **first time the container
starts**, after *you* read and accept Fishbowl's license agreement, enter your
license key (or start the 14 Day Trial) and choose a MySQL root password.
Everything else is automatic.

Repository: **https://github.com/cesiumskater/Docker_Testing**

## Quick start

```bash
# 1. Build the image straight from GitHub (this also downloads the Fishbowl installer)
docker build -t fishbowl https://github.com/cesiumskater/Docker_Testing.git#main
docker tag fishbowl "fishbowl:$(docker run --rm fishbowl version)"

# 2. First start: license agreement, license key or "trial", MySQL root password
docker run -it --rm --name fishbowl --stop-timeout 180 \
  -p 2456:2456 -p 127.0.0.1:6080:6080 \
  -e TZ=America/Denver \
  -v fishbowl-mysql:/var/lib/mysql \
  -v fishbowl-app:/opt/Fishbowl \
  -v fishbowl-data:/var/lib/fishbowl \
  fishbowl

# 3. The terminal then shows a link and a password: open Fishbowl Server
#    Administration in your browser and create your company database
#    (or restore an existing .sql, see "Restore an existing .sql file").

# 4. Day to day, with Docker Compose (stop the first-run container first)
curl -fsSLO https://raw.githubusercontent.com/cesiumskater/Docker_Testing/main/compose.yaml
docker compose up -d
```

Fishbowl Clients then connect to this computer's name or IP address, **port 2456**.

## Contents

1. [What this is, and the support position](#1-what-this-is-and-the-support-position)
2. [Requirements](#2-requirements)
3. [Get the image](#3-get-the-image)
4. [First start](#4-first-start)
5. [Your company database: create a new one](#5-your-company-database-create-a-new-one)
6. [Restore an existing .sql file](#6-restore-an-existing-sql-file)
7. [Day-to-day use](#7-day-to-day-use)
8. [Server Administration: opening it and changing the server setup](#8-server-administration-opening-it-and-changing-the-server-setup)
9. [Backups and your data](#9-backups-and-your-data)
10. [Updating to a new Fishbowl version](#10-updating-to-a-new-fishbowl-version)
11. [Maintaining this repository](#11-maintaining-this-repository)
12. [Reference](#12-reference)
13. [Troubleshooting](#13-troubleshooting)
14. [Versions and verification](#14-versions-and-verification)

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
| Fishbowl itself | Fishbowl's installer, run unattended | **first start, after you accept the license agreement** |
| Company database | Fishbowl Server Administration, in your browser | right after first setup |

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
| Docker | Docker Engine with BuildKit, and the Docker Compose plugin (`docker compose`) if you use Compose. Tested with Docker Engine 29.9.3 and Compose v5.7.0. |
| CPU | x86-64 (`linux/amd64`) only. ARM64 (including Apple Silicon running it natively) is untested. |
| Internet | To build: access to GitHub, Fedora's package mirrors and Adoptium's repository. |
| Disk | About **3.4 GB** for the image, about **1.2 GB** for a fresh install's volumes plus your database and backups, and about **1.5 GB** of temporary space during install and upgrades. Plan on **10 GB free**. |
| RAM | Plan on **12 GB available to Docker** (16 GB machine). Details below. |
| Ports | **2456** reachable by Fishbowl Clients. **6080** on 127.0.0.1 for Server Administration in your browser. |

**Why 12 GB of RAM.** This is an estimate from the configured limits, not a
measurement under load. Fishbowl Server is set to an **8192 MB** Java heap (as
the install guide requires), and Java uses memory beyond the heap too (roughly
another 0.5–1 GB, an estimate). Fishbowl's own MySQL settings use a **2 GB**
InnoDB buffer pool plus per-connection buffers, so MySQL needs roughly
2.5–3 GB. That adds up to about 11–12 GB when both are fully used. At idle with
a new database the container used about 1.3–1.6 GB in testing, and it ran on a
test machine with 7.8 GB of RAM: the heap only grows as needed. With less memory
than the estimate, the container can be killed when Fishbowl gets busy.

**Docker Desktop runs containers in a VM with its own memory limit**, which
defaults to 50% of your computer's memory. Raise it to at least 12 GB with
**Memory limit** under **Settings → Resources → Advanced**. On Windows with the
WSL 2 backend that setting isn't there; the memory is set for WSL itself
(Microsoft's WSL configuration, `.wslconfig`). Docker Desktop wasn't tested here.

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

`compose.yaml` builds the same image from GitHub the first time it's needed:

```bash
curl -fsSLO https://raw.githubusercontent.com/cesiumskater/Docker_Testing/main/compose.yaml
docker compose build
```

### Or pull a ready-made image (only once it's published)

If this repository's GitHub Actions workflow has published the image (see
[Maintaining this repository](#11-maintaining-this-repository)), you can skip
the build:

```bash
docker pull ghcr.io/cesiumskater/docker_testing:latest
docker tag ghcr.io/cesiumskater/docker_testing:latest fishbowl
```

## 4. First start

Setup shows you Fishbowl's license agreement and asks a few questions, so it
needs a terminal. Start it with **`-it`**:

```bash
docker run -it --rm --name fishbowl --stop-timeout 180 \
  -p 2456:2456 -p 127.0.0.1:6080:6080 \
  -e TZ=America/Denver \
  -v fishbowl-mysql:/var/lib/mysql \
  -v fishbowl-app:/opt/Fishbowl \
  -v fishbowl-data:/var/lib/fishbowl \
  fishbowl
```

Set `TZ` to your time zone (Fishbowl and MySQL use it for dates); it defaults to UTC.
With Compose, the same thing is `docker compose run --rm --service-ports fishbowl`.

### What you'll see

Setup first lists what it will ask. Then:

**1. Fishbowl's license agreement.**

```
Press Enter to open the license agreement...
```

It opens in a pager (Space or PgDn scrolls, `q` closes it). It's the same text
Fishbowl's installer shows. Then:

```
Do you accept the Fishbowl license agreement? Type "yes" to accept:
```

Only a typed `yes` counts. Anything else, or no answer, installs nothing and
exits with an explanation. Accepting is your own act; nothing in this image
accepts it for you.

**2. License key or trial.**

```
Paste your Fishbowl License Key. It won't be shown while you type.
No key yet? Type: trial    (starts the 14 Day Fishbowl Trial)
License key (or trial):
```

With a key, setup shows only its last four characters and asks you to confirm:
`The key you entered ends in ...XXXX. Is that right? [y/N]`

**3. Company name** (licensed installs only; Fishbowl's installer registers a
trial under the name "Trial").

```
Company name:
```

**4. MySQL root password**, typed twice and not shown:

```
MySQL root password:
Type it again:
```

It must have at least 8 characters, upper- and lower-case letters, a digit and a
special character (MySQL's MEDIUM policy). Any special character works,
including `!`, quotes and `$`. You'll need it again to create or restore a
database and to upgrade, so store it safely: **it isn't saved anywhere in plain
text**, and this image has no command to reset it.

**Set automatically:** "Server with Client" install in `/opt/Fishbowl`, MySQL on
`localhost:3306`, server memory **8192 MB**, client memory **2048 MB**, the
install guide's MySQL settings (`lower_case_table_names=1`,
`sql-mode=STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION`), Fishbowl's own MySQL
tuning from its `server/bin/my.cnf`, and Fishbowl's Auto Updates set to
*Never* (new versions come from new images, see [Updating](#10-updating-to-a-new-fishbowl-version)).

After the questions, setup runs on its own: it initializes MySQL, sets your
password, checks that MySQL is 8.4.x with `lower_case_table_names = 1`, applies
the guide's security cleanup, runs Fishbowl's installer, and verifies the memory
settings. **In testing this took about 20 seconds.** Then it opens Server
Administration for the database step (next section).

## 5. Your company database: create a new one

Fishbowl Server can't start without a company database. Right after first setup
the container opens **Fishbowl Server Administration** (a desktop program) on a
private virtual screen and shows it in your browser:

```
  1. In a browser on this computer, open:
       http://localhost:6080/vnc.html?autoconnect=1&resize=scale
  2. Session password:  XXXXXXXX
```

Open the link, click **Connect**, and type the session password. Then:

1. **Database** tab → the green **+** button on the right.
2. **Database:** a name for your company database (letters, numbers and
   underscores). **Host** `localhost`, **Port** `3306`, **Username** `root`.
3. **Password:** clear the long pre-filled value first, then type **your MySQL
   root password**. Click **Connect**.
4. Fishbowl asks for your **country** and **costing method** (Average, Standard,
   FIFO or LIFO costing). Fishbowl warns that *this setting cannot be changed once
   the wizard is complete.* Click **OK** and wait while Fishbowl creates the
   database.
5. Click **OK** to save, then **OK** on "Database Connection has been changed to: …".

Server Administration closes and **Fishbowl Server starts by itself**. In
testing this step took under two minutes, most of it Fishbowl creating the
database. The first time someone logs in with the Fishbowl Client, Fishbowl's
first-time wizard opens (Company, Admin Password, Next Steps).

**Moving an existing company instead?** In the same browser session, use the
**Restore** tab to load your `.sql` backup into a new database, then add that
database on the **Database** tab and click OK. The steps are in the next section.

### Leaving it running

Your terminal now shows the server's log. Either:

- **Detach** and leave it running: press **Ctrl-P, then Ctrl-Q**.
- **Stop** it: press **Ctrl-C** (shuts down Fishbowl, then MySQL, cleanly). Closing
  the terminal window also stops it cleanly.

For day-to-day use, stop the first-run container (`docker stop fishbowl` if you
detached) and switch to Docker Compose ([section 7](#7-day-to-day-use)).

## 6. Restore an existing .sql file

Fishbowl's own backups are `.sql` files (named like `MyCompany_2026-11-15-15-42.sql`).
You load one with the **Restore** tab in Fishbowl Server Administration. The
file has to be inside the container, so first copy it into the container's
**import folder**.

**1. Copy the file in** (the container must exist; running or stopped both work):

```bash
docker cp ./MyCompany_2026-11-15-15-42.sql fishbowl:/var/lib/fishbowl/import/
```

The import folder is on the `fishbowl-data` volume. Each time Server
Administration opens, the container makes the files there readable by it.

**2. Open Server Administration** (Fishbowl Server keeps running meanwhile):

```bash
docker exec -it fishbowl fishbowl-admin
```

Open the link it prints and type the session password.

**3. Restore tab.** It may already show Fishbowl's latest backup of the current
database in **Restore File**. You'll replace that next.

**4. Choose your file.** Click the magnifier next to **Restore File**. In
**File Name**, type the full path, for example
`/var/lib/fishbowl/import/MyCompany_2026-11-15-15-42.sql`, and click **Open**.
(If the file chooser opens in your home folder, you can also double-click the
`import` folder there.) The chooser lists `*.sql` files.

**5. Database.** Fishbowl fills this in from the file name (in testing, the part
before the first underscore). **Check it and type the name you want:**

- a **new name** (letters, numbers and underscores) restores the backup next to
  your current database, which is the safe choice;
- an **existing name** replaces that database. Fishbowl warns that all data not
  in the backup will be lost.

**6. Connection.** Host `localhost`, Port `3306`, Username `root`. In
**Password**, clear the pre-filled value and type **your MySQL root password**.

**7. Click Restore.** Fishbowl asks you to confirm ("Restoring will overwrite all
current data in database …"); click **Yes**. Wait for **"Database has been
restored."** and click **OK**. Large databases take a while.

**8. Make Fishbowl use it** (skip this if you restored over the database Fishbowl
already uses):

1. **Database** tab → green **+**.
2. **Database:** the name you restored into. **Password:** clear it, type your
   MySQL root password. Click **Connect**. An existing Fishbowl database is
   added to the list without the setup wizard.
3. Click the new database in the list, then **OK**.
4. Click **OK** on "Database Connection has been changed to: …" and on "This
   setting will not take place until the server is exited and restarted."
5. Restart: `docker restart fishbowl`

The log then shows `Applied the settings changed in Server Administration
(company database: …)` and `Fishbowl Server is running`. Check with
`docker logs fishbowl`.

**Notes**

- **Replacing the database Fishbowl Server is using right now:** do it with the
  server stopped. `docker compose stop`, then
  `docker compose run --rm --service-ports fishbowl admin`, restore with the
  current database's name, click **Cancel** to close, and `docker compose up -d`.
- **A backup from an older Fishbowl version** is updated by Fishbowl Server the
  next time it starts. A trial installation can't do that: Fishbowl Server
  refused to update a database for a trial in testing ("Trial accounts do not
  have access to update the database").
- Only restore backups from the **same or an older** Fishbowl version.
- `fishbowl-backup` files (`.sql.gz`, all of MySQL) aren't for the Restore tab;
  use the `restore` command for those ([section 9](#9-backups-and-your-data)).
- Copying the file into the container doesn't change it, and the import folder
  isn't cleaned up for you. Delete files you no longer need:
  `docker exec fishbowl rm /var/lib/fishbowl/import/MyCompany_2026-11-15-15-42.sql`

## 7. Day-to-day use

`compose.yaml` uses the same three volumes as the first-run command, so it starts
your existing installation with **no questions**:

```bash
curl -fsSLO https://raw.githubusercontent.com/cesiumskater/Docker_Testing/main/compose.yaml
# edit TZ in compose.yaml, then:
docker compose up -d
```

| Task | Command |
|---|---|
| Start | `docker compose up -d` |
| Stop | `docker compose stop` (gives Fishbowl and MySQL up to 3 minutes to shut down) |
| Restart | `docker restart fishbowl` |
| Status | `docker ps` (shows *healthy* once Fishbowl Server accepts connections) |
| Log | `docker logs -f fishbowl` |
| Fishbowl Server's own log | `docker exec fishbowl tail -n 100 /opt/Fishbowl/logs/fbserver.log` |
| Server Administration | `docker exec -it fishbowl fishbowl-admin` |
| Versions in the image | `docker run --rm fishbowl versions` |

The container restarts by itself after a reboot (`restart: unless-stopped`), as
long as Docker starts at boot.

### Connecting Fishbowl Clients

Install the Fishbowl Client on each user's computer (from Fishbowl). Point it at
the **Docker host's name or IP address, port 2456**. The client that comes with
26.10 defaults to the server's web port (`ServerPort=2456`,
`UseWebConnection=true` in its `client.properties`), and in testing a client
connected with only port 2456 published. Allow TCP 2456 through the Docker
host's firewall.

## 8. Server Administration: opening it and changing the server setup

Fishbowl Server Administration is where Fishbowl's server settings live: the
company database, ports, memory, Auto Updates, the license, and restoring
backups. It's a desktop program, so the container runs it on a private virtual
screen and shows it in your browser, one session at a time.

### Opening it

**While Fishbowl is running** (the usual way):

```bash
docker exec -it fishbowl fishbowl-admin
```

It prints a link and a one-time **session password**:

```
  1. In a browser on this computer, open:
       http://localhost:6080/vnc.html?autoconnect=1&resize=scale
  2. Session password:  XXXXXXXX
```

Open the link, click **Connect**, type the password. The page works only on this
computer, and only if the container was started with `-p 127.0.0.1:6080:6080`
(the commands here and `compose.yaml` do this).

**When Fishbowl Server can't start, or must be stopped** (for example to replace
the database it uses):

```bash
docker compose stop
docker compose run --rm --service-ports fishbowl admin
```

This runs MySQL and Server Administration only. Afterwards, `docker compose up -d`.
(Without Compose: `docker run -it --rm -p 127.0.0.1:6080:6080` with the same
three `-v` options and `fishbowl admin` at the end.)

### Closing it

- **OK** saves your changes and ends the session.
- **Cancel** ends the session without saving.
- **Ctrl-C** in the terminal also ends it without saving.

If you closed the terminal without ending the session, the session keeps
running. The next `fishbowl-admin` notices and asks whether to end it:
`End it and start a new session? [y/N]`.

### Changing settings while Fishbowl Server is running

When you click OK, Fishbowl says *"This setting will not take place until the
server is exited and restarted."* So restart afterwards:

```bash
docker restart fishbowl
```

That disconnects Fishbowl Clients for about 20 seconds. Fishbowl Server
rewrites its settings file from memory when it stops, which would undo your
changes; the container keeps a copy of what you changed and puts it back before
Fishbowl Server starts again. The log confirms it:
`Applied the settings changed in Server Administration`.

### The tabs

**Database:** your company databases. **+** adds one (a new name creates a
database through Fishbowl's wizard; an existing Fishbowl database is just
added), and the database selected when you click **OK** is the one Fishbowl
Server uses. The red bin is Fishbowl's delete button (not tried here). Right-click a database for
**Show Version, Backup Database, Rebuild Database, Database Maintenance, Drop
Database, Optimize Database, Convert Character Sets, Run Support Queries** and
**Send Copy to Fishbowl**. Of those, only Backup Database was tried here
([section 9](#9-backups-and-your-data)).

**Server:**

| Setting | Notes for this container |
|---|---|
| Port (2456) | The port Fishbowl Clients use. If you change it, publish the new port instead (`-p NEW:NEW`, or the `ports:` line in `compose.yaml`) and recreate the container. |
| Secure Connection, Certificate, Certificate Password | Fishbowl uses a `.jks` certificate file for this. The file must be inside the container: copy it to the import folder like a `.sql` file. Not tested here. |
| Legacy Port (28192) | Not published. Publish it (`-p 28192:28192`) only if something you use still connects to it. |
| Inactivity Time | Fishbowl's inactivity timeout, in minutes. |
| Broadcast Server Location, Users can only be logged in once | Fishbowl's own options. |
| Server memory | Set to 8192 MB at install. A new value takes effect after `docker restart fishbowl`; the log shows `Server memory changed in Server Administration: now …` and the heap in `Fishbowl Server is running (heap …)`. Keep Docker's memory limit above it (section 2). |
| Auto Updates | Set to *Never notify or update automatically* at install. Leave it: Fishbowl's download-and-apply options would update Fishbowl inside the container, skipping the license step and backup that new images do. |
| MySQL Server Location | `/usr/bin`. Leave it: Backup Database and Restore use MySQL's tools from there. |
| Enable read-only database user, Read-only user password | Fishbowl's read-only MySQL user. Fishbowl requires at least 8 characters with upper- and lower-case letters, a digit and a special character. |

**License:** the registered name and license key. This is where a purchased
license replaces the trial (not tested here: no real key was used). Restart
afterwards.

**Restore:** loads a `.sql` backup into a database. See
[Restore an existing .sql file](#6-restore-an-existing-sql-file).

## 9. Backups and your data

### Where everything lives

| Volume | Mounted at | Holds |
|---|---|---|
| `fishbowl-mysql` | `/var/lib/mysql` | MySQL's data directory: your Fishbowl database(s). |
| `fishbowl-app` | `/opt/Fishbowl` | Fishbowl as installed at first start: program files, settings (`server/bin/eve.properties`, which holds the license key and Fishbowl's encrypted database password), Fishbowl's logs and reports, and Fishbowl's own backups (`data/backups/`). |
| `fishbowl-data` | `/var/lib/fishbowl` | The container's state (setup and EULA records, installed version), the import folder (`import/`), `fishbowl-backup` files (`backups/`), logs, and the installer's temporary files. |

All three are required; the container refuses to start without them, because
anything outside a volume disappears when the container is removed.

### Fishbowl's own backups

In Server Administration, right-click your database on the **Database** tab →
**Backup Database**. Fishbowl reports "Successfully ran database backup." and
writes `/opt/Fishbowl/data/backups/<database>_<YYYY-MM-DD-HH-MM>.sql`. Copy it
off the server:

```bash
docker exec fishbowl ls -l /opt/Fishbowl/data/backups/
docker cp fishbowl:/opt/Fishbowl/data/backups/MyCompany_2026-11-15-15-42.sql .
```

These files restore with the **Restore** tab ([section 6](#6-restore-an-existing-sql-file)).
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
docker compose stop
docker cp ./fishbowl-backup-<timestamp>.sql.gz fishbowl:/var/lib/fishbowl/backups/   # if it isn't there already
docker compose run --rm fishbowl restore /var/lib/fishbowl/backups/fishbowl-backup-<timestamp>.sql.gz
docker compose up -d
```

`restore` asks you to type `restore` and the MySQL root password. It replaces
the databases in the file.

### Whole-installation backup (all three volumes, container stopped)

The way to move the whole server to another machine, and the way back after an
upgrade you want to undo:

```bash
docker compose stop
docker run --rm --entrypoint tar \
  -v fishbowl-mysql:/volumes/mysql:ro -v fishbowl-app:/volumes/app:ro -v fishbowl-data:/volumes/data:ro \
  -v "$PWD":/backup fishbowl \
  -czf /backup/fishbowl-volumes-$(date +%Y%m%d).tar.gz -C /volumes .
docker compose up -d
```

Restore into empty volumes with the same names (for example on a new machine),
then start normally:

```bash
docker run --rm --entrypoint tar \
  -v fishbowl-mysql:/volumes/mysql -v fishbowl-app:/volumes/app -v fishbowl-data:/volumes/data \
  -v "$PWD":/backup fishbowl \
  -xzpf /backup/fishbowl-volumes-YYYYMMDD.tar.gz -C /volumes
docker compose up -d
```

## 10. Updating to a new Fishbowl version

Each Fishbowl version is a new image, built after the installer on this
repository's release is replaced (see [section 11](#11-maintaining-this-repository)).
The container notices when the image is newer than what's on your volumes and
upgrades the way a normal Fishbowl update works, **after you accept the license
agreement for the new version**.

**Before upgrading a production server, make a
[whole-installation backup](#whole-installation-backup-all-three-volumes-container-stopped).**
Downgrades are refused, so it's the way back if the new version doesn't work out.

```bash
docker compose build          # rebuilds from GitHub with the new installer
docker tag fishbowl "fishbowl:$(docker run --rm fishbowl version)"
docker compose stop
docker compose run --rm --service-ports fishbowl    # accept the new agreement, enter the MySQL password
# wait for "Fishbowl Server is running", then Ctrl-C
docker compose up -d
```

(Without Compose: build with the two commands from [section 3](#3-get-the-image),
then start with the first-run `docker run -it` command.)

The upgrade shows the new agreement and asks for the MySQL root password, then
**backs up every database** to `/var/lib/fishbowl/backups/pre-upgrade-…sql.gz`
(plus Fishbowl's settings files) and runs the new installer over
`/opt/Fishbowl`. It keeps your company name, license key, memory settings and
data, and never re-initializes MySQL. Then Fishbowl Server starts, and on its
first start after a new version it **updates your database**. On a large
database that can take a while: wait for `Fishbowl Server is running` before
stopping anything. The container waits as long as it takes and logs a note
every 5 minutes.

- **Trial installations are not upgraded.** Fishbowl Server refuses to update a
  trial's database to a new version ("Trial accounts do not have access to update
  the database"; seen going from 26.9.1 to 26.10), which would leave the server
  unable to start. So for a trial the new image exits without changing anything
  and explains the options: keep running the old version, enter a purchased
  license first, or start a new trial on new volumes.
- Started without a terminal (for example plain `docker compose up -d`), the new
  image changes nothing: it exits and prints the command above. With
  `restart: unless-stopped` Docker keeps retrying, and printing the command,
  until you run it or go back to the old version.
- **Keeping the old version:** that's what the version tag is for. Put the old
  one in `compose.yaml` (`image: fishbowl:2026.10`) and start it.
- Declining the new agreement changes nothing.
- **Downgrades are refused**: an older image on newer volumes exits with an error.
- If Fishbowl Server reports that it can't update the database, the container
  shows Fishbowl's reason and stops ([Troubleshooting](#13-troubleshooting)).

## 11. Maintaining this repository

### Putting the files on GitHub

1. Create the repository **cesiumskater/Docker_Testing** on GitHub, **public**,
   default branch **main**. Leave it empty (no README, .gitignore or license),
   or upload over the existing files.
2. Unzip `Docker_Testing.zip`. In your file manager, **show hidden files**
   (Ctrl+H in most Linux file managers, Cmd+Shift+. on a Mac) so `.github`,
   `.dockerignore` and `.gitignore` are visible.
3. On the repository page: **Add file → Upload files** (on an empty repository,
   the "uploading an existing file" link). Select **everything inside** the
   unzipped `Docker_Testing` folder, not the folder itself, and **drag it onto
   the page**. Dragging keeps the folder structure. Commit to `main`.
4. Check the repository's top level shows `.github`, `build`, `ci`, `rootfs`,
   `tests`, `.dockerignore`, `.gitignore`, `Dockerfile`, `README.md` and
   `compose.yaml`. Without `.github` the image still builds, but the publishing
   workflow below won't run.

GitHub's upload page takes up to 100 files at a time and 25 MiB per file; this
repository is 26 small files.

### The installer release (one time, then once per Fishbowl version)

The installer lives on **one permanently named release**: tag
**`fishbowl-installer`**, holding **exactly one** file named
`Fishbowl-<version>.sh`, exactly as Fishbowl publishes it (for example
`Fishbowl-2026.10.sh`).

- **First time:** **Releases → Draft a new release** (or **Create a new
  release**). Choose a tag: type `fishbowl-installer` and create it on publish.
  Give it a title, attach the installer, and click **Publish release** (a draft
  isn't visible to the build).
- **New Fishbowl version:** edit that release, delete the old installer, upload
  the new one, and save. That's all: no file in the repository changes. People
  rebuild (`docker compose build`) to get it.

The build reads the version from the file name and fails with a clear message
if the release has **no** `Fishbowl-*.sh` file or **more than one**, or if the
download doesn't match the size and SHA-256 GitHub reports.

**File size.** GitHub doesn't limit a release's total size or download
bandwidth. Its *About releases* page says each file must be under 2 GiB; its
*About large files* page ties the limit to the plan's Git LFS maximum, which is
at least 2 GB on every plan. Either way, Fishbowl's installer (about 721 MiB)
fits. GitHub's 25 MiB limit for browser uploads is about adding files to the
repository itself, not release assets.

### Optional: ready-made images on ghcr.io

The workflow in `.github/workflows/build.yml` (**Build and publish the image**)
builds the image on GitHub and publishes `ghcr.io/cesiumskater/docker_testing:<version>`
and `:latest`:

- on its schedule, **every 6 hours** (it builds only when the installer changed);
- when you press **Actions → Build and publish the image → Run workflow** (tick
  *force* to rebuild an unchanged installer);
- on every push to `main` that changes the image's files.

Whether replacing a release file also starts it right away couldn't be tested
before this repository existed; each run logs what started it (*Triggered by: …*).

After the first run, **make the package public**: a new ghcr.io package starts
**private** and doesn't inherit the repository's visibility. On the package's
page: **Package settings → Danger Zone → Change visibility → Public**, then
confirm by typing the package name. GitHub warns that a public package can't be
made private again. GitHub also turns off scheduled workflows in a public
repository after **60 days** without repository activity; re-enable it on the
Actions tab if that happens.

## 12. Reference

### Ports

| Port | Published | What |
|---|---|---|
| 2456 | `-p 2456:2456` | Fishbowl Server's client port ("Port" in Server Administration; `webPort` in `eve.properties`). |
| 28192 | not published | "Legacy Port" (`port` in `eve.properties`). |
| 6080 | `-p 127.0.0.1:6080:6080` | Server Administration in your browser (noVNC), only during a session. |
| 5900 | optional `-p 127.0.0.1:5900:5900` | The same session for a VNC client instead of the browser. |
| 3306, 33060 | never | MySQL, bound to 127.0.0.1 inside the container. |
| 7770 | never | A Java debug port Fishbowl builds into its service launcher, bound to 127.0.0.1 inside the container. |

### Commands

| Command | |
|---|---|
| `docker exec -it fishbowl fishbowl-admin` | Server Administration in your browser (Fishbowl running). |
| `docker compose run --rm --service-ports fishbowl admin` | Server Administration with MySQL only (container stopped). |
| `docker exec -it fishbowl fishbowl-backup` | Back up all of MySQL. |
| `docker compose run --rm fishbowl restore FILE` | Restore a `fishbowl-backup` file (container stopped). |
| `docker cp FILE.sql fishbowl:/var/lib/fishbowl/import/` | Make a `.sql` available to the Restore tab. |
| `docker run --rm fishbowl version` | The image's Fishbowl version, for tagging (`2026.10`). |
| `docker run --rm fishbowl versions` | Fishbowl, MySQL and Java versions in the image. |

### Environment variables

| Variable | Default | |
|---|---|---|
| `TZ` | `UTC` | Time zone for Fishbowl and MySQL, e.g. `America/Denver`. |
| `FISHBOWL_PROMPT_TIMEOUT` | `1800` | Seconds each setup or upgrade question waits before giving up. |
| `FISHBOWL_ALLOW_NO_VOLUMES` | `0` | `1` skips the volume check (throwaway tests only). |
| `FISHBOWL_ALLOW_TRIAL_UPGRADE` | `0` | `1` lets a trial installation run an upgrade. Fishbowl Server refuses to update a trial's database, so this only works when the new version doesn't change the database; the test suite uses it. |

### Exit codes

`1` declined or failed · `2` volumes missing · `3` needs an interactive terminal
(setup or upgrade) · `4` downgrade refused · `5` volumes hold data this
container didn't set up · `6` another container is using these volumes ·
`7` trial installation not upgraded · `143` stopped during setup or upgrade.

### File locations

| Path | |
|---|---|
| `/opt/Fishbowl/server/bin/eve.properties` | Fishbowl Server settings (license key, database connection, ports, Auto Updates). Owner-only. |
| `/opt/Fishbowl/logs/fbserver.log` | Fishbowl Server's log. |
| `/opt/Fishbowl/data/backups/` | Backups made with Backup Database in Server Administration. |
| `/opt/Fishbowl/server/bin/*.vmoptions` | Server memory (`-Xmx…`); client memory is in `client/bin/`. |
| `/var/lib/fishbowl/import/` | Drop folder for `.sql` files to restore (shown as `import` in Server Administration's file chooser). |
| `/var/lib/fishbowl/backups/` | `fishbowl-backup` and pre-upgrade backups. |
| `/var/lib/fishbowl/logs/` | `mysqld.log`, setup and upgrade logs, `admin-session.log`. |
| `/var/lib/fishbowl/state/` | Setup and upgrade state, EULA acceptance records, settings waiting for a restart. |
| `/etc/my.cnf.d/90-fishbowl.cnf` | The guide's MySQL settings (in the image). |
| `/etc/my.cnf.d/50-fishbowl-server.cnf` | Fishbowl's `server/bin/my.cnf` tuning (`max_connections`, `innodb_buffer_pool_size`, `max_allowed_packet`, …), regenerated whenever MySQL starts, minus the two settings the guide controls. |
| `/opt/fishbowl-installer/` | The bundled installer, its license texts, `installer.env`. |

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

## 13. Troubleshooting

### From the install guide's troubleshooting section, in a container

| Guide symptom | In this container |
|---|---|
| MySQL won't start after adding `lower_case_table_names` (9.1) | Shouldn't happen: the setting is in the image before MySQL initializes, the container resets the option files' permissions before each MySQL start (MySQL ignores world-writable ones), and setup stops before installing Fishbowl if MySQL doesn't report `1` (the next start wipes the unfinished data directory and starts over). |
| Config file permission denied, SELinux (9.2) | Not inside the container. On a Fedora/RHEL host with SELinux, named volumes work; for bind mounts add `:Z` (for example `-v /srv/fishbowl/mysql:/var/lib/mysql:Z`). |
| Can't reach the MySQL socket as a regular user (9.3) | Use `docker exec -it fishbowl mysql -u root -p`. |
| "No suitable Java Virtual Machine could be found" (9.4) | Not applicable: the image has only Java 21 and points the installer at it. |
| Installer window blank or white (9.5) | Not applicable: the installer runs unattended. |
| Bash error with `!` in the password (9.6) | Not applicable: any character works. |
| MySQL 9.x instead of 8.4 (9.7) | Not possible: the image build fails unless MySQL is 8.4.x. |

### Container-specific

| Symptom | Fix |
|---|---|
| Exits right away: "Fishbowl is not installed in these volumes yet … No terminal is attached" (exit 3) | Run the first setup with `-it` (the message prints the exact command). |
| "The Fishbowl installer exited with status 1", and the log it names says "Not enough disk space for target directory: /opt/Fishbowl" | Docker is out of disk space (seen in testing). Free some (`docker system df` shows what's using it; `docker builder prune` removes old build cache) or give Docker Desktop a bigger disk, then start the container again: an unfinished setup or upgrade starts over cleanly. |
| Exits: "This image has Fishbowl X; your volumes have Y …" (exit 3) | An upgrade needs you at a terminal: run the printed command, or go back to the old version's image. |
| Started with `-t` but not `-i`: setup waits about 5 minutes, then exits (exit 3) | Use `-it`. |
| "These paths are not on volumes" (exit 2) | Add the three `-v` options. |
| "Another container is already using these volumes" (exit 6) | Stop the other container (for example the first-run one) first. |
| "Downgrades are refused" (exit 4) | Use an image at least as new as the installed version. |
| "Fishbowl X is a trial installation; not upgrading it to Y" (exit 7) | Fishbowl doesn't update a trial's database to a new version. Keep the old image, enter a purchased license (Server Administration → License) and then upgrade, or start a new trial on new volumes. Nothing was changed. |
| "Fishbowl Server could not update your database to Fishbowl X", then "Fishbowl says: …" (exit 1) | Fishbowl refused to update the database at its first start after an upgrade or a restore of an older backup; the container shows Fishbowl's reason and stops. Seen with a trial; in that test the database was left unchanged. Check the license with `docker compose run --rm --service-ports fishbowl admin` (License tab) or with Fishbowl. The way back to the old version is a whole-installation backup from before the upgrade. |
| "Fishbowl Server is still starting after …s" | Normal after an upgrade on a large database: Fishbowl updates the database before it listens. Let it finish; don't stop the container. |
| Changes made in Server Administration didn't take effect | Restart: `docker restart fishbowl`. The log should show `Applied the settings changed in Server Administration`. |
| "Another Server Administration session is still open" | An earlier session's terminal was closed without ending it. Answer `y` to end it, or use it in your browser. |
| The browser page doesn't load | The container needs `-p 127.0.0.1:6080:6080`, and a Server Administration session must be open. Recreate the container with the port (data is on the volumes). |
| The session password is rejected | Each session makes a new password; the old one stops working when its session ends. |
| The Restore tab can't find or read the file | Copy it to `/var/lib/fishbowl/import/`, then open a **new** Server Administration session (that's when the container makes the folder readable), and type the full path in File Name. |
| `docker ps` shows *unhealthy*, "No Fishbowl database yet" | Create or restore a database: `docker exec -it fishbowl fishbowl-admin`. |
| Closing the terminal stopped the container | That's `docker run -it`: detach with Ctrl-P Ctrl-Q instead, or run day to day with `docker compose up -d`. |
| `docker stop` takes long or MySQL recovers at the next start | Give it time to shut down: `--stop-timeout 180` (Compose: `stop_grace_period`, already set). |
| The container restarts with exit code 137 under load | Usually out of memory (`docker inspect -f '{{.State.OOMKilled}}' fishbowl` says `true`): give Docker more memory (section 2). |
| Warning: "Fishbowl … reports version X, but this container last installed Y" | Fishbowl updated itself. Set Auto Updates to *Never* in Server Administration → Server and update through new images. |
| "Fishbowl Server exited during startup" | Read Fishbowl's log: `docker exec fishbowl tail -n 50 /opt/Fishbowl/logs/fbserver.log`. |
| The log shows `ERROR … Stream is invalid` with `java.net.ConnectException: Connection refused` at each start | Fishbowl Server makes an outgoing web request when it starts. In testing the container had no direct internet access, this error appeared every time, and the server worked normally. |
| `OpenJDK … warning: Options -Xverify:none and -noverify were deprecated` | Comes from the Java options in Fishbowl's own launcher. Fishbowl Server ran normally with it in testing. |

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

## 14. Versions and verification

| | |
|---|---|
| Fishbowl Advanced | **26.10** (`Fishbowl-2026.10.sh`, 756,097,431 bytes, SHA-256 `25a0a0d3109c429264afe0af4f69ed49e89fd84fd1cad5c19030b59cfe40d2b5`) |
| MySQL | **8.4.10** (Fedora 44 `mysql-server-8.4.10-1.fc44`) |
| Java | **Eclipse Temurin 21.0.13+9** (`temurin-21-jdk`) |
| Base | Fedora 44; tini 0.19.0; Xvfb, x11vnc 0.9.17, noVNC 1.5.0, websockify 0.12.0 for Server Administration sessions |

The versions above are what the image was tested with; a rebuild picks up
Fedora's and Adoptium's current 8.4.x and 21.x updates (the build refuses
anything else). Each build downloads the installer again.

### What was verified by running it, and what wasn't

Tested on Docker Engine 29.9.3 (Linux, x86-64), with the 26.10 and 26.9.1
installers, using the 14 Day Trial. `tests/run-checks.sh` repeats most of the
non-GUI checks.

| Check | Status |
|---|---|
| Build finds the one installer on the release, verifies size and SHA-256, reads the version from the file name | Verified against a local stand-in for GitHub's API |
| Build fails clearly with zero installers, two installers, a bad name or a checksum mismatch | Verified (stand-in) |
| Replacing the installer: the same build command produces the new version | Verified (stand-in) |
| `docker build <git URL>` and Compose's `build:` from a git URL, plus the `version` tag command | Verified with a local git server; GitHub's own URL untested |
| Image build proves MySQL 8.4.x and Java 21, and stops on anything else | Verified (the check passes in the image and stops when `mysqld` reports 9.7 or `java` reports 17) |
| First start asks only: license agreement, license key or trial, company name (licensed), MySQL password | Verified (trial end to end; licensed path with a placeholder key up to the database step) |
| Declining the agreement, end of input, or "y" installs nothing; no terminal exits with the exact command | Verified |
| After setup: MySQL 8.4.10, `lower_case_table_names = 1`, guide sql-mode, Fishbowl's tuning, heap 8192 MB, client 2048 MB, non-root processes | Verified |
| Creating a database in Server Administration through the browser session | Verified (VNC end to end; noVNC page and WebSocket-to-VNC handshake) |
| A Fishbowl Client outside the container connects through port 2456 | Verified (client in a separate container) |
| License key and MySQL password absent from `docker logs`; password not stored in plain text | Verified |
| Stop, remove, recreate on the same volumes: no prompts, data identical; a setup killed halfway recovers | Verified |
| **Restore tab:** `.sql` copied in with `docker cp`, restored into a new database and over an existing one, added on the Database tab, server restarted onto it | Verified (a Fishbowl backup, with a test table to compare) |
| Replacing the database Fishbowl Server is using, with the `admin` command | The pieces were verified (restore over an existing database; restore in `admin` mode); not run end to end |
| **Backup Database** in Server Administration writes `/opt/Fishbowl/data/backups/<database>_<date>.sql` | Verified |
| Settings changed while Fishbowl runs survive the restart (database, Inactivity Time, Server memory) | Verified. Without the container's fix, Fishbowl Server's shutdown undid them. |
| A session whose terminal was closed: the next `fishbowl-admin` offers to end it | Verified |
| Upgrade steps: agreement again, backup, installer over the existing install, data intact, no company/key prompts | Verified with the 26.10 installer under a higher version number, and from a real 26.9.1 install to 26.10 |
| Real 26.9.1 → 26.10 with a trial | Fishbowl Server refused to update the trial's database; all 368 tables were unchanged. The container now refuses trial upgrades up front (exit 7) and stops within seconds, with Fishbowl's reason, if Fishbowl refuses an update. Verified. |
| Upgrade with a purchased license, where Fishbowl updates the database at first start | **Untested** (needs a real license key) |
| Downgrade refused; declining an upgrade changes nothing | Verified |
| Backup (`fishbowl-backup`), `restore`, whole-volume backup and restore | Verified |
| Uploading these files through GitHub's web page, the real release download, the GitHub Actions workflow, ghcr.io | Untested (no repository existed yet). The workflow is lint-clean and its scripts were tested against the stand-in and a local registry. |
| The Fishbowl Client's Schedule-module backups; Secure Connection certificates; the other right-click database tools | Untested |
| A real license key; QuickBooks or other integrations | Untested |
| `linux/arm64`; Docker Desktop on Mac or Windows; rootless Docker; Podman | Untested |
| Behavior under production load (memory figures are estimates) | Untested |
