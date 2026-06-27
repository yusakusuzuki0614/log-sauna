#!/usr/bin/env bash
# =============================================================
# LOG サウナ点検アプリ  ワンショット・セットアップ
#   GitHub Pages 公開 + Firebase(Firestore) 接続まで自動化
#   ※ index.html と同じフォルダに置いて実行してください
#   ※ ログインは初回のみブラウザで承認（GitHub / Firebase）
# 使い方:  bash setup.sh
# =============================================================
set -uo pipefail

REPO="log-sauna"                       # GitHubリポジトリ名（変更可）
REGION="asia-northeast1"               # 東京リージョン
HTML="index.html"
FB_ID="log-sauna-$(date +%y%m%d%H%M)"  # 一意なFirebaseプロジェクトID

echo "▶ 必要なCLIを確認..."
need() { command -v "$1" >/dev/null 2>&1 || { echo "✗ $1 が必要です → $2"; MISS=1; }; }
MISS=0
need gh       "brew install gh"
need firebase "npm install -g firebase-tools"
need jq       "brew install jq"
need git      "xcode-select --install"
[ "${MISS:-0}" = "1" ] && { echo "不足分を入れて再実行してください"; exit 1; }
[ -f "$HTML" ] || { echo "✗ $HTML が見つかりません。同じフォルダに置いてください"; exit 1; }

echo "▶ ① ログイン（初回のみブラウザが開きます）"
gh auth status >/dev/null 2>&1 || gh auth login
firebase login

echo "▶ ② Firebaseプロジェクト作成: $FB_ID"
firebase projects:create "$FB_ID" --display-name "LOG Sauna" || true

echo "▶ ③ Firestore データベース作成（$REGION）"
firebase firestore:databases:create "(default)" --project "$FB_ID" --location "$REGION" 2>/dev/null \
  || gcloud firestore databases create --location="$REGION" --project="$FB_ID" 2>/dev/null \
  || echo "  （作成済み、またはコンソールで一度Firestoreを有効化してください）"

echo "▶ ④ Webアプリ作成 & 設定値の取得"
APP_ID=$(firebase apps:create web "LOG Sauna Web" --project "$FB_ID" --json 2>/dev/null | jq -r '.result.appId // .appId // empty')
[ -z "$APP_ID" ] && APP_ID=$(firebase apps:list web --project "$FB_ID" --json | jq -r '.result[0].appId // empty')
CFG=$(firebase apps:sdkconfig web "$APP_ID" --project "$FB_ID" --json 2>/dev/null)

get(){ echo "$CFG" | jq -r "(.result.sdkConfig.$1 // .sdkConfig.$1 // empty)"; }
apiKey=$(get apiKey); authDomain=$(get authDomain); projectId=$(get projectId)
storageBucket=$(get storageBucket); messagingSenderId=$(get messagingSenderId); appId=$(get appId)
[ -z "$projectId" ] && projectId="$FB_ID"
[ -z "$authDomain" ] && authDomain="${FB_ID}.firebaseapp.com"
[ -z "$storageBucket" ] && storageBucket="${FB_ID}.appspot.com"

echo "▶ ⑤ index.html に設定値を差し込み"
python3 - "$HTML" "$apiKey" "$authDomain" "$projectId" "$storageBucket" "$messagingSenderId" "$appId" <<'PY'
import sys, re
html, apiKey, authDomain, projectId, storageBucket, messagingSenderId, appId = sys.argv[1:8]
vals = dict(apiKey=apiKey, authDomain=authDomain, projectId=projectId,
            storageBucket=storageBucket, messagingSenderId=messagingSenderId, appId=appId)
s = open(html, encoding="utf-8").read()
for k, v in vals.items():
    if v:
        s = re.sub(rf'({k}\s*:\s*")[^"]*(")', rf'\g<1>{v}\g<2>', s, count=1)
open(html, "w", encoding="utf-8").write(s)
print("  ✓ FIREBASE_CONFIG を更新（projectId=%s）" % projectId)
PY

echo "▶ ⑥ Firestore ルール（※当面オープン：URLは社外秘で運用）"
cat > firestore.rules <<'RULES'
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    // 当面は誰でも読み書き可（社内運用・URL非公開前提）。
    // 後でスタッフ用ログインを入れたら if request.auth != null 等に変更。
    match /{document=**} { allow read, write: if true; }
  }
}
RULES
cat > firebase.json <<'JSON'
{ "firestore": { "rules": "firestore.rules" } }
JSON
firebase deploy --only firestore:rules --project "$FB_ID" || echo "  （ルールは後でコンソールからでも設定可）"

echo "▶ ⑦ GitHub リポジトリ作成 & push"
[ -d .git ] || git init -q
git add -A && git commit -qm "LOG sauna app + firebase config" || true
if ! git remote get-url origin >/dev/null 2>&1; then
  gh repo create "$REPO" --public --source=. --remote=origin --push
else
  git push -u origin HEAD || git push
fi

echo "▶ ⑧ GitHub Pages 有効化"
USER=$(gh api user -q .login)
echo '{"source":{"branch":"main","path":"/"}}' | gh api -X POST "repos/$USER/$REPO/pages" --input - >/dev/null 2>&1 \
  || echo "  （既に有効、または Settings→Pages で main/root を選択してください）"

URL="https://$USER.github.io/$REPO/"
echo ""
echo "============================================================"
echo "✅ 完了！  公開URL（反映に1〜2分）:"
echo "   $URL"
echo "   iPhone/iPad は Safari で開き「ホーム画面に追加」でアプリ化"
echo "============================================================"
