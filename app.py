#!/usr/bin/env python3
import os
import re
import json
import shutil
import subprocess
import threading
import webbrowser
import base64
import secrets
from pathlib import Path
from datetime import datetime, date
from urllib.request import urlopen, Request
from urllib.parse import urlparse, urlunparse, parse_qsl, urlencode

from flask import Flask, render_template, request, jsonify, send_from_directory, abort

try:
    from dotenv import load_dotenv  # optional
    load_dotenv()
except Exception:
    pass

# ─────────────────────────────────────────────────────────────────────────────
# Defaults (no secrets hard-coded)
# ─────────────────────────────────────────────────────────────────────────────
DEFAULT_GITHUB_TOKEN = os.getenv('DEFAULT_GITHUB_TOKEN', '')
DEFAULT_AES_PASSPHRASE = os.getenv('APPBOOT_TOKEN_KEY', 'pet1234')

# AES-GCM helpers (encrypt only; decrypt happens client-side in app)
try:
    from Crypto.Cipher import AES
    from Crypto.Protocol.KDF import scrypt
except Exception:
    AES = None
    scrypt = None

def _b64(x: bytes) -> str:
    return base64.urlsafe_b64encode(x).decode('ascii').rstrip('=')

def _aesgcm_encrypt(plaintext: str, passphrase: str) -> str:
    """
    Returns: aesgcm:v1:<salt_b64>:<nonce_b64>:<ct_b64>:<tag_b64>
    """
    if AES is None or scrypt is None:
        raise RuntimeError("PyCryptodome not installed. `pip install pycryptodome`")
    salt  = secrets.token_bytes(16)
    key   = scrypt(passphrase.encode('utf-8'), salt, key_len=32, N=2**15, r=8, p=1)
    nonce = secrets.token_bytes(12)
    cipher = AES.new(key, AES.MODE_GCM, nonce=nonce)
    ct, tag = cipher.encrypt_and_digest(plaintext.encode('utf-8'))
    return "aesgcm:v1:{}:{}:{}:{}".format(_b64(salt), _b64(nonce), _b64(ct), _b64(tag))

def _inject_encrypted_token(appboot: dict, token_plain: str, passphrase: str) -> dict:
    enc = _aesgcm_encrypt(token_plain, passphrase or DEFAULT_AES_PASSPHRASE)
    gh = appboot.setdefault('github', {})
    gh['token_enc'] = enc
    gh['token'] = ""  # avoid plaintext
    toks = appboot.setdefault('tokens', {})
    toks['github_enc'] = enc
    return appboot

# ─────────────────────────────────────────────────────────────────────────────
# Paths / config
# ─────────────────────────────────────────────────────────────────────────────
BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = (BASE_DIR / 'data' / 'js').resolve()
PREVIEW_DIR = (DATA_DIR / '_preview').resolve()
UNZIP_DIR = (PREVIEW_DIR / 'unzipped').resolve()
APPBOOT_JSON = DATA_DIR / 'appboot.json'
PAYLOAD = (BASE_DIR / 'payload.sh').resolve()
PORT = int(os.getenv('PORT', '5000'))

DEFAULT_CLOUD_URL = os.getenv(
    'CLOUD_ENC_URL',
    'https://raw.githubusercontent.com/pkweitai/loopdb/main/data/js/app.zip.enc'
)

app = Flask(__name__)

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────
def _json_files():
    if not DATA_DIR.exists():
        return []
    out = []
    for p in sorted(DATA_DIR.glob('*.json')):
        try:
            stat = p.stat()
            out.append({'name': p.name, 'path': str(p), 'size': stat.st_size, 'mtime': stat.st_mtime})
        except FileNotFoundError:
            pass
    return out

def _safe_name(name: str) -> str:
    name = os.path.basename(name)
    if not name.endswith('.json'):
        raise ValueError('Only .json files are allowed')
    return name

def _pretty_json_text(text: str) -> str:
    obj = json.loads(text)
    return json.dumps(obj, ensure_ascii=False, indent=2) + '\n'

def _read_json(path: Path):
    with path.open('r', encoding='utf-8') as f:
        return json.load(f)

