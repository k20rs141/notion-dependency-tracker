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

echo "📦 Managers detected:$MANAGERS"

# ── Multi_select用のJSON配列生成 ──
generate_multi_select_json() {
  local managers_string="$1"
  local json_array="["
  local first=true
  
  for manager in $managers_string; do
    [[ -z "$manager" ]] && continue
    
    if [[ "$first" == true ]]; then
      first=false
    else
      json_array+=","
    fi
    
    json_array+="{\"name\":\"$manager\"}"
  done
  
  json_array+="]"
  echo "$json_array"
}

# ── Notion更新関数（Multi_select対応版） ──
update_notion() {
  local project_name="$1"
  local managers_string="$2"
  local update_time="$3"
  
  echo "🔄 Processing: $project_name"
  echo "📦 Managers: [$managers_string]"
  
  # 既存レコード検索（プロジェクト名のみで検索）
  search_filter="{\"filter\":{\"property\":\"プロジェクト名\",\"title\":{\"equals\":\"$project_name\"}}}"
  
  echo "🔍 Searching for existing project..."
  
  search_response=$(curl -s -X POST "https://api.notion.com/v1/databases/${NOTION_DATABASE_ID}/query" \
    -H "Authorization: Bearer ${NOTION_TOKEN}" \
    -H "Notion-Version: 2022-06-28" \
    -H "Content-Type: application/json" \
    -d "$search_filter")
  
  page_id=$(echo "$search_response" | ruby -rjson -e "data=JSON.parse(STDIN.read); puts data['results'][0]['id'] if data['results'][0]" 2>/dev/null)
  
  echo "🔍 Found existing page ID: '$page_id'"
  
  # Multi_select用のJSON配列を生成
  multi_select_array=$(generate_multi_select_json "$managers_string")
  echo "📋 Multi-select array: $multi_select_array"
  
  # プロパティ作成（Multi_select対応）
  properties="{\"プロジェクト名\":{\"title\":[{\"text\":{\"content\":\"$project_name\"}}]},\"パッケージマネージャー\":{\"multi_select\":$multi_select_array},\"更新日\":{\"date\":{\"start\":\"$update_time\"}}}"
  
  echo "📝 Properties JSON:"
  echo "$properties"
  
  if [[ -n "$page_id" ]]; then
    echo "📝 Updating existing record..."
    update_payload="{\"properties\":$properties}"
    
    response=$(curl -s -X PATCH "https://api.notion.com/v1/pages/$page_id" \
      -H "Authorization: Bearer ${NOTION_TOKEN}" \
      -H "Notion-Version: 2022-06-28" \
      -H "Content-Type: application/json" \
      -d "$update_payload")
    
    echo "📝 Update response:"
    echo "$response"
    
    if echo "$response" | grep -q '"object":"page"'; then
      echo "✅ Updated: $project_name [$managers_string]"
    else
      echo "❌ Update failed"
      return 1
    fi
  else
    echo "📝 Creating new record..."
    create_payload="{\"parent\":{\"database_id\":\"$NOTION_DATABASE_ID\"},\"properties\":$properties}"
    
    echo "📝 Create payload:"
    echo "$create_payload"
    
    response=$(curl -s -X POST "https://api.notion.com/v1/pages" \
      -H "Authorization: Bearer ${NOTION_TOKEN}" \
      -H "Notion-Version: 2022-06-28" \
      -H "Content-Type: application/json" \
      -d "$create_payload")
    
    echo "📝 Create response:"
    echo "$response"
    
    if echo "$response" | grep -q '"object":"page"'; then
      echo "✅ Created: $project_name [$managers_string]"
    else
      echo "❌ Create failed"
      return 1
    fi
  fi
  
  return 0
}

# ── プロジェクトを更新（1つのレコードで複数マネージャー対応） ──
echo "🚀 Updating Notion database..."

if update_notion "$PROJECT_NAME" "$MANAGERS" "$now_iso"; then
  echo "🎉 Successfully updated Notion database!"
  
  if [[ -n "${GITHUB_ACTIONS}" ]]; then
    echo "update-status=success" >> $GITHUB_OUTPUT
    echo "project-name=$PROJECT_NAME" >> $GITHUB_OUTPUT
    echo "managers=$MANAGERS" >> $GITHUB_OUTPUT
  fi
else
  echo "💥 Update failed"
  
  if [[ -n "${GITHUB_ACTIONS}" ]]; then
    echo "update-status=failed" >> $GITHUB_OUTPUT
  fi
  
  exit 1
fi