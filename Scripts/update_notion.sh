#!/usr/bin/env bash
set -eo pipefail

# ── 環境変数チェック ──
: "${NOTION_TOKEN:?Need NOTION_TOKEN env var}"
: "${NOTION_DATABASE_ID:?Need NOTION_DATABASE_ID env var}"
: "${PROJECT_NAME:?Need PROJECT_NAME env var}"

echo "🔧 Project: ${PROJECT_NAME}"
echo "🌿 Branch: ${GITHUB_REF_NAME:-unknown}"
echo "🚀 Event: ${GITHUB_EVENT_NAME:-unknown}"

# ── 依存関係の変更検出（修正版） ──
detect_library_changes() {
  local library_types=""
  
  if [[ "${GITHUB_EVENT_NAME}" == "workflow_dispatch" ]]; then
    # ログメッセージを標準エラーに出力（戻り値に混入させない）
    echo "🔍 Manual execution - checking current dependency files..." >&2
    
    if [[ -f "Podfile.lock" ]]; then
      library_types="${library_types}CocoaPods,"
      echo "📦 Found: Podfile.lock" >&2
    fi
    
    if find . -name "Package.resolved" -type f | head -1 | read -r; then
      library_types="${library_types}SPM,"
      echo "📦 Found: Package.resolved files" >&2
    fi
    
    if [[ -z "$library_types" ]]; then
      echo "⚠️ No dependency files found" >&2
      exit 0
    fi
  else
    echo "🔍 Push event - detecting changed dependency files..." >&2
    
    CHANGED_FILES=$(git diff --name-only HEAD~1 HEAD 2>/dev/null || echo "")
    
    if [[ -z "$CHANGED_FILES" ]]; then
      echo "⚠️ No changed files detected" >&2
      exit 0
    fi
    
    echo "Changed files:" >&2
    echo "$CHANGED_FILES" | while read -r file; do
      [[ -n "$file" ]] && echo "  - $file" >&2
    done
    
    if echo "$CHANGED_FILES" | grep -q "^Podfile\.lock$"; then
      library_types="${library_types}CocoaPods,"
      echo "✅ CocoaPods dependency changed" >&2
    fi
    
    if echo "$CHANGED_FILES" | grep -q "Package\.resolved$"; then
      library_types="${library_types}SPM,"
      echo "✅ SPM dependency changed" >&2
    fi
    
    if [[ -z "$library_types" ]]; then
      echo "ℹ️ No dependency changes detected" >&2
      exit 0
    fi
  fi
  
  # 末尾のカンマを除去して標準出力に出力（戻り値として使用）
  library_types=${library_types%,}
  echo "$library_types"
}

LIBRARY_TYPES=$(detect_library_changes)

if [[ -z "$LIBRARY_TYPES" ]]; then
  echo "🏁 No dependency updates needed"
  exit 0
fi

echo "📦 Package Manager Types: ${LIBRARY_TYPES}"

now_iso=$(date -u +%FT%TZ)
now_jst=$(TZ='Asia/Tokyo' date '+%Y-%m-%d %H:%M:%S')
echo "🕐 Update Time: ${now_jst} (JST)"

# ── Notion API関数（修正版） ──
search_existing_project() {
  local project_name="$1"
  
  echo "🔍 Searching for existing project: ${project_name}"
  
  local filter_payload=$(cat <<JSON
{
  "filter": {
    "property": "プロジェクト名",
    "title": {
      "equals": "${project_name}"
    }
  }
}
JSON
  )
  
  echo "🔍 Search payload:"
  echo "$filter_payload"
  
  local response
  response=$(curl -s -X POST "https://api.notion.com/v1/databases/${NOTION_DATABASE_ID}/query" \
    -H "Authorization: Bearer ${NOTION_TOKEN}" \
    -H "Notion-Version: 2022-06-28" \
    -H "Content-Type: application/json" \
    -d "${filter_payload}")
  
  echo "🔍 Search response:"
  echo "$response"
  
  # レスポンスを戻り値として返す（二重出力を回避）
  echo "$response"
}