def _write_json(path: Path, obj):
    text = json.dumps(obj, ensure_ascii=False, indent=2) + '\n'
    ts = datetime.now().strftime('%Y%m%d-%H%M%S')
    if path.exists():
        bak = path.with_suffix(path.suffix + f'.bak.{ts}')
        bak.write_text(path.read_text(encoding='utf-8'), encoding='utf-8')
    path.write_text(text, encoding='utf-8')

def _bump_semver(ver: str) -> str:
    if not isinstance(ver, str) or not ver.strip():
        return '1.0.0'
    s = ver.strip()
    if re.fullmatch(r'\d+(\.\d+)*', s):
        parts = [int(x) for x in s.split('.')]
        parts[-1] += 1
        return '.'.join(str(x) for x in parts)
    m = re.search(r'(.*?)(\d+)$', s)
    if m:
        head, num = m.group(1), m.group(2)
        return f'{head}{int(num)+1}'
    return s + '.1'

def _is_date_prefix(s: str) -> bool:
    return bool(re.match(r'^\d{4}-\d{2}-\d{2}', s or ''))

def _today_str() -> str:
    from datetime import date as _d
    return _d.today().isoformat()

def _bump_model_version(ver: str) -> str:
    if _is_date_prefix(ver or ''):
        suf = ver[10:] if isinstance(ver, str) and len(ver) > 10 else ''
        return _today_str() + suf
    return _bump_semver(ver or '')

def _extract_versions(appboot: dict):
    app_v = appboot.get('appVersion') or appboot.get('app_version') or ''
    model_v = appboot.get('modelVersion') or appboot.get('model_version') or ''
    return (str(app_v) if app_v is not None else '',
            str(model_v) if model_v is not None else '')

def _set_versions(appboot: dict, app_v: str, model_v: str):
    if 'appVersion' in appboot or 'app_version' not in appboot:
        appboot['appVersion'] = app_v
    else:
        appboot['app_version'] = app_v
    if 'modelVersion' in appboot or 'model_version' not in appboot:
        appboot['modelVersion'] = model_v
    else:
        appboot['model_version'] = model_v
    return appboot

def _download(url: str, dest: Path, force: bool = False):
    dest.parent.mkdir(parents=True, exist_ok=True)
    effective_url = url
    if force:
        pr = urlparse(url)
        q = dict(parse_qsl(pr.query))
        q['_cb'] = datetime.utcnow().strftime('%Y%m%d%H%M%S%f')
        pr = pr._replace(query=urlencode(q))
        effective_url = urlunparse(pr)
    req = Request(
        effective_url,
        headers={
            'User-Agent': 'appboot-portal/1.0',
            'Cache-Control': 'no-cache, no-store, max-age=0',
            'Pragma': 'no-cache',
        }
    )
    with urlopen(req, timeout=60) as r:
        data = r.read()
    dest.write_bytes(data)
    return len(data)

def _clear_preview_dirs():
    if PREVIEW_DIR.exists():
        shutil.rmtree(PREVIEW_DIR, ignore_errors=True)
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    UNZIP_DIR.mkdir(parents=True, exist_ok=True)

# ─────────────────────────────────────────────────────────────────────────────
# Routes
# ─────────────────────────────────────────────────────────────────────────────
@app.route('/')
def index():
    files = _json_files()
    app_v, model_v = '', ''
    try:
        if APPBOOT_JSON.exists():
            ab = _read_json(APPBOOT_JSON)
            app_v, model_v = _extract_versions(ab)
    except Exception:
        pass
    return render_template(
        'index.html',
        files=files,
        app_v=app_v,
        model_v=model_v,
        default_cloud_url=DEFAULT_CLOUD_URL,
        default_github_token=DEFAULT_GITHUB_TOKEN,
        default_passphrase=DEFAULT_AES_PASSPHRASE,
    )

@app.route('/api/list')
def api_list():
    return jsonify({'ok': True, 'files': _json_files()})

