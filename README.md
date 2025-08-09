# ConversationRelay Service for Cloud Run

WebSocket ConversationRelay サービスと TwiML エンドポイントを併設した Node.js アプリケーション。Cloud Run に「ソースから」デプロイ可能な最小構成です。

## 概要

このサービスは以下の機能を提供します：
- Twilio ConversationRelay 用の WebSocket サーバー
- TwiML レスポンスを返す HTTP エンドポイント
- OpenAI API を使用した AI 会話処理（ストリーミング対応）
- Cloud Run での長時間接続をサポート（Keepalive 実装済み）
- 会話履歴の管理と文脈を考慮した応答生成

## プロジェクト構成

```
conversationRelay-on-CloudRun/
├── server.js           # メインサーバーファイル
├── package.json        # Node.js 依存関係
├── .env               # 環境変数設定（要編集、Git除外対象）
├── .env.example       # 環境変数テンプレート
├── .gitignore         # Git除外設定
├── .gcloudignore      # Cloud Run デプロイ除外設定
├── scripts/           # デプロイ・管理用スクリプト
│   ├── setup-secrets.sh        # Secret Manager 設定
│   ├── deploy.sh               # デプロイコマンド生成
│   └── manage-service.sh       # サービス管理 (on/off/toggle/status)
└── README.md          # このファイル
```

## 必要な GCP API の有効化

```bash
# Cloud Run API
gcloud services enable run.googleapis.com

# Cloud Build API（ソースからのデプロイに必要）
gcloud services enable cloudbuild.googleapis.com

# Artifact Registry API（ビルドイメージの保存に必要）
gcloud services enable artifactregistry.googleapis.com
```

## 環境変数

| 変数名 | 説明 | デフォルト値 |
|--------|------|-------------|
| `PORT` | サーバーのリスニングポート | `8080` |
| `WS_PATH` | WebSocket のパス | `/relay` |
| `CR_LANGUAGE` | ConversationRelay の言語設定 | `ja-JP` |
| `CR_TTS_PROVIDER` | TTS プロバイダー | `google` |
| `CR_VOICE` | TTS 音声設定 | `ja-JP-Standard-B` |
| `CR_WELCOME` | ウェルカムメッセージ | `もしもし。こんにちは。こちらはAIオペレーターです。なんでもご相談ください。` |
| `WSS_URL` | WebSocket URL（指定しない場合は自動生成） | - |
| `WEBHOOK_VALIDATE` | Twilio Webhook 署名検証の有効化 | `false` |
| `TWILIO_AUTH_TOKEN` | Twilio Auth Token（署名検証時に必須） | - |
| `OPENAI_API_KEY` | OpenAI API キー | - |
| `SYSTEM_PROMPT` | AI アシスタントのシステムプロンプト | `あなたは親切で丁寧な日本語の電話オペレーターです。簡潔で自然な会話を心がけてください。` |

## デプロイ

### 方法 1: 自動デプロイスクリプトを使用（推奨）

#### 1. 環境変数を .env ファイルに設定

```bash
# .env.example をコピーして .env ファイルを作成
cp .env.example .env

# .env ファイルを編集して API キーなどを設定
vi .env
```

#### 2. Secret Manager の設定

```bash
# Secret Manager API を有効化し、シークレットを作成
./scripts/setup-secrets.sh
```

#### 3. デプロイコマンドの生成と実行

```bash
# デプロイコマンドを生成
./scripts/deploy.sh

# 生成されたコマンドをコピーして実行
```

### 方法 2: 手動デプロイ

#### 1. 必要な API の有効化

```bash
# Secret Manager API（シークレット管理用）
gcloud services enable secretmanager.googleapis.com
```

#### 2. Secret の作成