create_or_update_project() {
  local project_name="$1"
  local library_types="$2"
  local update_time_iso="$3"
  
  local search_result
  search_result=$(search_existing_project "$project_name")
  
  # レスポンスから最後の行（実際のJSONレスポンス）を取得
  local json_response
  json_response=$(echo "$search_result" | tail -n 1)
  
  echo "🔍 JSON response for processing:"
  echo "$json_response"
  
  local existing_page_id
  existing_page_id=$(echo "$json_response" | ruby -rjson -e "
    begin
      data = JSON.parse(STDIN.read)
      if data['results'] && data['results'].length > 0
        puts data['results'][0]['id']
      end
    rescue => e
      STDERR.puts \"Ruby error: #{e.message}\"
    end
  ")
  
  echo "🔍 Existing page ID: '${existing_page_id}'"
  
  local properties=$(cat <<JSON
{
  "プロジェクト名": { 
    "title": [{ "text": { "content": "${project_name}" } }] 
  },
  "パッケージマネージャー": { 
    "select": { "name": "${library_types}" } 
  },
  "更新日": { 
    "date": { "start": "${update_time_iso}" } 
  }
}
JSON
  )
  
  echo "📝 Properties to be used:"
  echo "$properties"
  
  if [[ -n "$existing_page_id" ]]; then
    echo "📝 Updating existing project..."
    
    local update_payload=$(cat <<JSON
{
  "properties": ${properties}
}
JSON
    )
    
    echo "📝 Update payload:"
    echo "$update_payload"
    
    local update_response
    update_response=$(curl -s -X PATCH "https://api.notion.com/v1/pages/${existing_page_id}" \
      -H "Authorization: Bearer ${NOTION_TOKEN}" \
      -H "Notion-Version: 2022-06-28" \
      -H "Content-Type: application/json" \
      -d "${update_payload}")
    
    echo "📝 Update response:"
    echo "$update_response"
    
    if echo "$update_response" | grep -q '"object":"page"'; then
      echo "✅ Updated: ${project_name} (${library_types})"
      return 0
    else
      echo "❌ Failed to update: ${project_name}"
      return 1
    fi
  else
    echo "📝 Creating new project..."
    
    local create_payload=$(cat <<JSON
{
  "parent": { "database_id": "${NOTION_DATABASE_ID}" },
  "properties": ${properties}
}
JSON
    )
    
    echo "📝 Create payload:"
    echo "$create_payload"
    
    local create_response
    create_response=$(curl -s -X POST https://api.notion.com/v1/pages \
      -H "Authorization: Bearer ${NOTION_TOKEN}" \
      -H "Notion-Version: 2022-06-28" \
      -H "Content-Type: application/json" \
      -d "${create_payload}")
    
    echo "📝 Create response:"
    echo "$create_response"
    
    if echo "$create_response" | grep -q '"object":"page"'; then
      echo "✅ Created: ${project_name} (${library_types})"
      return 0
    else
      echo "❌ Failed to create: ${project_name}"
      return 1
    fi
  fi
}

# ── Notion更新実行 ──
echo "🚀 Updating Notion database..."

if create_or_update_project "$PROJECT_NAME" "$LIBRARY_TYPES" "$now_iso"; then
  echo "🎉 Successfully updated Notion database!"
  
  if [[ -n "${GITHUB_ACTIONS}" ]]; then
    echo "update-status=success" >> $GITHUB_OUTPUT
    echo "project-name=$PROJECT_NAME" >> $GITHUB_OUTPUT
    echo "package-manager-types=$LIBRARY_TYPES" >> $GITHUB_OUTPUT
  fi
else
  echo "💥 Failed to update Notion database"
  
  if [[ -n "${GITHUB_ACTIONS}" ]]; then
    echo "update-status=failed" >> $GITHUB_OUTPUT
  fi
  
  exit 1
fi
