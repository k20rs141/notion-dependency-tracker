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

または、`Scripts/secrets.sh` ファイルに記述して source で読み込むことも可能です：

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

Xcode プロジェクトの Build Phases に「Run Script」を追加：

```bash
source "${SRCROOT}/Scripts/secrets.sh"
"${SRCROOT}/Scripts/update_notion.sh"
```

## 機能詳細

### 1. 依存関係の抽出

#### CocoaPods (Podfile.lock)
- メインライブラリとそのバージョンを抽出
- コロン(:)で終わる行のみを対象とし、入れ子の依存関係は無視
- 例：`- Adjust (5.4.0):` のような形式のライブラリのみを取得

#### SwiftPM (Package.resolved)
- パッケージ名とバージョン（またはコミットハッシュ）を抽出
- JSON形式のファイルを Ruby で解析

### 2. 重複チェックと更新

- ライブラリ名 + パッケージマネージャーの組み合わせで既存レコードを検索
- 既存の場合：バージョンと更新日時のみ更新
- 新規の場合：新しいレコードを作成

### 3. キャッシュ機能

- Podfile.lock と Package.resolved のチェックサムを計算
- 前回実行時と変更がない場合はスキップ
- ビルド時間の短縮に貢献

### 4. エラーハンドリング

- Notion API のエラーを適切にキャッチ
- 一部のライブラリで失敗しても他の処理は継続
- 詳細なログ出力

## トラブルシューティング

### よくある問題

1. **Notion API エラー**
   - トークンが正しく設定されているか確認
   - データベース ID が正しいか確認
   - Integration がデータベースにアクセス権限を持っているか確認

2. **Ruby エラー**
   - macOS の標準 Ruby を使用（/usr/bin/ruby）
   - Package.resolved の JSON 形式が正しいか確認

3. **権限エラー**
   - スクリプトファイルに実行権限があるか確認：`chmod +x Scripts/update_notion.sh`

### ログの確認

スクリプトは以下のような出力を行います：

```
📦 Processing all libraries...
✅ Updated: Alamofire@5.10.2 (CocoaPods)
✅ Created: NewLibrary@1.0.0 (CocoaPods)
✅ Updated: SwiftProtobuf@1.29.0 (SwiftPM)
INFO: Successfully updated all libraries to Notion.
```

## ライセンス

このスクリプトは MIT ライセンスの下で提供されています。

## 貢献

バグ報告や機能追加の提案は、プロジェクトの Issue で受け付けています。
