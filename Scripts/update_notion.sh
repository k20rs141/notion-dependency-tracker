#!/usr/bin/env bash
set -eo pipefail

# ── 環境変数チェック ──
: "${NOTION_TOKEN:?Need NOTION_TOKEN env var}"
: "${NOTION_DATABASE_ID:?Need NOTION_DATABASE_ID env var}"
: "${PROJECT_NAME:?Need PROJECT_NAME env var}"

echo "🔧 Project: ${PROJECT_NAME}"
echo "🌿 Branch: ${GITHUB_REF_NAME:-unknown}"

# ── 依存関係ファイルの実際の場所を検出 ──
detect_dependency_changes() {
  local library_types=""
  
  # GitHubActionsの場合は変更されたファイルから検出
  if [[ -n "${GITHUB_ACTIONS}" ]]; then
    echo "🔍 Detecting dependency changes from Git diff..."
    
    CHANGED_FILES=$(git diff --name-only HEAD~1 HEAD 2>/dev/null || echo "")
    
    echo "Changed files:"
    echo "$CHANGED_FILES" | while read -r file; do
      [[ -n "$file" ]] && echo "  - $file"
    done
    
    if echo "$CHANGED_FILES" | grep -q "Podfile.lock"; then
      library_types="${library_types}CocoaPods,"
      echo "📦 Found CocoaPods changes (Podfile.lock)"
    fi
    
    if echo "$CHANGED_FILES" | grep -q "Package.resolved"; then
      library_types="${library_types}SPM,"
      echo "📦 Found SPM changes (Package.resolved)"
    fi
  else
    # ローカル実行時は実際にファイルの存在を確認
    echo "🔍 Checking for dependency files..."
    
    if [[ -f "Podfile.lock" ]]; then
      library_types="${library_types}CocoaPods,"
      echo "📦 Found Podfile.lock"
    fi
    
    # Package.resolvedファイルを検索
    if find . -name "Package.resolved" -type f 2>/dev/null | head -1 | read -r; then
      library_types="${library_types}SPM,"
      echo "📦 Found Package.resolved files:"
      find . -name "Package.resolved" -type f 2>/dev/null | while read -r file; do
        echo "  - $file"
      done
    fi
  fi
  
  # 末尾のカンマを除去
  library_types=${library_types%,}
  
  if [[ -z "$library_types" ]]; then
    echo "ℹ️ No dependency changes detected"
    exit 0
  fi
  
  echo "$library_types"
}

# ── メイン処理 ──
echo "🚀 Starting dependency detection..."

LIBRARY_TYPES=$(detect_dependency_changes)

if [[ -z "$LIBRARY_TYPES" ]]; then
  echo "🏁 No dependency updates needed"
  exit 0
fi

echo "📦 Library Types: ${LIBRARY_TYPES}"

# ── 現在時刻 ──
now_iso=$(date -u +%FT%TZ)
now_jst=$(TZ='Asia/Tokyo' date '+%Y-%m-%d %H:%M:%S')
echo "🕐 Update Time: ${now_jst} (JST)"

# ── Notion API関数（前回と同じ） ──
search_existing_project() {
  local project_name="$1"
  
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
  
  curl -s -X POST "https://api.notion.com/v1/databases/${NOTION_DATABASE_ID}/query" \
    -H "Authorization: Bearer ${NOTION_TOKEN}" \
    -H "Notion-Version: 2022-06-28" \
    -H "Content-Type: application/json" \
    -d "${filter_payload}"
}

create_or_update_project() {
  local project_name="$1"
  local library_types="$2"
  local update_time_iso="$3"
  
  echo "🔍 Searching for existing project: ${project_name}"
  
  local search_result
  search_result=$(search_existing_project "$project_name")
  
  local existing_page_id
  existing_page_id=$(echo "$search_result" | ruby -rjson -e "
    begin
      data = JSON.parse(STDIN.read)
      if data['results'] && data['results'].length > 0
        puts data['results'][0]['id']
      end
    rescue => e
      # 新規作成として処理
    end
  ")
  
  local properties=$(cat <<JSON
{
  "プロジェクト名": { 
    "title": [{ "text": { "content": "${project_name}" } }] 
  },
  "ライブラリ": { 
    "rich_text": [{ "text": { "content": "${library_types}" } }] 
  },
  "更新日": { 
    "date": { "start": "${update_time_iso}" } 
  }
}
JSON
  )
  
  if [[ -n "$existing_page_id" ]]; then
    echo "📝 Updating existing project..."
    
    local update_payload=$(cat <<JSON
{
  "properties": ${properties}
}
JSON
    )
    
    if curl -f -s -X PATCH "https://api.notion.com/v1/pages/${existing_page_id}" \
      -H "Authorization: Bearer ${NOTION_TOKEN}" \
      -H "Notion-Version: 2022-06-28" \
      -H "Content-Type: application/json" \
      -d "${update_payload}" > /dev/null; then
      echo "✅ Updated project: ${project_name} (${library_types})"
      return 0
    else
      echo "❌ Failed to update project: ${project_name}"
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
    
    if curl -f -s -X POST https://api.notion.com/v1/pages \
      -H "Authorization: Bearer ${NOTION_TOKEN}" \
      -H "Notion-Version: 2022-06-28" \
      -H "Content-Type: application/json" \
      -d "${create_payload}" > /dev/null; then
      echo "✅ Created project: ${project_name} (${library_types})"
      return 0
    else
      echo "❌ Failed to create project: ${project_name}"
      return 1
    fi
  fi
}

# ── Notion更新実行 ──
if create_or_update_project "$PROJECT_NAME" "$LIBRARY_TYPES" "$now_iso"; then
  echo "🎉 Successfully updated Notion database!"
  
  if [[ -n "${GITHUB_ACTIONS}" ]]; then
    echo "update-status=success" >> $GITHUB_OUTPUT
    echo "project-name=$PROJECT_NAME" >> $GITHUB_OUTPUT
    echo "library-types=$LIBRARY_TYPES" >> $GITHUB_OUTPUT
  fi
else
  echo "💥 Failed to update Notion database"
  
  if [[ -n "${GITHUB_ACTIONS}" ]]; then
    echo "update-status=failed" >> $GITHUB_OUTPUT
  fi
  
  exit 1
fi