```bash
# プロジェクト番号を取得
PROJECT_NUMBER=$(gcloud projects describe "$(gcloud config get-value project)" --format="value(projectNumber)")

# OpenAI API キーを Secret として保存
echo -n "your-openai-api-key" | gcloud secrets create OPENAI_API_KEY --data-file=-

# Twilio Auth Token を Secret として保存
echo -n "your-twilio-auth-token" | gcloud secrets create TWILIO_AUTH_TOKEN --data-file=-

# Secret へのアクセス権限を付与
gcloud secrets add-iam-policy-binding OPENAI_API_KEY \
  --member=serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com \
  --role=roles/secretmanager.secretAccessor

gcloud secrets add-iam-policy-binding TWILIO_AUTH_TOKEN \
  --member=serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com \
  --role=roles/secretmanager.secretAccessor
```

#### 3. Cloud Run へのデプロイ

```bash
gcloud run deploy conversation-relay \
  --source . \
  --region asia-northeast1 \
  --platform managed \
  --allow-unauthenticated \
  --timeout 3600 \
  --concurrency 1 \
  --min-instances 1 \
  --max-instances 10 \
  --memory 512Mi \
  --cpu 1 \
  --set-secrets "OPENAI_API_KEY=OPENAI_API_KEY:latest,TWILIO_AUTH_TOKEN=TWILIO_AUTH_TOKEN:latest" \
  --set-env-vars "WEBHOOK_VALIDATE=true,CR_LANGUAGE=ja-JP,CR_TTS_PROVIDER=google,CR_VOICE=ja-JP-Standard-B"
```

## ローカル実行

```bash
# 依存関係のインストール
npm install

# .env ファイルを設定（サンプルが含まれています）
# OPENAI_API_KEY と TWILIO_AUTH_TOKEN を設定してください
vi .env

# サーバー起動
npm start
```

ヘルスチェック確認：
```bash
curl http://localhost:8080/healthz
```

TwiML エンドポイント確認：
```bash
curl http://localhost:8080/twiml/ai
```

## Twilio 側の設定

1. Twilio Console で電話番号の設定画面を開く
2. Voice Configuration の「A call comes in」を Webhook に設定
3. URL に以下を入力：
   ```
   https://YOUR-SERVICE-URL/twiml/ai
   ```
   
   **注意**: Cloud Run のサービス URL は以下の形式になります：
   - `https://SERVICE-NAME-PROJECT-NUMBER.REGION.run.app` (従来形式)
   - `https://SERVICE-NAME-HASH-REGION-CODE.a.run.app` (新形式)
   
   正確な URL は `./scripts/manage-service.sh status` で確認できます。
4. HTTP メソッドを `HTTP POST` に設定
5. 保存

これにより、電話がかかってきた際に TwiML エンドポイントが呼び出され、ConversationRelay が WebSocket 経由で接続されます。

## サービス管理

### インスタンス数の管理

`manage-service.sh` スクリプトで Cloud Run のコストとパフォーマンスを管理できます：

```bash
# 基本的な使用方法
./scripts/manage-service.sh <command> [service-name] [region]

# 利用可能なコマンド
./scripts/manage-service.sh on       # 常時起動（min-instances=1）
./scripts/manage-service.sh off      # 使用時起動（min-instances=0）
./scripts/manage-service.sh toggle   # 自動切り替え（0↔1）
./scripts/manage-service.sh status   # 現在の状態確認
```

**実行例：**
```bash
# デフォルト設定でサービスを起動
./scripts/manage-service.sh on

# 特定のサービス・リージョンを指定
./scripts/manage-service.sh on my-service us-central1

# 現在の状態を確認（URL、インスタンス数など）
./scripts/manage-service.sh status

# コスト削減のため使用時のみ起動に変更
./scripts/manage-service.sh off
```

### 使い分けの目安

**常時起動（on）を推奨する場合：**
- 重要な業務電話で即座に応答が必要
- 高頻度で利用される
- レスポンス速度が最優先

**使用時起動（off）を推奨する場合：**
- テストや開発環境
- 低頻度での利用
- コスト削減が優先

## Webhook 署名検証

セキュリティ強化のため、Twilio からの Webhook リクエストの署名検証を有効にできます：

