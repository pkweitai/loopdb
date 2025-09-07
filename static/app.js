let files = [];
let current = null;
const $list = document.getElementById('file-list');
const $content = document.getElementById('content');
const $filename = document.getElementById('filename');
const $status = document.getElementById('status');
const $btnPretty = document.getElementById('btn-pretty');
const $btnSave = document.getElementById('btn-save');
const $btnReload = document.getElementById('btn-reload');
const $btnBuild = document.getElementById('btn-build');
const $log = document.getElementById('log');
const $pass = document.getElementById('passphrase');
const $vers = document.getElementById('vers');
const $chkApp = document.getElementById('chk-app');
const $chkModel = document.getElementById('chk-model');

const $cloudUrl = document.getElementById('cloud-url');
const $btnFetch = document.getElementById('btn-fetch');
const $cloudStatus = document.getElementById('cloud-status');
const $previewList = document.getElementById('preview-list');

function setStatus(msg, ok=true) {
  $status.textContent = msg;
  $status.style.color = ok ? '#1a7f37' : '#b91c1c';
}

function setCloudStatus(msg, ok=true) {
  $cloudStatus.textContent = msg;
  $cloudStatus.style.color = ok ? '#6b7280' : '#b91c1c';
}

async function loadVersions() {
  try {
    const res = await fetch('/api/versions');
    const data = await res.json();
    if (data.ok) {
      const c = data.current, n = data.next;
      $vers.textContent = `appVersion ${c.appVersion || '-'} → ${n.appVersion} | modelVersion ${c.modelVersion || '-'} → ${n.modelVersion}`;
    } else {
      $vers.textContent = '(no appboot.json)';
    }
  } catch (e) {
    $vers.textContent = '(versions error)';
  }
}

async function loadList() {
  const res = await fetch('/api/list');
  const data = await res.json();
  files = data.files || [];
  $list.innerHTML = '';
  for (const f of files) {
    const li = document.createElement('li');
    li.textContent = f.name;
    if (current && f.name === current) li.classList.add('active');
    li.onclick = () => openFile(f.name);
    $list.appendChild(li);
  }
  if (!current && files.length) openFile('appboot.json');
  loadVersions();
}

async function openFile(name) {
  const res = await fetch('/api/load?name=' + encodeURIComponent(name));
  const data = await res.json();
  if (!data.ok) {
    setStatus('Error: ' + data.error, false);
    return;
  }
  current = data.name;
  $filename.textContent = current;
  $content.value = data.text;
  setStatus('Loaded ' + current);
  for (const li of $list.children) {
    li.classList.toggle('active', li.textContent === current);
  }
}

$btnPretty.onclick = async () => {
  try {
    const txt = $content.value;
    const res = await fetch('/api/pretty', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({text: txt})
    });
    const data = await res.json();
    if (data.ok) {
      $content.value = data.text;
      setStatus('Pretty-printed');
    } else {
      setStatus('Invalid JSON: ' + data.error, false);
    }
  } catch (e) {
    setStatus('Pretty error: ' + e, false);
  }
};

$btnSave.onclick = async () => {
  if (!current) return;
  try {
    const res = await fetch('/api/save', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({name: current, text: $content.value})
    });
    const data = await res.json();
    if (data.ok) setStatus('Saved ' + current);
    else setStatus('Save failed: ' + data.error, false);
  } catch (e) {
    setStatus('Save error: ' + e, false);
  } finally {
    loadVersions();
  }
};

$btnReload.onclick = async () => {
  if (current) openFile(current);
  else loadList();
  loadVersions();
};

$btnBuild.onclick = async () => {
  $btnBuild.disabled = true;
  $log.classList.remove('hidden');
  $log.textContent = 'Building...';
  try {
    const res = await fetch('/api/build', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({
        passphrase: $pass.value,
        bumpApp: $chkApp.checked,
        bumpModel: $chkModel.checked
      })
    });
    const data = await res.json();
    $log.textContent = `CMD: ${data.cmd || ''}\n\n--- STDOUT ---\n${data.stdout || ''}\n\n--- STDERR ---\n${data.stderr || ''}\n\nRC=${data.returncode}\n\nBUMP=${JSON.stringify(data.bump || {}, null, 2)}`;
    setStatus(data.ok ? 'Build complete' : 'Build failed', !!data.ok);
  } catch (e) {
    $log.textContent = 'Error: ' + e;
    setStatus('Build exception', false);
  } finally {
    $btnBuild.disabled = false;
    loadVersions();
  }
};

/* -------- Cloud preview -------- */
$btnFetch.onclick = async () => {
  $btnFetch.disabled = true;
  setCloudStatus('Fetching...', true);
  $previewList.innerHTML = '';
  try {
    const res = await fetch('/api/preview_fetch', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({ url: $cloudUrl.value, passphrase: $pass.value })
    });
    const data = await res.json();
    if (!data.ok) {
      setCloudStatus('Failed: ' + (data.error || 'unknown error'), false);
      return;
    }
    setCloudStatus(`Downloaded ${data.download_bytes} bytes. Decrypted. ${data.entries.length} files in zip.`);

    // list entries; click to open JSONs
    const entries = data.entries || [];
    for (const ent of entries) {
      const li = document.createElement('li');
      li.textContent = `${ent.name} (${ent.size} B)`;
      if (ent.name.toLowerCase().endsWith('.json')) {
        li.classList.add('clickable');
        li.onclick = async () => {
          const r = await fetch('/api/preview_read?name=' + encodeURIComponent(ent.name));
          const d = await r.json();
          if (d.ok) {
            $filename.textContent = 'PREVIEW: ' + d.name;
            $content.value = d.text;
            setStatus('Previewing ' + d.name);
          } else {
            setStatus('Preview error: ' + (d.error || 'unknown'), false);
          }
        };
      }
      $previewList.appendChild(li);
    }
  } catch (e) {
    setCloudStatus('Exception: ' + e, false);
  } finally {
    $btnFetch.disabled = false;
  }
};

loadList();
