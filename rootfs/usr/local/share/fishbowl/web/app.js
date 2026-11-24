// The Fishbowl page (main page). Plain JavaScript, no libraries.
// It asks the container for its status every two seconds and shows the part of
// the page that fits. Text from the container is always set as text, never as HTML.
'use strict';
(function () {
  const $ = (id) => document.getElementById(id);
  const show = (el, on) => { el.hidden = !on; };
  const LOCAL = ['localhost', '127.0.0.1', '[::1]', '::1'];

  const STATES = {
    'starting-up':         ['busy', 'Starting up…', ''],
    'needs-setup':         ['wait', "Fishbowl isn't installed yet", 'Fill in the form below. Nothing is accepted or installed until you do.'],
    'setup':               ['busy', 'Installing Fishbowl…', "This takes a minute or two. MySQL is set up first, then Fishbowl's own installer runs. The page updates by itself."],
    'awaiting-database':   ['wait', 'No company database is selected yet', 'Fishbowl Server starts by itself once one is. Restore a backup or create a new database below.'],
    'starting':            ['busy', 'Fishbowl Server is starting…', "This usually takes under a minute. After an upgrade, or with a database from an older Fishbowl version, it updates the database first, which can take a long time on a large one. Don't stop the container meanwhile."],
    'running':             ['good', 'Fishbowl Server is running', ''],
    'stopping-server':     ['busy', 'Fishbowl Server is stopping…', ''],
    'paused':              ['wait', 'Fishbowl Server is stopped', 'MySQL is still running, so Server Administration works. Fishbowl Clients can connect again once you start Fishbowl Server.'],
    'server-failed':       ['bad', "Fishbowl Server didn't start", ''],
    'upgrading':           ['busy', 'Upgrading Fishbowl…', "Backing up every database, then Fishbowl's installer updates the program. Fishbowl Server starts again afterwards. Don't stop the container meanwhile."],
    'upgrade-interrupted': ['bad', "An upgrade didn't finish", ''],
    'updating':            ['busy', 'Fishbowl is updating itself…', "Fishbowl downloaded an update (Auto Updates in Server Administration). The container backed up every database first; Fishbowl's updater is applying it now, and Fishbowl Server starts again by itself. Don't stop the container meanwhile."],
    'no-volumes':          ['bad', 'Nothing is running: the volumes are missing', ''],
    'foreign-data':        ['bad', "Nothing is running: these volumes weren't set up by this container", ''],
    'downgrade':           ['bad', 'Nothing is running: this image is older than your Fishbowl', ''],
    'stopped':             ['wait', 'The container is stopping', ''],
  };
  const SHOW_MESSAGE = ['server-failed', 'upgrade-interrupted', 'no-volumes', 'foreign-data', 'downgrade', 'starting'];
  const ADMIN_OK = ['awaiting-database', 'starting', 'running', 'paused', 'server-failed'];
  const INSTALLED = ['awaiting-database', 'starting', 'running', 'stopping-server', 'paused', 'server-failed'];
  const UPGRADE_OK = ['awaiting-database', 'starting', 'running', 'paused', 'server-failed', 'upgrade-interrupted'];

  let eula = null;          // { text, sha256, variants }
  let eulaLoading = false;
  let last = null;          // the last status
  const waiting = { setup: 0, upgrade: 0 };   // when the form was submitted (ms), 0 = not waiting

  // ------------------------------------------------------------ talking to the container
  async function api(method, path, body) {
    const r = await fetch(path, {
      method,
      credentials: 'same-origin',
      cache: 'no-store',
      headers: { 'X-Fishbowl': '1', 'Content-Type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    let data = {};
    try { data = await r.json(); } catch (e) { /* no JSON body */ }
    if (r.status === 401) { location.href = '/login'; throw new Error('Signed out.'); }
    if (!r.ok) throw new Error(data.error || 'The container answered with an error (' + r.status + ').');
    return data;
  }

  function fmtSize(n) {
    if (n >= 1073741824) return (n / 1073741824).toFixed(2) + ' GB';
    if (n >= 1048576) return (n / 1048576).toFixed(1) + ' MB';
    if (n >= 1024) return Math.round(n / 1024) + ' KB';
    return n + ' bytes';
  }

  function setText(el, text) { if (el.textContent !== text) el.textContent = text; }

  // A button that asks for a second click before it acts.
  function armable(btn, action) {
    const label = btn.textContent;
    let timer = null;
    const disarm = () => { clearTimeout(timer); btn.classList.remove('armed'); btn.textContent = label; };
    btn.addEventListener('click', async () => {
      if (!btn.classList.contains('armed')) {
        btn.classList.add('armed');
        btn.textContent = btn.dataset.confirm || 'Click again to confirm';
        timer = setTimeout(disarm, 6000);
        return;
      }
      disarm();
      btn.disabled = true;
      try { await action(); } finally { btn.disabled = false; }
    });
  }

  // ------------------------------------------------------------ the license agreement
  async function loadEula() {
    if (eula || eulaLoading) return;
    eulaLoading = true;
    try {
      eula = await api('GET', '/api/eula');
      for (const id of ['setup-eula', 'upgrade-eula']) $(id).textContent = eula.text;
      if (eula.variants && eula.variants.length) {
        const p = $('setup-eula-variants');
        p.textContent = "Fishbowl's installer also carries another version of these terms: ";
        eula.variants.forEach((name, i) => {
          const a = document.createElement('a');
          a.href = '/api/eula?variant=' + encodeURIComponent(name);
          a.target = '_blank';
          a.rel = 'noopener';
          a.textContent = name;
          if (i) p.append(', ');
          p.append(a);
        });
        show(p, true);
      }
    } catch (e) {
      for (const id of ['setup-eula', 'upgrade-eula']) $(id).textContent = "The license agreement couldn't be loaded. Reload the page.";
    } finally {
      eulaLoading = false;
    }
  }

  // ------------------------------------------------------------ rendering
  // The image's MySQL root password is never shown or sent to the browser: Fishbowl
  // fills the Password field in by itself. Only an installation made by an earlier
  // version of this image has a password of its own to type (and to give for upgrades).
  function showRootPassword(s) {
    const own = s.root_password_kind === 'own';
    for (const el of document.querySelectorAll('.pw-image')) show(el, !own);
    for (const el of document.querySelectorAll('.pw-own')) show(el, own);
    show($('upgrade-pw-card'), own);
  }

  function render(s) {
    last = s;
    showRootPassword(s);
    const state = s.state;
    const def = STATES[state] || ['wait', 'Status: ' + state, ''];

    // top bar
    const version = s.installed_version || '';
    show($('pill-version'), true);
    setText($('pill-version'), version ? 'Fishbowl ' + version + ' installed' : 'Image carries Fishbowl ' + s.image_version);
    show($('pill-license'), !!s.install_type);
    setText($('pill-license'), s.install_type === 'trial' ? 'Trial' : 'Licensed');

    // Over the network, only plain HTTP is a problem; the Compose stack's edge serves HTTPS.
    show($('net-warning'), !LOCAL.includes(location.hostname) && location.protocol !== 'https:');
    show($('volumes-warning'), s.volumes === 'unnamed');
    const stale = typeof s.image_age_days === 'number' && s.image_age_days > s.image_max_age_days;
    show($('image-age-warning'), stale);
    if (stale) {
      setText($('image-age-days'), String(s.image_age_days));
      setText($('image-built'), (s.image_built || '').slice(0, 10));
    }

    // status card
    $('status-dot').className = 'dot ' + def[0];
    let title = def[1];
    let text = def[2];
    if (state === 'setup') title = 'Installing Fishbowl ' + s.image_app_version + '…';
    if (state === 'running') {
      text = (s.database ? 'Company database: ' + s.database + '. ' : '') +
        "Fishbowl Clients connect to this computer's name or IP address, port " + (s.client_port || '2456') +
        ' (or the port you published it on).';
    }
    if (state === 'upgrading' && s.upgrade_to) title = 'Upgrading to Fishbowl ' + s.upgrade_to + '…';
    setText($('status-title'), title);
    setText($('status-text'), text);
    const message = SHOW_MESSAGE.includes(state) ? (s.message || '') : '';
    setText($('status-message'), message);
    show($('status-message'), !!message);

    // buttons
    const adminOpen = s.sessions && s.sessions.admin !== 'closed';
    const clientOpen = s.sessions && s.sessions.client !== 'closed';
    show($('open-client'), state === 'running');
    setText($('open-client'), clientOpen ? 'Show Fishbowl Client (open)' : 'Open Fishbowl Client');
    show($('open-admin'), ADMIN_OK.includes(state));
    setText($('open-admin'), adminOpen ? 'Show Server Administration (open)' : 'Open Server Administration');
    $('open-admin').className = 'button' + (state === 'awaiting-database' ? ' primary' : '');
    show($('server-start'), state === 'paused' || state === 'server-failed');
    show($('server-restart'), state === 'running');
    show($('server-stop'), state === 'running');
    show($('actions'), ADMIN_OK.includes(state));
    if (!ADMIN_OK.includes(state)) show($('action-error'), false);

    // settings waiting for a restart
    show($('pending-card'), !!s.pending_settings && state === 'running');
    setText($('pending-db'), s.pending_database && s.pending_database !== s.database
      ? 'After the restart the company database is: ' + s.pending_database + '.' : '');

    // what went wrong last time (kept quiet while a request is still on its way)
    const pending = s.requests || {};
    const working = state === 'setup' || state === 'upgrading' || pending.setup || pending.upgrade;
    const err = working ? '' : (s.last_error || '');
    let errTitle = "That didn't work";
    if (state === 'needs-setup') errTitle = "Setup didn't finish, and nothing is installed";
    else if (s.upgrade_to) errTitle = "The upgrade didn't go through";
    setText($('error-title'), errTitle);
    setText($('error-text'), err);
    show($('error-card'), !!err);

    // first-time setup
    const needSetup = state === 'needs-setup';
    show($('setup-card'), needSetup);
    if (needSetup) {
      loadEula();
      fillTimeZones(s.time_zone);
      show($('setup-volumes'), s.volumes === 'unnamed');
      if (waiting.setup && !pending.setup && (err || Date.now() - waiting.setup > 30000)) waiting.setup = 0;
    } else {
      waiting.setup = 0;
    }
    $('setup-submit').disabled = !!waiting.setup;
    setText($('setup-submit'), waiting.setup ? 'Starting the install…' : 'Install Fishbowl');

    // the company database, and .sql files
    show($('database-card'), state === 'awaiting-database');
    show($('imports-card'), INSTALLED.includes(state));
    show($('restore-help'), state !== 'awaiting-database');
    const trialNote = s.install_type === 'trial'
      ? 'This is a trial installation. It can use a backup made by Fishbowl ' + versionShort(s.installed_version) +
        '. A backup from an older Fishbowl version needs a purchased license: Fishbowl Server has to update it, and refuses to for a trial.'
      : '';
    setText($('trial-restore-note'), trialNote);
    show($('trial-restore-note'), !!trialNote);
    renderImports(s.imports || [], s);

    // a newer Fishbowl in this image
    show($('upgrade-blocked-card'), s.upgrade_blocked === 'trial');
    if (s.upgrade_blocked === 'trial') {
      setText($('upgrade-blocked-text'), 'This image carries Fishbowl ' + s.image_version + ', and Fishbowl ' + s.installed_version +
        " in your volumes is a trial installation. Fishbowl Server doesn't update a trial's database to a new version, so the trial is not upgraded and Fishbowl " +
        s.installed_version + ' keeps running. Licensed now? Enter your purchased license in Server Administration (License tab), then restart the container: ' +
        'the upgrade is offered here after that.');
    }
    const canUpgrade = !!s.upgrade_to && UPGRADE_OK.includes(state);
    show($('upgrade-card'), canUpgrade);
    if (canUpgrade) {
      loadEula();
      setText($('upgrade-title'), 'Upgrade to Fishbowl ' + s.upgrade_to);
      setText($('upgrade-intro'), state === 'upgrade-interrupted'
        ? 'Run the upgrade again to finish it. Fishbowl Server stays stopped until it has.'
        : 'This image carries Fishbowl ' + s.upgrade_to + '. Fishbowl ' + s.installed_version +
          ' is installed and keeps running until you upgrade here. The upgrade needs two things from you.');
      setText($('upgrade-accept-label'), "I have read and accept Fishbowl's license agreement for Fishbowl " + s.upgrade_to + '.');
      if (waiting.upgrade && !pending.upgrade && (err || Date.now() - waiting.upgrade > 30000)) waiting.upgrade = 0;
    } else {
      waiting.upgrade = 0;
    }
    $('upgrade-submit').disabled = !!waiting.upgrade;
    setText($('upgrade-submit'), waiting.upgrade ? 'Checking, then upgrading…' : 'Back up and upgrade');
  }

  // "2026.10.1" -> [2026, 10]: Fishbowl's database versions follow the year.month release.
  function versionParts(v) { return String(v || '').split('.').slice(0, 2).map((x) => parseInt(x, 10) || 0); }
  function versionShort(v) { return versionParts(v).join('.'); }
  function compareVersions(a, b) {
    const x = versionParts(a), y = versionParts(b);
    return x[0] - y[0] || x[1] - y[1];
  }

  // What to say about a backup, given the Fishbowl installed here.
  function madeByNote(f, s) {
    if (f.made_by === 'n/a') return ['', ''];   // not a .sql file, nothing to read
    if (f.made_by === null || f.made_by === undefined) return ['Reading…', ''];
    if (f.made_by === '') return ['Unknown', "No Fishbowl version found in this file. Is it a backup made by Fishbowl?"];
    const label = 'Fishbowl ' + f.made_by;
    const installed = s.installed_version;
    if (!installed) return [label, ''];
    const cmp = compareVersions(f.made_by, installed);
    if (cmp === 0) return [label, ''];
    if (cmp > 0) {
      return [label, 'warn:Made by a newer Fishbowl than the one installed (' + versionShort(installed) +
        '). An older Fishbowl may not be able to use it: restore it into the same Fishbowl version or newer.'];
    }
    if (s.install_type === 'trial') {
      return [label, 'warn:Older than the installed Fishbowl ' + versionShort(installed) +
        '. Fishbowl Server has to update it when it starts, and a trial installation can\'t: Fishbowl refuses with "Trial accounts do not have access to update the database." It needs a purchased license (Server Administration, License tab).'];
    }
    return [label, 'Older than the installed Fishbowl ' + versionShort(installed) +
      ': Fishbowl Server updates the database the first time it starts on it, which can take a while on a large one.'];
  }

  let importsKey = '';
  function renderImports(files, s) {
    const key = JSON.stringify([files, s.installed_version, s.install_type]);
    if (key === importsKey) return;
    importsKey = key;
    const body = $('imports-body');
    body.textContent = '';
    for (const f of files) {
      const tr = document.createElement('tr');
      const name = document.createElement('td');
      const code = document.createElement('code');
      code.textContent = f.name;
      name.append(code);
      const [label, note] = madeByNote(f, s);
      const made = document.createElement('td');
      made.className = 'made';
      made.textContent = label;
      if (note) {
        const n = document.createElement('span');
        n.className = note.startsWith('warn:') ? 'note warn' : 'note';
        n.textContent = note.replace(/^warn:/, '');
        name.append(n);
      }
      const size = document.createElement('td');
      size.className = 'num';
      size.textContent = fmtSize(f.size);
      const act = document.createElement('td');
      const del = document.createElement('button');
      del.type = 'button';
      del.className = 'danger';
      del.textContent = 'Remove';
      del.dataset.confirm = 'Click again to remove';
      armable(del, async () => {
        try { await api('DELETE', '/api/imports/' + encodeURIComponent(f.name)); }
        catch (e) { uploadMessage(e.message, true); }
        poll(true);
      });
      act.append(del);
      tr.append(name, made, size, act);
      body.append(tr);
    }
    show($('imports-table'), files.length > 0);
  }

  // ------------------------------------------------------------ polling
  let pollTimer = null;
  async function poll(once) {
    try {
      const r = await fetch('/api/status', { credentials: 'same-origin', cache: 'no-store' });
      if (r.status === 401) { location.href = '/login'; return; }
      if (!r.ok) throw new Error('status ' + r.status);
      render(await r.json());
      show($('offline'), false);
    } catch (e) {
      show($('offline'), true);
    }
    if (once === true) return;
    pollTimer = setTimeout(poll, 2000);
  }

  // ------------------------------------------------------------ first-time setup
  // The time zone list: the container's own zone first when it's a named one (it
  // may follow daylight saving time, which no GMT offset does), then GMT -12 to
  // GMT +14. Filled once, so a choice isn't reset by the next status poll.
  let tzFilled = false;
  function gmtText(minutes) {
    const m = Math.abs(minutes);
    return 'GMT ' + (minutes < 0 ? '-' : '+') + Math.floor(m / 60) + (m % 60 ? ':' + String(m % 60).padStart(2, '0') : '');
  }
  function fillTimeZones(tz) {
    if (tzFilled || !tz) return;
    tzFilled = true;
    const sel = $('setup-tz');
    const named = !/^(UTC|Etc\/(GMT|UTC).*)$/.test(tz.name);
    const now = gmtText(tz.offset_minutes);
    const dst = tz.daylight_saving ? ', changes for daylight saving time' : '';
    setText($('setup-tz-now'), 'This container is on ' + (named ? tz.name + ' (' + now + ' now' + dst + ')' : now) +
      '. Fishbowl dates orders, receipts and reports in its time zone.');
    if (named) {
      const o = document.createElement('option');
      o.value = 'keep';
      o.textContent = 'Keep ' + tz.name + ' (' + now + ' now)';
      sel.appendChild(o);
    }
    for (let h = -12; h <= 14; h++) {
      const o = document.createElement('option');
      o.value = String(h);
      o.textContent = 'GMT ' + (h < 0 ? '-' : '+') + Math.abs(h);
      sel.appendChild(o);
    }
    sel.value = named ? 'keep' : String(Math.round(tz.offset_minutes / 60));
  }

  function formError(id, text) {
    const el = $(id);
    el.textContent = text || '';
    show(el, !!text);
    if (text) el.scrollIntoView({ block: 'nearest' });
  }

  async function submitSetup(ev) {
    ev.preventDefault();
    formError('setup-error', '');
    if (!eula) return formError('setup-error', "The license agreement hasn't loaded yet. Reload the page.");
    if (!$('setup-accept').checked) return formError('setup-error', "Tick the box to accept Fishbowl's license agreement first. Fishbowl can't be installed without it.");
    const license = document.querySelector('input[name=license]:checked');
    const body = {
      eula_accepted: true,
      eula_sha256: eula.sha256,
      license: license ? license.value : '',
      timezone: $('setup-tz').value || 'keep',
    };
    if (body.license === 'key') {
      body.key = $('setup-key').value.replace(/\s+/g, '');
      body.company = $('setup-company').value.trim();
      if (body.key.length < 5) return formError('setup-error', 'Paste your whole license key, or choose the 14 Day Trial.');
      if (!body.company) return formError('setup-error', 'Enter the company name exactly as it appears on your Fishbowl license.');
    }
    if (last && last.volumes === 'unnamed' && !$('setup-volumes-ok').checked) {
      return formError('setup-error', 'Tick the box under "Before you install", or start the container again with named volumes.');
    }
    $('setup-submit').disabled = true;
    try {
      await api('POST', '/api/setup', body);
      waiting.setup = Date.now();
      $('setup-key').value = '';
      window.scrollTo({ top: 0, behavior: 'smooth' });
    } catch (e) {
      formError('setup-error', e.message);
    }
    poll(true);
  }

  async function submitUpgrade(ev) {
    ev.preventDefault();
    formError('upgrade-error', '');
    if (!eula) return formError('upgrade-error', "The license agreement hasn't loaded yet. Reload the page.");
    if (!$('upgrade-accept').checked) return formError('upgrade-error', "Tick the box to accept the license agreement for the new version first. Without it nothing is upgraded.");
    // Only an installation from an earlier version of this image has a password to give.
    const needsPassword = !!last && last.root_password_kind === 'own';
    const password = needsPassword ? $('upgrade-pw').value : '';
    if (needsPassword && !password) return formError('upgrade-error', 'Enter the MySQL root password you chose when this installation was set up.');
    $('upgrade-submit').disabled = true;
    try {
      await api('POST', '/api/upgrade', { eula_accepted: true, eula_sha256: eula.sha256, password });
      waiting.upgrade = Date.now();
      $('upgrade-pw').value = '';
      window.scrollTo({ top: 0, behavior: 'smooth' });
    } catch (e) {
      formError('upgrade-error', e.message);
    }
    poll(true);
  }

  // ------------------------------------------------------------ uploads
  let xhr = null;
  function uploadMessage(text, bad) {
    const el = $('upload-message');
    el.textContent = text || '';
    el.className = bad ? 'error' : 'ok';
    show(el, !!text);
  }
  function uploadDone() {
    xhr = null;
    show($('upload-progress-row'), false);
    $('upload-button').disabled = false;
    poll(true);
  }
  async function upload() {
    const file = $('upload-file').files[0];
    uploadMessage('');
    if (!file) return uploadMessage('Choose a file first.', true);
    $('upload-button').disabled = true;
    try {
      await api('POST', '/api/imports-check', { name: file.name, size: file.size });
    } catch (e) {
      $('upload-button').disabled = false;
      return uploadMessage(e.message, true);
    }
    xhr = new XMLHttpRequest();
    xhr.open('PUT', '/api/imports/' + encodeURIComponent(file.name));
    xhr.setRequestHeader('X-Fishbowl', '1');
    $('upload-progress').value = 0;
    $('upload-progress-text').textContent = '0%';
    show($('upload-progress-row'), true);
    xhr.upload.onprogress = (e) => {
      if (!e.lengthComputable) return;
      const pct = Math.floor(e.loaded / e.total * 100);
      $('upload-progress').value = pct;
      $('upload-progress-text').textContent = pct + '% of ' + fmtSize(e.total);
    };
    xhr.onload = () => {
      let data = {};
      try { data = JSON.parse(xhr.responseText); } catch (e) { /* not JSON */ }
      if (xhr.status === 200) {
        uploadMessage('Uploaded ' + data.name + ' (' + fmtSize(data.size) + '). In Server Administration, open the file chooser and go to the import folder.');
        $('upload-file').value = '';
      } else if (xhr.status === 401) {
        location.href = '/login';
      } else {
        uploadMessage(data.error || 'The upload failed (' + xhr.status + ').', true);
      }
      uploadDone();
    };
    xhr.onerror = () => { uploadMessage('The upload was interrupted. Check that the container is running, then try again.', true); uploadDone(); };
    xhr.onabort = () => { uploadMessage('Upload cancelled.', true); uploadDone(); };
    xhr.send(file);
  }

  // ------------------------------------------------------------ wiring
  async function serverAction(action) {
    show($('action-error'), false);
    try {
      await api('POST', '/api/server/' + action, {});
    } catch (e) {
      $('action-error').textContent = e.message;
      show($('action-error'), true);
    }
    poll(true);
  }

  document.addEventListener('DOMContentLoaded', () => {
    $('setup-form').addEventListener('submit', submitSetup);
    $('upgrade-form').addEventListener('submit', submitUpgrade);
    $('upload-button').addEventListener('click', upload);
    $('upload-cancel').addEventListener('click', () => { if (xhr) xhr.abort(); });
    $('server-start').addEventListener('click', () => serverAction('start'));
    armable($('server-restart'), () => serverAction('restart'));
    armable($('server-stop'), () => serverAction('stop'));
    armable($('pending-restart'), () => serverAction('restart'));
    for (const radio of document.querySelectorAll('input[name=license]')) {
      radio.addEventListener('change', () => {
        show($('setup-key-fields'), document.querySelector('input[name=license]:checked').value === 'key');
      });
    }
    for (const btn of document.querySelectorAll('button.reveal')) {
      btn.addEventListener('click', () => {
        const input = $(btn.dataset.for);
        const hide = input.type === 'text';
        input.type = hide ? 'password' : 'text';
        btn.textContent = hide ? 'Show' : 'Hide';
      });
    }
    poll();
  });
})();
