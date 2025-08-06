# Notion ライブラリ管理スクリプト

このスクリプトは、iOS プロジェクトで使用している CocoaPods および SwiftPM ライブラリの情報を自動的に Notion データベースに同期するためのツールです。

## 概要

- **Podfile.lock** と **Package.resolved** を解析
- ライブラリ名、バージョン、パッケージマネージャーを抽出
- Notion データベースに自動登録・更新
- 既存レコードの重複を避けて効率的に更新
- 依存関係に変更がない場合はスキップ（キャッシュ機能）

## Notionの設定

NotionAPIを利用するにはIntegrationやAPI Secretの設定が必要。以下を参考に！
https://developers.notion.com/docs/create-a-notion-integration


## 必要な環境変数

スクリプトを実行する前に、以下の環境変数を設定する必要があります：

```bash
export NOTION_TOKEN="your_notion_integration_token"
export NOTION_DATABASE_ID="your_database_id"
```

セキュリティのため、これらの変数は `Scripts/secrets.sh` ファイルに記述し、`.gitignore` に追加してリポジトリに含めないようにすることを推奨します。

```bash
# Scripts/secrets.sh
export NOTION_TOKEN="your_notion_integration_token"
export NOTION_DATABASE_ID="your_database_id"
```

## Notion データベースの設定

このスクリプトを使用するには、Notion データベースに以下のプロパティが必要です：

### 必須プロパティ

| プロパティ名 | タイプ | 説明 |
|-------------|--------|------|
| ライブラリ名 | Title | ライブラリの名前（主キー） |
| バージョン | Rich text | ライブラリのバージョン情報 |
| パッケージマネージャー | Select | "CocoaPods" または "SwiftPM" |
| 更新日時 | Date | 最後に更新された日時 |

### Select プロパティの設定

「パッケージマネージャー」プロパティには以下のオプションを設定してください：
- CocoaPods
- SwiftPM

## 使用方法

### 手動実行

```bash
cd /path/to/your/project
source Scripts/secrets.sh  # 環境変数を読み込み
./Scripts/update_notion.sh
```

### Xcode Build Phase での自動実行

Xcode プロジェクトの **Build Phases** にある `[CP] Check Pods Manifest.lock` の直後に新しい「Run Script Phase」を追加し、以下のスクリプトを記述します。

```bash
# 環境変数を読み込む
if [ -f "${SRCROOT}/Scripts/secrets.sh" ]; then
  source "${SRCROOT}/Scripts/secrets.sh"
fi

# スクリプトを実行する
"${SRCROOT}/Scripts/update_notion.sh"
```

この設定により、ビルド時にライブラリの依存関係が解決された後で、自動的にNotionが更新されます。

## 機能詳細

### 1. 依存関係の抽出

#### CocoaPods (Podfile.lock)
- メインライブラリとそのバージョンを抽出します。
- 入れ子の依存関係は無視されます。

#### SwiftPM (Package.resolved)
- パッケージ名とバージョン（またはコミットハッシュ）を抽出します。

### 2. 重複チェックと更新

- 「ライブラリ名」と「パッケージマネージャー」の組み合わせで、Notion上の既存レコードを検索します。
- 既存の場合はバージョンと更新日時を更新し、新規の場合はレコードを作成します。

### 3. キャッシュ機能 (`.update_notion.cache`)

- スクリプトは、`Podfile.lock` と `Package.resolved` の内容からチェックサム（ファイルの内容を要約した文字列）を生成します。
- Notionへの更新が成功すると、このチェックサムを `Scripts/.update_notion.cache` というファイルに保存します。このファイルは、**初回実行時に自動で作成されます**。
- 2回目以降の実行時には、まずこのキャッシュファイルに保存された前回のチェックサムと、現在の依存関係から生成した新しいチェックサムを比較します。
- チェックサムが同じであれば、ライブラリに変更はないと判断し、Notionへの更新処理をスキップしてビルド時間を短縮します。
- なお、この `.update_notion.cache` ファイルは `.gitignore` に登録されているため、Gitリポジトリには含まれません。

### 4. エラーハンドリング

- Notion APIとの通信エラーや、ファイルの解析エラーを検知し、ログに出力します。
- スクリプトが失敗した場合は、キャッシュが更新されないため、次回のビルドで再実行されます。

## トラブルシューティング

### よくある問題

1. **Notion API エラー**:
   - `NOTION_TOKEN` と `NOTION_DATABASE_ID` が `secrets.sh` に正しく設定されているか確認してください。
   - Notionインテグレーションが対象のデータベースに対して適切な権限（読み取り、書き込み）を持っているか確認してください。

2. **Ruby エラー**:
   - スクリプトはmacOS標準のRuby (`/usr/bin/ruby`) を使用します。
   - `Package.resolved` ファイルのJSON形式が破損していないか確認してください。

3. **権限エラー**:
   - スクリプトに実行権限が付与されているか確認してください (`chmod +x Scripts/update_notion.sh`)。

### ログの確認

Xcodeのビルドログや、手動実行時のターミナル出力で、以下のようなログを確認できます。

```
📦 Processing all libraries...
✅ Updated: Alamofire@5.10.2 (CocoaPods)
✅ Created: NewLibrary@1.0.0 (CocoaPods)
✅ Updated: SwiftProtobuf@1.29.0 (SwiftPM)
INFO: Successfully updated all libraries to Notion.
```
