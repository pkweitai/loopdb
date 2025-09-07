# Appboot Portal (Flask)

Local UI to edit `./data/js/*.json` and trigger `payload.sh -u` to build `app.zip.enc`.

## Layout
```
flask_portal/
  app.py
  templates/
    index.html
  static/
    app.js
    style.css
```

## Quick start
```bash
cd flask_portal
# Put your repo's data/js and payload.sh alongside app.py or symlink them:
#   ln -s ../data data
#   ln -s ../payload.sh payload.sh
python3 -m pip install -r requirements.txt
# Optionally set passphrase (matches your app):
echo 'PASS=pet1234' > .env
python3 app.py
# Browser opens at http://127.0.0.1:5000/
```

### Build & push
Click **Build & Push (-u)**. It runs:
```
./payload.sh -u -s data/js -d data/js -o app [-k <pass>]
```
- If you typed a passphrase in the UI field, it uses `-k`.
- Otherwise it relies on `PASS` from `.env` or your shell env.

The output log is shown in the page. You can open `manifest` from the header to view `data/js/app.manifest.txt` after a successful build.

> Note: Make sure `payload.sh` is executable: `chmod +x payload.sh`.
> The script will commit & push if there are changes (per its `-u` mode).

## Notes
- Server validates and pretty-prints JSON on save (2-space indent).
- It backs up the previous file to `*.json.bak.YYYYMMDD-HHMMSS` before overwriting.
- The app only lists and allows editing `*.json` inside `./data/js`.
