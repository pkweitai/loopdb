#!/usr/bin/env zsh
# payload.sh — zip assets and encrypt for CDN
# Modes:
#   -u       : single-bundle (subject "appboot vX.Y")
#   -uimage  : per-pet bundles (subject "assets version X.Y")
# deps: zip, openssl, git
# Safe-guards:
#   • Never (re)enable Git LFS for *.enc
#   • Scrub LFS attr lines that would match *.enc in any .gitattributes we touch
#   • Verbose logging for git operations

emulate -L zsh
set -o errexit -o nounset -o pipefail
setopt extended_glob null_glob

# ---------- Defaults ----------
: ${SRC_DIR:="."}
: ${OUT_NAME_DEFAULT:="config_bundle"}
: ${OUT_NAME:="${OUT_NAME_DEFAULT}"}
: ${OUT_DIR:="."}
: ${ENV_FILE:=".env"}
: ${CIPHER:="aes-256-cbc"}
: ${KEEP_ZIP:=false}
UPDATE=false
UPDATE_IMAGES=false

# track explicit flags so -u/-uimage set sane defaults only if not given
SRC_SET=false
OUT_SET=false
DST_SET=false

# --- New decrypt flags ---
DECRYPT=false
DEC_IN=""
DEC_OUT=""


usage() {
  cat <<'USAGE'
Usage:
  ./payload.sh [options]

Options:
  -s, --src <dir>       Source directory (default: .)
  -o, --out <name>      Output base name (default: config_bundle) [ignored by -uimage]
  -d, --dest <dir>      Output directory (default: . ; -uimage default: ./images)
  -k, --key <string>    Passphrase (prefer env PASS)
  -e, --env <file>      .env with PASS (default: .env)
  --cipher <name>       OpenSSL cipher (default: aes-256-cbc)
  --keep-zip            Keep intermediate .zip (default: delete)
  -u, --update          One bundle; defaults -s ./ -d ./ -o app; commit "appboot vX.Y"
  -uimage               Per-pet bundles; defaults -s ./ -d ./images; commit "assets version X.Y"
  -h, --help            Help
  -x|--decrypt) DECRYPT=true; shift ;;
 -i|--in)      DEC_IN="$2"; shift 2 ;;
-O|--out)     DEC_OUT="$2"; shift 2 ;;

USAGE
}

# ---------- Helpers ----------
log() { print -r -- "$@"; }

run() {
  print -r -- "↪︎ $*"
  eval "$@"
}

sha256_of() {
  local f="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    openssl dgst -sha256 "$f" | awk '{print $2}'
  fi
}

bytes_to_mb() {
  local b="$1"
  if command -v bc >/dev/null 2>&1; then
    printf '%.2f' "$(echo "$b / 1048576" | bc -l)"
  else
    awk -v n="$b" 'BEGIN{printf "%.2f", n/1048576}'
  fi
}

file_size_bytes() { (stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null) }

prev_version_appboot() {
  git log --grep='^appboot v[0-9]' --format='%s' -n 1 2>/dev/null \
    | sed -nE 's/^appboot v([0-9]+(\.[0-9]+)?)\b.*/\1/p'
}
prev_version_assets() {
  git log --grep='^assets version [0-9]' --format='%s' -n 1 2>/dev/null \
    | sed -nE 's/^assets version ([0-9]+(\.[0-9]+)?)\b.*/\1/p'
}
next_version() {
  local prev="$1"
  if [[ -z "$prev" ]]; then
    echo "1.1"; return
  fi
  local major="${prev%%.*}"
  local minor="${prev#*.}"
  [[ "$minor" == "$prev" ]] && minor=0
  [[ "$major" != <-> ]] && major=1
  [[ "$minor" != <-> ]] && minor=0
  echo "${major}.$((minor+1))"
}

# --- No-LFS guard: strip *.enc LFS rules & ensure tracked as normal blobs ----
strip_lfs_rules_for_enc() {
  # Remove lines that BOTH mention .enc and filter=lfs
  local files
  files=("${(@f)$(git ls-files -z '**/.gitattributes' 2>/dev/null | tr -d '\0')}")
  for ga in $files .gitattributes; do
    [[ -f "$ga" ]] || continue
    if grep -Eq 'filter=lfs' "$ga"; then
      # surgical remove: lines that target *.enc and use filter=lfs
      run "sed -i.bak -E '/filter=lfs/ { /(^|[[:space:]])[^#]*\\.enc([^[:alnum:]_]|$)/d; }' $ga"
      # also purge the weird leftover rules seen before
      run "sed -i '' -e '/^patterns[[:space:]]\+filter=lfs/d' -e '/^see[[:space:]]\+filter=lfs/d' $ga" 2>/dev/null || true
      # if empty after edits, remove it (keeps repo clean)
      [[ -s "$ga" ]] || run "rm -f $ga"
    fi
  done

  # Enforce local override too (even if some attr sneaks back later)
  mkdir -p .git/info
  if [[ ! -f .git/info/attributes ]] || ! grep -q '\*.enc' .git/info/attributes; then
    log "🔒 Writing local attribute override for *.enc"
    print -r -- "*.enc -filter -diff -merge -text" >> .git/info/attributes
  fi
}

