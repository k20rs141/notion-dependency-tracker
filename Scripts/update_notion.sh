#!/usr/bin/env bash
set -eo pipefail

# ── 環境変数チェック ──
: "${NOTION_TOKEN:?Need NOTION_TOKEN env var}"
: "${NOTION_DATABASE_ID:?Need NOTION_DATABASE_ID env var}"
: "${PROJECT_NAME:?Need PROJECT_NAME env var}"

echo "🔧 Project: ${PROJECT_NAME}"
echo "🌿 Branch: ${GITHUB_REF_NAME:-unknown}"
echo "🚀 Event: ${GITHUB_EVENT_NAME:-unknown}"

# ── 現在時刻 ──
now_iso=$(date -u +%FT%TZ)
echo "🕐 Update Time (ISO): ${now_iso}"

# ── 検出された依存関係管理ツール ──
MANAGERS=""

if [[ "${GITHUB_EVENT_NAME}" == "workflow_dispatch" ]]; then
  echo "🔍 Manual execution - checking current dependency files..."
  
  if [[ -f "Podfile.lock" ]]; then
    MANAGERS="$MANAGERS CocoaPods"
    echo "📦 Found: Podfile.lock"
  fi
  
  if [[ -f "Package.resolved" ]] || find . -type f -name "Package.resolved" -print -quit | grep -q .; then
    MANAGERS="$MANAGERS SPM"
    echo "📦 Found: Package.resolved files"
  fi
else
  echo "🔍 Push event - detecting changed dependency files..."
  
  CHANGED_FILES=$(git diff --name-only HEAD~1 HEAD 2>/dev/null || echo "")
  echo "Changed files: $CHANGED_FILES"
  
  if echo "$CHANGED_FILES" | grep -q "Podfile.lock"; then
    MANAGERS="$MANAGERS CocoaPods"
    echo "✅ CocoaPods dependency changed"
  fi
  
  if echo "$CHANGED_FILES" | grep -q "Package.resolved"; then
    MANAGERS="$MANAGERS SPM"
    echo "✅ SPM dependency changed"
  fi

  # フォールバック: 差分で検出できない場合は存在チェックに切り替え
  if [[ -z "$MANAGERS" ]]; then
    echo "ℹ️ No dependency changes detected by diff; falling back to existence check..."
    if [[ -f "Podfile.lock" ]]; then
      MANAGERS="$MANAGERS CocoaPods"
      echo "📦 Found: Podfile.lock"
    fi
    if [[ -f "Package.resolved" ]] || find . -type f -name "Package.resolved" -print -quit | grep -q .; then
      MANAGERS="$MANAGERS SPM"
      echo "📦 Found: Package.resolved files"
    fi
  fi
fi

# ── 処理対象が無い場合は終了 ──
if [[ -z "$MANAGERS" ]]; then
  echo "🏁 No dependency managers found"
  exit 0
fi

echo "📦 Managers to process:$MANAGERS"

# ── Notion更新関数 ──
update_notion() {
  local project_name="$1"
  local package_manager="$2"
  local update_time="$3"
  
  echo "🔄 Processing: $project_name ($package_manager)"
  
  # 既存レコード検索
  search_filter="{\"filter\":{\"and\":[{\"property\":\"プロジェクト名\",\"title\":{\"equals\":\"$project_name\"}},{\"property\":\"パッケージマネージャー\",\"select\":{\"equals\":\"$package_manager\"}}]}}"
  
  search_response=$(curl -s -X POST "https://api.notion.com/v1/databases/${NOTION_DATABASE_ID}/query" \
    -H "Authorization: Bearer ${NOTION_TOKEN}" \
    -H "Notion-Version: 2022-06-28" \
    -H "Content-Type: application/json" \
    -d "$search_filter")
  
  page_id=$(echo "$search_response" | ruby -rjson -e "data=JSON.parse(STDIN.read); puts data['results'][0]['id'] if data['results'][0]" 2>/dev/null)
  
  # プロパティ作成
  properties="{\"プロジェクト名\":{\"title\":[{\"text\":{\"content\":\"$project_name\"}}]},\"パッケージマネージャー\":{\"select\":{\"name\":\"$package_manager\"}},\"更新日\":{\"date\":{\"start\":\"$update_time\"}}}"
  
  if [[ -n "$page_id" ]]; then
    echo "📝 Updating existing record..."
    update_payload="{\"properties\":$properties}"
    
    response=$(curl -s -X PATCH "https://api.notion.com/v1/pages/$page_id" \
      -H "Authorization: Bearer ${NOTION_TOKEN}" \
      -H "Notion-Version: 2022-06-28" \
      -H "Content-Type: application/json" \
      -d "$update_payload")
    
    if echo "$response" | grep -q '"object":"page"'; then
      echo "✅ Updated: $project_name ($package_manager)"
    else
      echo "❌ Update failed: $response"
      return 1
    fi
  else
    echo "📝 Creating new record..."
    create_payload="{\"parent\":{\"database_id\":\"$NOTION_DATABASE_ID\"},\"properties\":$properties}"
    
    response=$(curl -s -X POST "https://api.notion.com/v1/pages" \
      -H "Authorization: Bearer ${NOTION_TOKEN}" \
      -H "Notion-Version: 2022-06-28" \
      -H "Content-Type: application/json" \
      -d "$create_payload")
    
    if echo "$response" | grep -q '"object":"page"'; then
      echo "✅ Created: $project_name ($package_manager)"
    else
      echo "❌ Create failed: $response"
      return 1
    fi
  fi
  
  return 0
}

# ── 各マネージャーを処理 ──
echo "🚀 Updating Notion database..."
success_count=0
total_count=0

for manager in $MANAGERS; do
  [[ -z "$manager" ]] && continue
  
  total_count=$((total_count + 1))
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  
  if update_notion "$PROJECT_NAME" "$manager" "$now_iso"; then
    success_count=$((success_count + 1))
  fi
  
  echo ""
done

# ── 結果 ──
echo "📊 Results: $success_count/$total_count successful"

if [[ $success_count -eq $total_count ]]; then
  echo "🎉 All updates successful!"
  
  if [[ -n "${GITHUB_ACTIONS}" ]]; then
    echo "update-status=success" >> $GITHUB_OUTPUT
    echo "managers=$MANAGERS" >> $GITHUB_OUTPUT
  fi
else
  echo "💥 Some updates failed"
  
  if [[ -n "${GITHUB_ACTIONS}" ]]; then
    echo "update-status=failed" >> $GITHUB_OUTPUT
  fi
  
  exit 1
fi
