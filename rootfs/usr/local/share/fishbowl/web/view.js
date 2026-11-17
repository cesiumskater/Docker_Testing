// A Fishbowl window in a browser tab: /admin is Fishbowl Server Administration,
// /client is the Fishbowl Client. The picture comes from noVNC (the VNC viewer
// that runs in the browser); this file opens the window in the container,
// connects noVNC to it, and says what happened when it closes.
import RFB from '/novnc/core/rfb.js';

const name = location.pathname.replace(/\/+$/, '') === '/client' ? 'client' : 'admin';
const TITLE = name === 'client' ? 'Fishbowl Client' : 'Fishbowl Server Administration';
const SHORT = name === 'client' ? 'The Fishbowl Client' : 'Server Administration';

const $ = (id) => document.getElementById(id);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const show = (el, on) => { el.hidden = !on; };

let rfb = null;
let retries = 0;
let opening = false;

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
const getStatus = () => api('GET', '/api/status');

function overlay(kind, title, text, withActions) {
  $('overlay-dot').className = 'dot ' + kind;
  $('overlay-title').textContent = title;
  $('overlay-text').textContent = text || '';
  show($('overlay-actions'), !!withActions);
  show($('overlay'), true);
}
function setConn(text) { $('conn').textContent = text; }

// How much room the tab has for the window (the container opens it at this size).
function stageSize() {
  const el = $('scroller');
  return { width: Math.max(1000, Math.floor(el.clientWidth)), height: Math.max(640, Math.floor(el.clientHeight)) };
}

async function open() {
  if (opening) return;
  opening = true;
  retries = 0;
  setConn('Opening…');
  overlay('busy', 'Opening ' + TITLE + '…', 'This takes a few seconds.');
  try {
    await api('POST', '/api/session/' + name + '/open', stageSize());
    const deadline = Date.now() + 90000;
    while (Date.now() < deadline) {
      let s = null;
      try { s = await getStatus(); } catch (e) { /* try again */ }
      if (s && s.sessions && s.sessions[name] === 'ready') {
        opening = false;
        connect();
        return;
      }
      await sleep(700);
    }
    throw new Error(SHORT + " didn't open. The container's log may say why: docker logs fishbowl");
  } catch (e) {
    opening = false;
    setConn('Not open');
    overlay('bad', SHORT + " isn't open", e.message, true);
    $('overlay-open').textContent = 'Try again';
  }
}

function connect() {
  const url = (location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/ws/' + name;
  $('screen').textContent = '';
  setConn('Connecting…');
  rfb = new RFB($('screen'), url, { shared: true });
  rfb.scaleViewport = false;
  rfb.resizeSession = true;      // the window's screen follows the size of this tab
  rfb.focusOnClick = true;
  rfb.background = '#26303c';
  rfb.addEventListener('connect', () => {
    retries = 0;
    setConn('Connected');
    show($('overlay'), false);
    rfb.focus();
  });
  rfb.addEventListener('disconnect', onDisconnect);
  rfb.addEventListener('clipboard', (e) => { $('clip').value = e.detail.text; });
}

async function onDisconnect() {
  rfb = null;
  setConn('Not connected');
  let s = null;
  try { s = await getStatus(); } catch (e) { /* container may be restarting */ }
  if (s && s.sessions && s.sessions[name] !== 'closed' && retries < 5) {
    retries += 1;
    overlay('busy', 'Reconnecting…', '');
    await sleep(1500);
    connect();
    return;
  }
  closed(s);
}

// What to say once the window has closed. It depends on what the container is
// doing, so the text keeps itself up to date while it is on screen.
function closedText(s) {
  if (!s) return "The container isn't answering. If it is restarting, open the Fishbowl page to see when it's back.";
  if (name === 'client') {
    return s.state === 'running'
      ? 'You can open it again any time.'
      : "Fishbowl Server isn't running right now, and the Client needs it. The Fishbowl page shows what it's waiting for.";
  }
  if (s.state === 'awaiting-database') {
    return 'No company database is selected yet, so Fishbowl Server is still waiting. Open Server Administration again to restore or create one.';
  }
  if (s.state === 'starting') return "Fishbowl Server is starting now. The Fishbowl page shows when it's running.";
  if (s.pending_settings) {
    return 'The settings you changed take effect when Fishbowl Server restarts. Press "Restart Fishbowl Server" on the Fishbowl page when it suits you.';
  }
  if (s.state === 'running') {
    return 'Fishbowl Server is running' + (s.database ? ' with the company database ' + s.database : '') + '. You can open Server Administration again any time.';
  }
  return 'You can open it again any time.';
}

let closedTimer = null;
function closed(s) {
  setConn('Closed');
  $('overlay-open').textContent = 'Open it again';
  overlay('wait', SHORT + ' has closed', closedText(s), true);
  clearInterval(closedTimer);
  closedTimer = setInterval(async () => {
    if (rfb || opening) { clearInterval(closedTimer); return; }
    let now = null;
    try { now = await getStatus(); } catch (e) { /* not answering */ }
    if (!rfb && !opening) $('overlay-text').textContent = closedText(now);
  }, 3000);
}

// ---- the side panel
let sideTimer = null;
async function refreshSide() {
  if ($('side').hidden || name !== 'admin') return;
  try {
    const s = await getStatus();
    const files = (s.imports || []).map((f) => f.name);
    $('side-files').textContent = files.length
      ? 'In the import folder: ' + files.join(', ')
      : 'The import folder is empty. Upload the file on the Fishbowl page first.';
  } catch (e) { /* keep what is shown */ }
}
function toggleSide() {
  const side = $('side');
  show(side, side.hidden);
  clearInterval(sideTimer);
  if (!side.hidden) {
    refreshSide();
    sideTimer = setInterval(refreshSide, 4000);
  }
}

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
    await action();
  });
}

document.title = TITLE;
$('title').textContent = TITLE;
for (const el of document.querySelectorAll(name === 'client' ? '.for-client' : '.for-admin')) show(el, true);
$('toggle-side').addEventListener('click', toggleSide);
$('overlay-open').addEventListener('click', open);
$('clip').addEventListener('input', () => { if (rfb) rfb.clipboardPasteFrom($('clip').value); });
$('clip-clear').addEventListener('click', () => { $('clip').value = ''; if (rfb) rfb.clipboardPasteFrom(''); });
armable($('force-close'), async () => {
  try { await api('POST', '/api/session/' + name + '/close', {}); } catch (e) { /* shown by the disconnect */ }
});
open();

// The MySQL root password for the "Password" step of Server Administration. The
// Fishbowl window is Java, so the easy way in is the clipboard box above: one
// click puts the password there, then click the field in the window and press Ctrl+V.
(async () => {
  let pw = '';
  try { pw = (await getStatus()).mysql_root_password || ''; } catch (e) { /* the page shows the rest anyway */ }
  const text = pw || 'the MySQL root password you chose when this installation was set up';
  for (const el of document.querySelectorAll('.mysql-pw')) el.textContent = text;
  if (!pw) return;
  for (const btn of document.querySelectorAll('.mysql-pw-copy')) {
    show(btn, true);
    btn.addEventListener('click', () => {
      $('clip').value = pw;
      if (rfb) rfb.clipboardPasteFrom(pw);
    });
  }
})();