reindex_as_normal_blob() {
  # Re-stage provided paths as normal blobs (not pointers)
  local paths=("$@")
  [[ "${#paths}" -gt 0 ]] || return 0
  for p in "${paths[@]}"; do
    [[ -f "$p" ]] || continue
    # If it's an LFS pointer (starts with 'version https://git-lfs.github.com/spec/v1'), fail hard
    if head -c 30 "$p" | grep -q 'https://git-lfs.github.com/spec/v1'; then
      log "❌ '$p' looks like a Git LFS pointer. Overwrite it with the real encrypted file before committing."
      exit 1
    fi
    # Make sure attributes no longer resolve to LFS
    if git check-attr filter -- "$p" | grep -qi 'lfs'; then
      log "⚠️  '$p' still matches filter=lfs; scrubbing attributes…"
      strip_lfs_rules_for_enc
    fi
    run "git rm --cached -- '$p'" || true
    run "git add -- '$p'"
  done
}

# ---------- Parse args ----------
KEY_FROM_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--src)   SRC_DIR="$2"; SRC_SET=true; shift 2 ;;
    -o|--out)   OUT_NAME="$2"; OUT_SET=true; shift 2 ;;
    -d|--dest)  OUT_DIR="$2"; DST_SET=true; shift 2 ;;
    -k|--key)   KEY_FROM_ARG="$2"; shift 2 ;;
    -e|--env)   ENV_FILE="$2"; shift 2 ;;
    --cipher)   CIPHER="$2"; shift 2 ;;
    --keep-zip) KEEP_ZIP=true; shift ;;
    -u|--update) UPDATE=true; shift ;;
    -uimage) UPDATE_IMAGES=true; shift ;;
    -x|--decrypt) DECRYPT=true; shift ;;
    -i|--in)      DEC_IN="$2"; shift 2 ;;
    -O|--out)     DEC_OUT="$2"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

# Defaults for modes
if $UPDATE; then
  $SRC_SET || SRC_DIR="./"
  $DST_SET || OUT_DIR="./"
  $OUT_SET || OUT_NAME="app"
fi
if $UPDATE_IMAGES; then
  $SRC_SET || SRC_DIR="./"
  $DST_SET || OUT_DIR="./images"
fi

# ---------- Preflight ----------
for cmd in zip openssl git; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "❌ '$cmd' not found"; exit 1; }
done

# Load env if present
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
fi

# Passphrase
PASS="${KEY_FROM_ARG:-${PASS:-}}"
if [[ -z "${PASS:-}" ]]; then
  read -rs "PASS?Enter encryption passphrase: "
  echo
  [[ -z "$PASS" ]] && { echo "❌ No passphrase provided"; exit 1; }
fi


# ---------- Mode: decrypt only ----------
if $DECRYPT; then
  [[ -n "${DEC_IN}" && -n "${DEC_OUT}" ]] || { echo "❌ For --decrypt, pass -i <enc> and -O <zip>"; exit 1; }
  # Load env if present (so PASS may come from .env)
  if [[ -f "$ENV_FILE" ]]; then
    set -a; source "$ENV_FILE"; set +a
  fi
  # Passphrase
  PASS="${KEY_FROM_ARG:-${PASS:-}}"
  if [[ -z "${PASS:-}" ]]; then
    read -rs "PASS?Enter encryption passphrase: "
    echo
    [[ -z "$PASS" ]] && { echo "❌ No passphrase provided"; exit 1; }
  fi
  CIPHER="${CIPHER:-aes-256-cbc}"
  echo "🔓 Decrypting:"
  echo "  in : $DEC_IN"
  echo "  out: $DEC_OUT"
  openssl enc -d "-${CIPHER}" -pbkdf2 -md sha256 -in "$DEC_IN" -out "$DEC_OUT" -pass "pass:${PASS}"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "❌ Decrypt failed (rc=$rc)"
    exit $rc
  fi
  echo "✅ Decrypted to: $DEC_OUT"
  exit 0