@app.route('/api/versions')
def api_versions():
    if not APPBOOT_JSON.exists():
        return jsonify({'ok': False, 'error': f'{APPBOOT_JSON} not found'}), 404
    try:
        ab = _read_json(APPBOOT_JSON)
        cur_app, cur_model = _extract_versions(ab)
        next_app = _bump_semver(cur_app)
        next_model = _bump_model_version(cur_model)
        return jsonify({'ok': True,
                        'current': {'appVersion': cur_app, 'modelVersion': cur_model},
                        'next': {'appVersion': next_app, 'modelVersion': next_model}})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 400

@app.route('/api/load')
def api_load():
    name = request.args.get('name', '')
    try:
        safe = _safe_name(name)
        p = (DATA_DIR / safe)
        if not p.exists():
            return jsonify({'ok': False, 'error': f'File not found: {safe}'}), 404
        text = p.read_text(encoding='utf-8')
        json.loads(text)  # validate
        return jsonify({'ok': True, 'name': safe, 'text': text})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 400

@app.route('/api/pretty', methods=['POST'])
def api_pretty():
    data = request.get_json(force=True, silent=True) or {}
    text = data.get('text', '')
    try:
        return jsonify({'ok': True, 'text': _pretty_json_text(text)})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 400

@app.route('/api/save', methods=['POST'])
def api_save():
    data = request.get_json(force=True, silent=True) or {}
    name = data.get('name', '')
    text = data.get('text', '')
    try:
        safe = _safe_name(name)
        pretty = _pretty_json_text(text)
        target = (DATA_DIR / safe)
        _write_json(target, json.loads(pretty))
        return jsonify({'ok': True, 'name': safe})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 400

@app.route('/api/build', methods=['POST'])
def api_build():
    if not PAYLOAD.exists():
        return jsonify({'ok': False, 'error': f'payload.sh not found at {PAYLOAD}'}), 400
    if not APPBOOT_JSON.exists():
        return jsonify({'ok': False, 'error': f'appboot.json not found at {APPBOOT_JSON}'}), 400

    body = request.get_json(force=True, silent=True) or {}
    passphrase = (body.get('passphrase') or '').strip()
    bump_app = bool(body.get('bumpApp', True))
    bump_model = bool(body.get('bumpModel', True))
    token_in = (body.get('token') or '').strip()
    token_plain = token_in if token_in else DEFAULT_GITHUB_TOKEN

    try:
        ab = _read_json(APPBOOT_JSON)

        # 1) insert encrypted token
        try:
            _inject_encrypted_token(ab, token_plain, passphrase or DEFAULT_AES_PASSPHRASE)
        except Exception as e:
            return jsonify({'ok': False, 'error': f'Encrypt token failed: {e}'}), 500

        # 2) bump versions
        cur_app, cur_model = _extract_versions(ab)
        next_app = _bump_semver(cur_app) if bump_app else cur_app
        next_model = _bump_model_version(cur_model) if bump_model else cur_model
        _set_versions(ab, next_app, next_model)
        _write_json(APPBOOT_JSON, ab)
        bump_info = {
            'current': {'appVersion': cur_app, 'modelVersion': cur_model},
            'next': {'appVersion': next_app, 'modelVersion': next_model},
        }

        # 3) make a lightweight appboot.zip
        import zipfile
        appboot_zip = (DATA_DIR / 'appboot.zip')
        with zipfile.ZipFile(str(appboot_zip), 'w', compression=zipfile.ZIP_DEFLATED) as z:
            z.write(str(APPBOOT_JSON), arcname='appboot.json')

    except Exception as e:
        return jsonify({'ok': False, 'error': f'Failed to prep build: {e}'}), 500

    # 4) call payload to produce app.zip/app.zip.enc (+ manifest)
    args = [str(PAYLOAD), '-u', '-s', 'data/js', '-d', 'data/js', '-o', 'app']
    key_for_payload = passphrase or DEFAULT_AES_PASSPHRASE
    if key_for_payload:
        args += ['-k', key_for_payload]

    try:
        proc = subprocess.run(args, cwd=str(BASE_DIR), capture_output=True, text=True)
        ok = proc.returncode == 0
        return jsonify({
            'ok': ok,
            'returncode': proc.returncode,
            'cmd': ' '.join(args),
            'stdout': proc.stdout[-20000:],
            'stderr': proc.stderr[-20000:],
            'bump': bump_info,
            'outputs': {
                'app_zip': str((DATA_DIR / 'app.zip').resolve()),
                'app_zip_enc': str((DATA_DIR / 'app.zip.enc').resolve()),
                'appboot_zip': str((DATA_DIR / 'appboot.zip').resolve()),
            }
        }), (200 if ok else 500)
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e), 'bump': bump_info}), 500

