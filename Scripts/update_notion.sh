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
now_jst=$(TZ='Asia/Tokyo' date '+%Y-%m-%d %H:%M:%S')
echo "🕐 Update Time: ${now_jst} (JST)"

# ── 依存関係の変更検出（シンプル版） ──
detect_dependency_changes() {
  local managers=""
  
  if [[ "${GITHUB_EVENT_NAME}" == "workflow_dispatch" ]]; then
    echo "🔍 Manual execution - checking current dependency files..."
    
    if [[ -f "Podfile.lock" ]]; then
      managers="${managers}CocoaPods "
      echo "📦 Found: Podfile.lock"
    fi
    
    if find . -name "Package.resolved" -type f 2>/dev/null | head -1 >/dev/null; then
      managers="${managers}SPM "
      echo "📦 Found: Package.resolved files"
    fi
  else
    echo "🔍 Push event - detecting changed dependency files..."
    
    CHANGED_FILES=$(git diff --name-only HEAD~1 HEAD 2>/dev/null || echo "")
    
    if [[ -z "$CHANGED_FILES" ]]; then
      echo "⚠️ No changed files detected"
      exit 0
    fi
    
    echo "Changed files:"
    echo "$CHANGED_FILES"
    
    if echo "$CHANGED_FILES" | grep -q "^Podfile\.lock$"; then
      managers="${managers}CocoaPods "
      echo "✅ CocoaPods dependency changed"
    fi
    
    if echo "$CHANGED_FILES" | grep -q "Package\.resolved$"; then
      managers="${managers}SPM "
      echo "✅ SPM dependency changed"
    fi
  fi
  
  # スペース区切りで出力（余計な処理を避ける）
  echo "${managers}"
}

# ── Notion API関数 ──
search_existing_project() {
  local project_name="$1"
  local package_manager="$2"
  
  local filter_payload=$(cat <<JSON
{
  "filter": {
    "and": [
      {
        "property": "プロジェクト名",
        "title": {
          "equals": "${project_name}"
        }
      },
      {
        "property": "パッケージマネージャー",
        "select": {
          "equals": "${package_manager}"
        }
      }
    ]
  }
}
JSON
  )
  
  curl -s -X POST "https://api.notion.com/v1/databases/${NOTION_DATABASE_ID}/query" \
    -H "Authorization: Bearer ${NOTION_TOKEN}" \
    -H "Notion-Version: 2022-06-28" \
    -H "Content-Type: application/json" \
    -d "${filter_payload}"
}

create_or_update_project() {
  local project_name="$1"
  local package_manager="$2"
  local update_time_iso="$3"
  
  echo "🔍 Processing: ${project_name} (${package_manager})"
  
  local search_result
  search_result=$(search_existing_project "$project_name" "$package_manager")
  
  local existing_page_id
  existing_page_id=$(echo "$search_result" | ruby -rjson -e "
    begin
      data = JSON.parse(STDIN.read)
      if data['results'] && data['results'].length > 0
        puts data['results'][0]['id']
      end
    rescue => e
      # エラー時は何もしない（新規作成）
    end
  ")
  
  local properties=$(cat <<JSON
{
  "プロジェクト名": { 
    "title": [{ "text": { "content": "${project_name}" } }] 
  },
  "パッケージマネージャー": { 
    "select": { "name": "${package_manager}" } 
  },
  "更新日時": { 
    "date": { "start": "${update_time_iso}" } 
  }
}
JSON
  )
  
  if [[ -n "$existing_page_id" ]]; then
    echo "📝 Updating existing project: ${project_name} (${package_manager})"
    
    local update_payload=$(cat <<JSON
{
  "properties": ${properties}
}
JSON
    )
    
    local update_response
    update_response=$(curl -s -X PATCH "https://api.notion.com/v1/pages/${existing_page_id}" \
      -H "Authorization: Bearer ${NOTION_TOKEN}" \
      -H "Notion-Version: 2022-06-28" \
      -H "Content-Type: application/json" \
      -d "${update_payload}")
    
    if echo "$update_response" | grep -q '"object":"page"'; then
      echo "✅ Updated: ${project_name} (${package_manager})"
      return 0
    else
      echo "❌ Failed to update: ${project_name} (${package_manager})"
      echo "Error: $update_response"
      return 1
    fi
  else
    echo "📝 Creating new project: ${project_name} (${package_manager})"
    
    local create_payload=$(cat <<JSON
{
  "parent": { "database_id": "${NOTION_DATABASE_ID}" },
  "properties": ${properties}
}
JSON
    )
    
    local create_response
    create_response=$(curl -s -X POST https://api.notion.com/v1/pages \
      -H "Authorization: Bearer ${NOTION_TOKEN}" \
      -H "Notion-Version: 2022-06-28" \
      -H "Content-Type: application/json" \
      -d "${create_payload}")
    
    if echo "$create_response" | grep -q '"object":"page"'; then
      echo "✅ Created: ${project_name} (${package_manager})"
      return 0
    else
      echo "❌ Failed to create: ${project_name} (${package_manager})"
      echo "Error: $create_response"
      return 1
    fi
  fi
}

# ── メイン処理 ──
echo "🚀 Detecting dependency changes..."

managers_output=$(detect_dependency_changes)

if [[ -z "$managers_output" ]]; then
  echo "🏁 No dependency updates needed"
  exit 0
fi

echo "📦 Found dependency managers: ${managers_output}"

# ── 各パッケージマネージャーを個別に処理 ──
echo "🚀 Updating Notion database..."

all_success=true

# スペース区切りの文字列を配列のように処理
for manager in $managers_output; do
  [[ -z "$manager" ]] && continue
  
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  
  if ! create_or_update_project "$PROJECT_NAME" "$manager" "$now_iso"; then
    all_success=false
  fi
  
  echo ""
done

# ── 結果処理 ──
if $all_success; then
  echo "🎉 Successfully updated Notion database!"
  
  if [[ -n "${GITHUB_ACTIONS}" ]]; then
    echo "update-status=success" >> $GITHUB_OUTPUT
    echo "project-name=$PROJECT_NAME" >> $GITHUB_OUTPUT
    echo "managers=$managers_output" >> $GITHUB_OUTPUT
  fi
else
  echo "💥 Some updates failed"
  
  if [[ -n "${GITHUB_ACTIONS}" ]]; then
    echo "update-status=failed" >> $GITHUB_OUTPUT
  fi
  
  exit 1
fi
