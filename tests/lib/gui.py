"""Drive Fishbowl Server Administration like a person would, over VNC.

In normal use the window is shown by the Fishbowl page in a browser tab. For
the checks, vnc_bridge.py (copied into the test container) forwards a TCP port
to the window's private VNC socket, and vncdotool (pip install vncdotool) does
the clicking and typing.

Positions are measured from the top-left corner of the window's blue header,
which is found in a screenshot, so they don't depend on the screen size or on
where the window manager put the window. They are those of Fishbowl 26.10's
Server Administration; a later Fishbowl version may move things (the
screenshots each step saves show where a run went wrong).
"""
import os
import subprocess
import time

HEADER_BLUE = bytes((45, 156, 219))

# x, y from the header's top-left corner
TAB_DATABASE = (60, 59)
TAB_RESTORE = (320, 59)
PLUS = (651, 83)
ROW1 = (323, 108)          # first database in the list; rows are 25 px apart
ROW_HEIGHT = 25
OK = (485, 519)
CANCEL = (553, 519)
# "Database Connection" (after +)
CONN_DATABASE = (349, 139)
CONN_PASSWORD = (349, 238)
CONN_CONNECT = (346, 418)
# "Settings" (country and costing method, new databases only)
SETTINGS_OK = (427, 455)
# "Database Selected" (after OK)
SELECTED_OK = (328, 294)
# Restore tab
RESTORE_MAGNIFIER = (649, 178)
RESTORE_DATABASE = (366, 242)
RESTORE_PASSWORD = (366, 341)
RESTORE_BUTTON = (608, 373)
# "Database Restore File" (file chooser)
CHOOSER_FILE_NAME = (372, 339)
CHOOSER_OPEN = (451, 408)
# "Restore Operation" (Yes / No) and "Database Restored" (OK)
RESTORE_YES = (303, 294)
RESTORED_OK = (323, 294)


def start_bridge(container, admin_port=5999, client_port=5998):
    """Copy vnc_bridge.py into the container and start it there."""
    here = os.path.dirname(os.path.abspath(__file__))
    subprocess.run(["docker", "cp", os.path.join(here, "vnc_bridge.py"), f"{container}:/tmp/vnc_bridge.py"],
                   check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["docker", "exec", "-d", container, "python3", "-I", "/tmp/vnc_bridge.py",
                    f"{admin_port}=/run/fishbowl/x/admin.rfb", f"{client_port}=/run/fishbowl/x/client.rfb"], check=True)
    time.sleep(1)


class Gui:
    def __init__(self, vnc, shots):
        """vnc: "127.0.0.1::PORT" (the published bridge port); shots: folder for screenshots."""
        self.vnc = vnc
        self.shots = shots
        self.origin = None
        os.makedirs(shots, exist_ok=True)

    def vncdo(self, *args):
        exe = os.environ.get("VNCDO", "vncdo")
        subprocess.run([exe, "-s", self.vnc, *args], check=True, timeout=180,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def shot(self, name):
        path = os.path.join(self.shots, name + ".png")
        self.vncdo("capture", path)
        return path

    def locate(self, timeout=60):
        """Find the window: the first long run of the header's blue in a screenshot."""
        from PIL import Image
        deadline = time.time() + timeout
        while True:
            path = self.shot("locate")
            im = Image.open(path).convert("RGB")
            at = im.tobytes().find(HEADER_BLUE * 300)
            if at >= 0 and at % 3 == 0:
                y, x = divmod(at // 3, im.width)
                self.origin = (x, y)
                return self.origin
            if time.time() > deadline:
                raise RuntimeError("Server Administration's window wasn't found on the screen (see locate.png). "
                                   "A newer Fishbowl may look different; tests/lib/gui.py has the positions.")
            time.sleep(2)

    def at(self, pos, dy=0):
        return str(self.origin[0] + pos[0]), str(self.origin[1] + pos[1] + dy)

    def click(self, pos, dy=0, pause=0.6):
        x, y = self.at(pos, dy)
        self.vncdo("move", x, y, "click", "1", "pause", str(pause))

    def replace_text(self, pos, text):
        """Click a field, select what is in it, delete it, type."""
        x, y = self.at(pos)
        self.vncdo("move", x, y, "click", "1", "pause", "0.4", "key", "ctrl-a", "key", "bsp", "pause", "0.2", "type", text, "pause", "0.4")

    # ---- the things a person does
    def create_database(self, name, mysql_password, table_count, timeout=900):
        """Database tab -> + -> name and password -> Connect -> wizard (defaults) -> wait.
        mysql_password None: leave the Password field as Fishbowl filled it in (what the
        page tells people to do; the image's password is never typed or shown)."""
        self.click(TAB_DATABASE)
        self.click(PLUS, pause=3)
        self.shot("create-1-form")
        self.replace_text(CONN_DATABASE, name)
        if mysql_password is not None:
            self.replace_text(CONN_PASSWORD, mysql_password)
        self.click(CONN_CONNECT, pause=20)
        self.shot("create-2-settings")
        self.click(SETTINGS_OK)       # United States, Average Costing: fine for a throwaway test database
        deadline = time.time() + timeout
        n = 0
        while time.time() < deadline:
            time.sleep(10)
            n = table_count(name)
            if n >= 300:
                break
        if n < 300:
            self.shot("create-timeout")
            raise RuntimeError(f"database {name} has only {n} tables after {timeout}s")
        time.sleep(20)
        self.shot("create-3-created")
        return n

    def restore(self, path_in_container, database, mysql_password, table_count, timeout=1800):
        """Restore tab -> choose the file -> database name and password -> Restore -> Yes -> wait -> OK.
        mysql_password None: leave the Password field as Fishbowl filled it in."""
        self.click(TAB_RESTORE, pause=2)
        self.click(RESTORE_MAGNIFIER, pause=3)
        self.shot("restore-1-chooser")
        self.replace_text(CHOOSER_FILE_NAME, path_in_container)
        self.click(CHOOSER_OPEN, pause=3)
        self.replace_text(RESTORE_DATABASE, database)
        if mysql_password is not None:
            self.replace_text(RESTORE_PASSWORD, mysql_password)
        self.shot("restore-2-filled")
        self.click(RESTORE_BUTTON, pause=3)
        self.shot("restore-3-confirm")
        self.click(RESTORE_YES)
        # Done when the table count has stopped growing.
        deadline = time.time() + timeout
        last, same = -1, 0
        while time.time() < deadline:
            time.sleep(5)
            n = table_count(database)
            same = same + 1 if (n == last and n >= 300) else 0
            last = n
            if same >= 3:
                break
        if same < 3:
            self.shot("restore-timeout")
            raise RuntimeError(f"restore into {database} did not settle (tables: {last})")
        time.sleep(8)
        self.shot("restore-4-restored")
        self.click(RESTORED_OK, pause=2)
        return last

    def select_database(self, row=0):
        """Database tab -> click a row -> OK -> OK on "Database Connection has been changed"."""
        self.click(TAB_DATABASE, pause=1.5)
        self.shot("select-1-list")
        self.click(ROW1, dy=row * ROW_HEIGHT)
        self.click(OK, pause=5)
        self.shot("select-2-after-ok")
        try:
            self.click(SELECTED_OK, pause=3)
        except subprocess.SubprocessError:
            pass   # the window may already be closing

    def cancel(self):
        try:
            self.click(CANCEL, pause=2)
        except subprocess.SubprocessError:
            pass