@app.route('/api/preview_fetch', methods=['POST'])
def api_preview_fetch():
    """
    Download cloud app.zip.enc, decrypt via payload.sh --decrypt, unzip, and list entries.
    """
    if not PAYLOAD.exists():
        return jsonify({'ok': False, 'error': f'payload.sh not found at {PAYLOAD}'}), 400

    data = request.get_json(force=True, silent=True) or {}
    url = (data.get('url') or DEFAULT_CLOUD_URL).strip()
    passphrase = (data.get('passphrase') or '').strip()
    key_for_decrypt = passphrase or DEFAULT_AES_PASSPHRASE
    force = bool(data.get('force', False))
    try:
        _clear_preview_dirs()
        enc_path = PREVIEW_DIR / 'cloud.app.zip.enc'
        zip_path = PREVIEW_DIR / 'cloud.app.zip'

        # 1) download
        size = _download(url, enc_path, force=force)

        # 2) decrypt via payload.sh --decrypt (timeout to avoid hanging)
        args = [str(PAYLOAD), '--decrypt', '-i', str(enc_path), '-O', str(zip_path), '-k', key_for_decrypt]
        from subprocess import TimeoutExpired
        try:
          proc = subprocess.run(args, cwd=str(BASE_DIR), capture_output=True, text=True, timeout=120)
        except TimeoutExpired:
          return jsonify({'ok': False, 'step': 'decrypt', 'error': 'decrypt timeout'}), 500

        if proc.returncode != 0:
            return jsonify({'ok': False,
                            'step': 'decrypt',
                            'cmd': ' '.join(args),
                            'stdout': proc.stdout[-20000:],
                            'stderr': proc.stderr[-20000:],
                            'error': 'decrypt failed'}), 500

        # 3) unzip JSON entries to UNZIP_DIR and list them
        import zipfile
        entries = []
        with zipfile.ZipFile(str(zip_path), 'r') as z:
            for info in z.infolist():
                entries.append({'name': info.filename, 'size': info.file_size})
                if info.filename.lower().endswith('.json'):
                    target = UNZIP_DIR / info.filename
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with z.open(info, 'r') as src, target.open('wb') as dst:
                        shutil.copyfileobj(src, dst)

        return jsonify({'ok': True,
                        'download_bytes': size,
                        'decrypt_cmd': ' '.join(args),
                        'entries': entries})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500

@app.route('/api/preview_read')
def api_preview_read():
    name = request.args.get('name', '').strip()
    name = name.lstrip('/').replace('\\', '/')
    if not name or '..' in name:
        return jsonify({'ok': False, 'error': 'invalid name'}), 400
    path = UNZIP_DIR / name
    if not path.exists() or not str(path).endswith('.json'):
        return jsonify({'ok': False, 'error': f'not found: {name}'}), 404
    try:
        text = path.read_text(encoding='utf-8')
        json.loads(text)
        return jsonify({'ok': True, 'name': name, 'text': text})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 400

@app.route('/manifest')
def get_manifest():
    mf = DATA_DIR / 'app.manifest.txt'
    if mf.exists():
        return send_from_directory(directory=str(DATA_DIR), path='app.manifest.txt')
    abort(404)

def open_browser():
    url = f'http://127.0.0.1:{PORT}/'
    try:
        webbrowser.open(url)
    except Exception:
        pass

if __name__ == '__main__':
    print(f'★ Data dir: {DATA_DIR}')
    print(f'★ Payload : {PAYLOAD}')
    threading.Timer(1.0, open_browser).start()
    app.run(host='127.0.0.1', port=PORT, debug=True, use_reloader=False)
