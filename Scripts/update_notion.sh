# GitHubでファイル内容を直接確認
echo "Current GitHub file: https://github.com/$(git config --get remote.origin.url | sed 's/.*github.com[:/]\([^/]*\/[^/]*\).*/\1/' | sed 's/\.git$//')/blob/main/Scripts/update_notion.sh"

# 完全に削除して新規作成
rm -f Scripts/update_notion.sh

# 最新版を確実に作成
cat > Scripts/update_notion.sh << 'SCRIPT_END'
#!/usr/bin/env bash
set -eo pipefail

: "${NOTION_TOKEN:?Need NOTION_TOKEN env var}"
: "${NOTION_DATABASE_ID:?Need NOTION_DATABASE_ID env var}"
: "${PROJECT_NAME:?Need PROJECT_NAME env var}"

echo "🔧 Project: ${PROJECT_NAME}"
echo "🌿 Branch: ${GITHUB_REF_NAME:-unknown}"
echo "🚀 Event: ${GITHUB_EVENT_NAME:-unknown}"

now_iso=$(date -u +%FT%TZ)
echo "🕐 Update Time (ISO): ${now_iso}"

MANAGERS=""

if [[ "${GITHUB_EVENT_NAME}" == "workflow_dispatch" ]]; then
  echo "🔍 Manual execution - checking current dependency files..."
  
  if [[ -f "Podfile.lock" ]]; then
    MANAGERS="$MANAGERS CocoaPods"
    echo "📦 Found: Podfile.lock"
  fi
  
  if find . -type f -name "Package.resolved" 2>/dev/null | head -1 >/dev/null; then
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
fi

if [[ -z "$MANAGERS" ]]; then
  echo "🏁 No dependency managers found"
  exit 0
fi

echo "📦 Managers detected:$MANAGERS"

# Multi_select JSON生成
managers_json="["
first=true
for manager in $MANAGERS; do
  [[ -z "$manager" ]] && continue
  
  if [[ "$first" == true ]]; then
    first=false
  else
    managers_json+=","
  fi
  
  managers_json+="{\"name\":\"$manager\"}"
done
managers_json+="]"

echo "📋 Multi-select JSON: $managers_json"

# 既存レコード検索
search_filter="{\"filter\":{\"property\":\"プロジェクト名\",\"title\":{\"equals\":\"$PROJECT_NAME\"}}}"

echo "🔍 Searching for existing project..."

search_response=$(curl -s -X POST "https://api.notion.com/v1/databases/${NOTION_DATABASE_ID}/query" \
  -H "Authorization: Bearer ${NOTION_TOKEN}" \
  -H "Notion-Version: 2022-06-28" \
  -H "Content-Type: application/json" \
  -d "$search_filter")

page_id=$(echo "$search_response" | ruby -rjson -e "data=JSON.parse(STDIN.read); puts data['results'][0]['id'] if data['results'][0]" 2>/dev/null)

echo "🔍 Found existing page ID: '$page_id'"

# プロパティ作成
properties="{\"プロジェクト名\":{\"title\":[{\"text\":{\"content\":\"$PROJECT_NAME\"}}]},\"パッケージマネージャー\":{\"multi_select\":$managers_json},\"更新日\":{\"date\":{\"start\":\"$now_iso\"}}}"

if [[ -n "$page_id" ]]; then
  echo "📝 Updating existing record..."
  
  response=$(curl -s -X PATCH "https://api.notion.com/v1/pages/$page_id" \
    -H "Authorization: Bearer ${NOTION_TOKEN}" \
    -H "Notion-Version: 2022-06-28" \
    -H "Content-Type: application/json" \
    -d "{\"properties\":$properties}")
  
  echo "Response: $response"
  
  if echo "$response" | grep -q '"object":"page"'; then
    echo "✅ Updated: $PROJECT_NAME [$MANAGERS]"
  else
    echo "❌ Update failed"
    exit 1
  fi
else
  echo "📝 Creating new record..."
  
  response=$(curl -s -X POST "https://api.notion.com/v1/pages" \
    -H "Authorization: Bearer ${NOTION_TOKEN}" \
    -H "Notion-Version: 2022-06-28" \
    -H "Content-Type: application/json" \
    -d "{\"parent\":{\"database_id\":\"$NOTION_DATABASE_ID\"},\"properties\":$properties}")
  
  echo "Response: $response"
  
  if echo "$response" | grep -q '"object":"page"'; then
    echo "✅ Created: $PROJECT_NAME [$MANAGERS]"
  else
    echo "❌ Create failed"
    exit 1
  fi
fi

echo "🎉 Successfully updated Notion database!"
SCRIPT_END

# 実行権限付与
chmod +x Scripts/update_notion.sh

# 確認
echo "=== Script verification ==="
echo "Lines: $(wc -l < Scripts/update_notion.sh)"
grep -q "Processing.*(" Scripts/update_notion.sh && echo "❌ Still has old pattern!" || echo "✅ No old pattern found"
grep -q "multi_select" Scripts/update_notion.sh && echo "✅ Has multi_select" || echo "❌ Missing multi_select"

# コミット
git add Scripts/update_notion.sh
git commit -m "Force update to multi_select version (simplified)"
git push