1. `WEBHOOK_VALIDATE=true` を環境変数に設定
2. `TWILIO_AUTH_TOKEN` を Secret として設定
3. Cloud Run の TLS 終端を考慮した URL 構築により自動的に検証

**注意点：**
- Cloud Run は TLS 終端を行うため、`X-Forwarded-Proto` ヘッダーを使用して実際のプロトコルを判定
- 検証に失敗した場合は 403 エラーを返却

## 運用のヒント

### AI 会話機能
- OpenAI GPT-4o-mini を使用（モデルは server.js で変更可能）
- ストリーミングレスポンスで自然な会話を実現
- 会話履歴を保持し、文脈を考慮した応答を生成
- 日本語の文区切り（。！？）で逐次音声合成

### タイムアウト設定
- Cloud Run のタイムアウトは最大 60 分（3600 秒）
- 長時間の通話に対応するため、タイムアウトを最大値に設定することを推奨

### 再接続処理
- WebSocket 接続が切断された場合、Twilio 側で自動的に再接続を試みます
- アプリケーション側での明示的な再接続処理は不要

### Keepalive
- 25 秒ごとに ping/pong を送信して接続を維持
- Cloud Run の WebSocket アイドルタイムアウト（60秒）を回避

### 構造化ログ
- Cloud Logging との統合のため、JSON 形式でのログ出力を検討
- `console.log` の出力は自動的に Cloud Logging に収集されます

### スケーリング
- ConversationRelay は接続ごとにリソースを消費するため、`concurrency=1` を推奨
- 同時接続数に応じて `max-instances` を調整

### Cloud Run URL の変更について
- Cloud Run のサービス URL は Google の内部更新により形式が変わる場合があります
- 従来: `https://service-PROJECT-NUMBER.REGION.run.app`
- 新形式: `https://service-HASH-REGION-CODE.a.run.app`
- 両方の URL は同じサービスにアクセス可能です
- Twilio の設定では最新の URL を使用することを推奨

### コールドスタート対策
- `./scripts/manage-service.sh on` で常時起動に設定
- 初回接続の遅延を防ぎ、即座に電話応答が可能

### 会話履歴の管理
- 各セッションごとに独立した会話履歴を保持
- 履歴が長くなりすぎないよう最新10ターンを保持
- システムプロンプトは常に保持

## 参照リンク

- [Cloud Run WebSocket サポート](https://cloud.google.com/run/docs/triggering/websockets)
- [Cloud Run ソースからのデプロイ](https://cloud.google.com/run/docs/deploying-source-code)
- [Twilio ConversationRelay TwiML](https://www.twilio.com/docs/voice/twiml/connect#conversationrelay)
- [Twilio Webhook セキュリティ](https://www.twilio.com/docs/usage/webhooks/webhooks-security)
- [Cloud Run Buildpacks](https://cloud.google.com/docs/buildpacks/overview)

## トラブルシューティング

### WebSocket 接続が確立されない
- `./scripts/manage-service.sh status` で正しい URL を確認
- Cloud Run のログで WebSocket パス（`/relay`）が正しいか確認
- TwiML で生成される WebSocket URL が最新の形式か確認
- サービスが起動している（min-instances > 0）か確認

### 署名検証エラー
- `TWILIO_AUTH_TOKEN` が正しく設定されているか確認
- リクエスト URL の構築が正しいか（特に `x-forwarded-proto` ヘッダー）

### AI が応答しない
- OpenAI API キーが Secret Manager に正しく設定されているか確認
- Cloud Run のログで「User said on [ID]: [テキスト]」が出力されているか確認
- API の利用制限やクレジット残高を確認
- `SYSTEM_PROMPT` 環境変数が適切に設定されているか確認

### Service URL が変わった場合
- `./scripts/manage-service.sh status` で最新の URL を確認
- Twilio Console の Webhook URL を新しい URL に更新
- 古い URL も一定期間は動作しますが、最新 URL への更新を推奨

### デプロイエラー
- 必要な GCP API が有効化されているか確認
- サービスアカウントの権限を確認
- `gcloud` CLI が最新版か確認