fi


# ---------- Paths ----------
[[ -d "$SRC_DIR" ]] || { echo "❌ Source dir not found: $SRC_DIR"; exit 1; }

OUT_DIR_ABS="$(cd "$OUT_DIR" && pwd -P)"
SRC_DIR_ABS="$(cd "$SRC_DIR" && pwd -P)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
run "mkdir -p '$OUT_DIR_ABS'"

log "🧭 repo=$REPO_ROOT"
log "🗂  src=$SRC_DIR_ABS"
log "📤 out_dir=$OUT_DIR_ABS"

# Pre-emptively scrub LFS *.enc rules
strip_lfs_rules_for_enc
run "git add -A :/ 2>/dev/null || true"

# ---------- Mode: per-pet images ----------
if $UPDATE_IMAGES; then
  typeset -A PETS

  log "🔎 Scanning for petX_Y.png in: $SRC_DIR_ABS"
  for f in $SRC_DIR_ABS/pet<->_<->.png(N); do
    base="${f:t}"            # filename
    prefix="${base%%_*}"     # petX
    PETS[$prefix]=1
  done

  if (( ${#PETS} == 0 )); then
    echo "❌ No files matching pet<NUM>_<NUM>.png in $SRC_DIR_ABS"
    exit 1
  fi

  log "📚 Groups: ${(k)PETS}"

  CHANGED_FILES=()
  COMMIT_LINES=()
  ts="$(date +%Y%m%d-%H%M%S)"

  for pet in ${(k)PETS}; do
    ZIP_PATH="${OUT_DIR_ABS%/}/${pet}.zip"
    ENC_PATH="${OUT_DIR_ABS%/}/${pet}.zip.enc"
    MANIFEST_PATH="${OUT_DIR_ABS%/}/${pet}.manifest.txt"

    run "rm -f '$ZIP_PATH' '$ENC_PATH' '$MANIFEST_PATH'"

    frames=($SRC_DIR_ABS/${pet}_<->.png(N))
    if (( ${#frames} == 0 )); then
      log "⚠️  ${pet}: no frames found; skipping"
      continue
    fi

    log "📦 ${pet}: zipping ${#frames} frames → $ZIP_PATH"
    run "zip -j -q -9 '$ZIP_PATH' ${frames:q}"

    ZIP_SHA="$(sha256_of "$ZIP_PATH")"

    {
      echo "bundle: ${pet}"
      echo "date:   ${ts}"
      echo "cipher: ${CIPHER}"
      echo "src:    ${SRC_DIR_ABS}"
      echo
      echo "# files:"
      print -rl -- ${frames[@]:t} | sort -V
      echo
      echo "# sha256(zip):"
      echo "$ZIP_SHA  ${pet}.zip"
    } > "$MANIFEST_PATH"

    log "🔐 ${pet}: encrypting → $ENC_PATH"
    run "openssl enc '-${CIPHER}' -pbkdf2 -md sha256 -salt -in '$ZIP_PATH' -out '$ENC_PATH' -pass 'pass:${PASS}'"

    ENC_SHA="$(sha256_of "$ENC_PATH")"
    ENC_SIZE_BYTES="$(file_size_bytes "$ENC_PATH")"
    ENC_MB="$(bytes_to_mb "$ENC_SIZE_BYTES")"

    {
      echo
      echo "# sha256(enc):"
      echo "$ENC_SHA  ${pet}.zip.enc"
      echo "# size(enc): ${ENC_MB} MB"
    } >> "$MANIFEST_PATH"

    [[ "${KEEP_ZIP}" != true ]] && run "rm -f '$ZIP_PATH'"

    CHANGED_FILES+=("$ENC_PATH" "$MANIFEST_PATH")
    COMMIT_LINES+=("${pet}.zip.enc  sha256=${ENC_SHA}  size=${ENC_MB}MB")
  done

  if (( ${#CHANGED_FILES} == 0 )); then
    echo "ℹ️  Nothing produced."
    exit 0
  fi

  # Make sure these will be committed as normal blobs
  reindex_as_normal_blob "${CHANGED_FILES[@]}"

  BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
  PREV_VER="$(prev_version_assets || true)"
  NEXT_VER="$(next_version "$PREV_VER")"
  log "🧾 Previous assets version: ${PREV_VER:-<none>}"
  log "🔖 Next assets version: $NEXT_VER"

  run "git add -- ${CHANGED_FILES:q}"

  COMMIT_MSG=$'assets version '"${NEXT_VER}"$'\n\nPer-pet image bundles:\n'
  for line in "${COMMIT_LINES[@]}"; do
    COMMIT_MSG+="- ${line}\n"
  done

  if run "git commit -m $(printf %q "$COMMIT_MSG")"; then
    log "🚀 git push → origin ${BRANCH}"
    run "git push -u origin '${BRANCH}'"
  else
    log "ℹ️ Nothing to commit (no changes)."
  fi

  log "✅ Done (-uimage). Outputs in: $OUT_DIR_ABS"
  exit 0
fi

# ---------- Mode: single-bundle (-u) ----------
ts="$(date +%Y%m%d-%H%M%S)"
ZIP_PATH="${OUT_DIR_ABS%/}/${OUT_NAME}.zip"
ENC_PATH="${OUT_DIR_ABS%/}/${OUT_NAME}.zip.enc"
MANIFEST_PATH="${OUT_DIR_ABS%/}/${OUT_NAME}.manifest.txt"

if $UPDATE; then
  log "🧹 Cleaning old bundle(s) for base '${OUT_NAME}' in ${OUT_DIR_ABS}"
  run "rm -f '$ZIP_PATH' '$ENC_PATH' '$MANIFEST_PATH'"
fi

file_count=$(find "$SRC_DIR_ABS" -type f \( -name '*.json' -o -name '*.png' \) | wc -l | tr -d ' ')
[[ "$file_count" -gt 0 ]] || { echo "❌ No .json or .png found in $SRC_DIR_ABS"; exit 1; }

log "📦 Zipping $file_count file(s) (*.json, *.png) from: $SRC_DIR_ABS"
(
  cd "$SRC_DIR_ABS"
  run "zip -r -q -9 '$ZIP_PATH' . -i '*.json' '*.png'"
)

ZIP_SHA="$(sha256_of "$ZIP_PATH")"

{
  echo "bundle: ${OUT_NAME}"
  echo "date:   ${ts}"
  echo "cipher: ${CIPHER}"
  echo "src:    ${SRC_DIR_ABS}"
  echo
  echo "# files:"
  (cd "$SRC_DIR_ABS" && find . -type f \( -name '*.json' -o -name '*.png' \) -print | sort)
  echo
  echo "# sha256(zip):"
  echo "$ZIP_SHA  ${OUT_NAME}.zip"
} > "$MANIFEST_PATH"

log "🔐 Encrypting → $ENC_PATH"
run "openssl enc '-${CIPHER}' -pbkdf2 -md sha256 -salt -in '$ZIP_PATH' -out '$ENC_PATH' -pass 'pass:${PASS}'"

ENC_SHA="$(sha256_of "$ENC_PATH")"
ENC_SIZE_BYTES="$(file_size_bytes "$ENC_PATH")"
ENC_MB="$(bytes_to_mb "$ENC_SIZE_BYTES")"

{
  echo
  echo "# sha256(enc):"
  echo "$ENC_SHA  ${OUT_NAME}.zip.enc"
  echo "# size(enc): ${ENC_MB} MB"
} >> "$MANIFEST_PATH"

[[ "${KEEP_ZIP}" != true ]] && run "rm -f '$ZIP_PATH'"

log "✅ Done. Encrypted bundle at: $ENC_PATH"
log "   sha256(enc) = $ENC_SHA"
log "   size(enc)   = ${ENC_MB} MB"

if $UPDATE; then
  BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
  PREV_VER="$(prev_version_appboot || true)"
  NEXT_VER="$(next_version "$PREV_VER")"

  # Ensure normal blob for *.enc
  reindex_as_normal_blob "$ENC_PATH" "$MANIFEST_PATH"

  run "git -C '$OUT_DIR_ABS' add '${OUT_NAME}.zip.enc' '${OUT_NAME}.manifest.txt'"

  if run "git commit -m 'appboot v${NEXT_VER}' -m 'sha256(enc): ${ENC_SHA}' -m 'manifest: ${OUT_NAME}.manifest.txt'"; then
    log "🚀 git push → origin ${BRANCH}"
    run "git push -u origin '${BRANCH}'"
  else
    log "ℹ️ Nothing to commit (no changes)."
  fi
fi

echo
echo "To decrypt:"
echo "  openssl enc -d -${CIPHER} -pbkdf2 -md sha256 -in '${ENC_PATH}' -out '${OUT_NAME}.zip'"
echo "  unzip '${OUT_NAME}.zip'"
