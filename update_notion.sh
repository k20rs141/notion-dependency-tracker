#!/usr/bin/env bash
set -eo pipefail

# ── (A) 必須環境変数チェック ──
# sourceコマンドで読み込まれる secrets.sh で設定されていることを期待
: "${NOTION_TOKEN:?Need NOTION_TOKEN env var}"
: "${NOTION_DATABASE_ID:?Need NOTION_DATABASE_ID env var}"

# ── (B) プロジェクトルートに移動 と チェックサム確認 ──
cd "${SRCROOT:-.}" || exit 1

readonly CACHE_FILE="Scripts/.update_notion.cache"

# 依存ファイルからチェックサムを生成
# Package.resolved はパスが変わる可能性があるため find で探す
package_resolved_path=$(find . -path "*/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" | head -n 1)
current_checksum=""
if [[ -f "Podfile.lock" ]]; then
  current_checksum+=$(md5 -q "Podfile.lock")
fi
if [[ -f "$package_resolved_path" ]]; then
  current_checksum+=$(md5 -q "$package_resolved_path")
fi

# 前回のチェックサムと比較
if [[ -f "$CACHE_FILE" ]] && [[ "$(cat "$CACHE_FILE")" == "$current_checksum" ]]; then
  echo "INFO: Dependencies have not changed. Skipping Notion update."
  exit 0
fi

# ── (A-2) Notion データベースのプロパティ構造を取得 ──
get_database_properties() {
  curl -s -X GET "https://api.notion.com/v1/databases/${NOTION_DATABASE_ID}" \
    -H "Authorization: Bearer ${NOTION_TOKEN}" \
    -H "Notion-Version: 2022-06-28"
}

# ── (A-3) 既存のページを検索する関数 ──
search_existing_page() {
  local library_name="$1"
  local manager="$2"
  
  # ライブラリ名とパッケージマネージャーで既存ページを検索
  local filter_payload=$(cat <<JSON
{
  "filter": {
    "and": [
      {
        "property": "ライブラリ名",
        "title": {
          "equals": "${library_name}"
        }
      },
      {
        "property": "パッケージマネージャー",
        "select": {
          "equals": "${manager}"
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

# ── (C) Podfile.lock から CocoaPods ライブラリを抽出（メインライブラリのみ） ──
pods=()

if [[ -f "Podfile.lock" ]]; then
  while read -r line; do
    # メインライブラリのみ抽出: "  - Adjust (5.4.0):"
    # コロン(:)で終わる行のみを対象とし、入れ子の依存関係は無視
    if [[ $line =~ ^[[:space:]]*-[[:space:]]+([^[:space:]]+)[[:space:]]+\(([^\)]+)\):$ ]]; then
      pods+=( "${BASH_REMATCH[1]},${BASH_REMATCH[2]},CocoaPods" )
    fi
  done < <(awk '/^PODS:/{flag=1;next}/^DEPENDENCIES:/{flag=0}flag' Podfile.lock)
fi

# ── (D) Package.resolved から SwiftPM ライブラリを抽出 ──
spm=()

# `Package.resolved`がファイルとして存在するかチェック
if [[ -f "$package_resolved_path" ]]; then
  # Xcodeのビルド環境ではrubyのパスが通っていない可能性を考慮し、フルパスで指定します。
  # また、エラー発生時に詳細が出力されるように、Rubyスクリプト内にエラーハンドリングを追加します。
  output=$(/usr/bin/ruby -rjson -e "
    begin
      data = JSON.parse(File.read('$package_resolved_path'))
      # 'pins' (v2) または 'objects' (v1) に対応
      (data['pins'] || data['objects']).each do |pin|
        name    = pin['identity'] || pin['package']
        version = pin['state']['version'] || (pin['state']['revision'] ? pin['state']['revision'][0, 7] : 'N/A')
        puts \"#{name},#{version},SwiftPM\"
      end
    rescue => e
      STDERR.puts \"Ruby Error: Failed to parse Package.resolved. #{e.message}\"
      exit 1
    end
  " 2>&1)
  exit_code=$?

  if [[ $exit_code -eq 0 ]]; then
    # Rubyスクリプトの出力を改行区切りで配列に格納
    while IFS= read -r line; do
      # 空行は追加しない
      if [[ -n "$line" ]]; then
        spm+=("$line")
      fi
    done <<< "$output"
  else
    # エラーが発生した場合はログに出力
    echo "⚠️ Error processing SwiftPM packages:"
    echo "${output}"
  fi
else
  echo "⚠️ Warning: Package.resolved was not found. Skipping SwiftPM libraries."
fi

# ── (E) ライブラリ情報の作成・更新処理 ──
create_or_update_library() {
  local name="$1"
  local version="$2"
  local manager="$3"
  local now_iso="$4"
  
  # 既存のページを検索
  local search_result
  search_result=$(search_existing_page "$name" "$manager")
  local existing_page_id
  existing_page_id=$(echo "$search_result" | /usr/bin/ruby -rjson -e "
    begin
      data = JSON.parse(STDIN.read)
      if data['results'] && data['results'].length > 0
        puts data['results'][0]['id']
      end
    rescue => e
      # エラーの場合は何も出力しない（新規作成として扱う）
    end
  ")
  
  # プロパティの構築
  local properties=$(cat <<JSON
{
  "ライブラリ名": { "title": [{ "text": { "content": "${name}" } }] },
  "バージョン": { "rich_text": [{ "text": { "content": "${version}" } }] },
  "パッケージマネージャー": { "select": { "name": "${manager}" } },
  "更新日時": { "date": { "start": "${now_iso}" } }
}
JSON
  )
  
  if [[ -n "$existing_page_id" ]]; then
    # 既存ページの更新
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
      echo "✅ Updated: ${name}@${version} (${manager})"
      return 0
    else
      echo "⚠️ Failed to update: ${name}@${version}"
      return 1
    fi
  else
    # 新規ページの作成
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
      echo "✅ Created: ${name}@${version} (${manager})"
      return 0
    else
      echo "⚠️ Failed to create: ${name}@${version}"
      return 1
    fi
  fi
}

# ── (F) Notion に登録 ──
all_success=true
now_iso=$(date -u +%FT%TZ)

echo "📦 Processing all libraries..."
for entry in "${pods[@]}" "${spm[@]}"; do
  IFS=',' read -r name version manager <<< "$entry"
  if [[ -z "$name" ]]; then continue; fi

  if ! create_or_update_library "$name" "$version" "$manager" "$now_iso"; then
    all_success=false
  fi
done

if $all_success; then
  echo "INFO: Successfully updated all libraries to Notion."
  echo "$current_checksum" > "$CACHE_FILE"
else
  echo "ERROR: One or more libraries failed to update to Notion. Check logs for details."
  # 失敗した場合はキャッシュを更新しないので、次回ビルド時に再実行される
  exit 1
fi
