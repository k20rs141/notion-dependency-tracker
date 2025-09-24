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

# ── 依存関係の変更検出（個別処理版） ──
detect_dependency_changes() {
  local -a managers=()  # 配列として宣言
  
  if [[ "${GITHUB_EVENT_NAME}" == "workflow_dispatch" ]]; then
    echo "🔍 Manual execution - checking current dependency files..."
    
    if [[ -f "Podfile.lock" ]]; then
      managers+=("CocoaPods")
      echo "📦 Found: Podfile.lock"
    fi
    
    if find . -name "Package.resolved" -type f | head -1 | read -r; then
      managers+=("SPM")
      echo "📦 Found: Package.resolved files"
    fi
    
    if [[ ${#managers[@]} -eq 0 ]]; then
      echo "⚠️ No dependency files found"
      exit 0
    fi
  else
    echo "🔍 Push event - detecting changed dependency files..."
    
    CHANGED_FILES=$(git diff --name-only HEAD~1 HEAD 2>/dev/null || echo "")
    
    if [[ -z "$CHANGED_FILES" ]]; then
      echo "⚠️ No changed files detected"
      exit 0
    fi
    
    echo "Changed files:"
    echo "$CHANGED_FILES" | while read -r file; do
      [[ -n "$file" ]] && echo "  - $file"
    done
    
    if echo "$CHANGED_FILES" | grep -q "^Podfile\.lock$"; then
      managers+=("CocoaPods")
      echo "✅ CocoaPods dependency changed"
    fi
    
    if echo "$CHANGED_FILES" | grep -q "Package\.resolved$"; then
      managers+=("SPM")
      echo "✅ SPM dependency changed"
    fi
    
    if [[ ${#managers[@]} -eq 0 ]]; then
      echo "ℹ️ No dependency changes detected"
      exit 0
    fi
  fi
  
  # 配列を改行区切りで返す
  printf '%s\n' "${managers[@]}"
}

# ── Notion API関数 ──
search_existing_project() {
  local project_name="$1"
  local package_manager="$2"
  
  echo "🔍 Searching for existing project: ${project_name} (${package_manager})"
  
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
      STDERR.puts \"Ruby error: #{e.message}\"
    end
  ")
  
  echo "🔍 Existing page ID for ${package_manager}: '${existing_page_id}'"
  
  local properties=$(cat <<JSON
{
  "プロジェクト名": { 
    "title": [{ "text": { "content": "${project_name}" } }] 
  },
  "パッケージマネージャー": { 
    "select": { "name": "${package_manager}" } 
  },
  "更新日": { 
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
      echo "Response: $update_response"
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
      echo "Response: $create_response"
      return 1
    fi
  fi
}

# ── 依存関係管理ツールを個別に処理 ──
echo "🚀 Detecting dependency changes..."

# 変更された依存関係管理ツールを取得
readarray -t DEPENDENCY_MANAGERS < <(detect_dependency_changes)

if [[ ${#DEPENDENCY_MANAGERS[@]} -eq 0 ]]; then
  echo "🏁 No dependency updates needed"
  exit 0
fi

echo "📦 Found ${#DEPENDENCY_MANAGERS[@]} dependency manager(s): ${DEPENDENCY_MANAGERS[*]}"

# ── 各パッケージマネージャーを個別にNotionに登録 ──
echo "🚀 Updating Notion database..."

all_success=true
for manager in "${DEPENDENCY_MANAGERS[@]}"; do
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Processing: ${manager}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  
  if ! create_or_update_project "$PROJECT_NAME" "$manager" "$now_iso"; then
    all_success=false
  fi
  
  echo ""  # 空行で区切り
done

# ── 結果処理 ──
if $all_success; then
  echo "🎉 Successfully updated all ${#DEPENDENCY_MANAGERS[@]} dependency manager(s) in Notion!"
  
  if [[ -n "${GITHUB_ACTIONS}" ]]; then
    echo "update-status=success" >> $GITHUB_OUTPUT
    echo "project-name=$PROJECT_NAME" >> $GITHUB_OUTPUT
    echo "managers-count=${#DEPENDENCY_MANAGERS[@]}" >> $GITHUB_OUTPUT
    echo "managers=${DEPENDENCY_MANAGERS[*]}" >> $GITHUB_OUTPUT
  fi
else
  echo "💥 Some dependency managers failed to update"
  
  if [[ -n "${GITHUB_ACTIONS}" ]]; then
    echo "update-status=failed" >> $GITHUB_OUTPUT
  fi
  
  exit 1
fi
