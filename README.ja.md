# Agent Meter

[English](README.md)

Agent Meterは、CodexとClaude Codeの利用制限をmacOSのメニューバーから確認できるアプリです。SwiftUIで実装しています。

## 機能

- Codex CLI／対応IDE拡張と同じログイン状態を利用
- Codex app-serverが返す利用制限の割合とリセット時刻を表示
- Claude Codeの5時間・7日制限を表示
- メニューバーの項目（Codex・週、Claude Code・5時間、Claude Code・週）を、それぞれ自由にオン／オフ。同じサービスのバーはアイコンの後に並べて表示
- 項目ごとに、期間ラベルとバーの表示／非表示、値の表示（使用・残りの数値または%、リセットまでの時間、非表示）を選択
- 設定画面でプレビューを確認可能（データがないサービスはサンプル値で表示）
- トークン数は表示できません（各サービスが返すのは使用率とリセット時刻のみのため）
- 60秒間隔で自動更新
- ログイン時に自動で起動します（**Settings → General** でオフにできます）。初回起動時は、アカウントの追加を案内するため、設定画面を1回だけ自動で開きます

## 対応状況

| サービス | 取得元 | 表示できる期間 |
| --- | --- | --- |
| Codex | Codex CLIのapp-server | アカウントから返された期間（現在は7日） |
| Claude Code | Anthropicの利用状況API（Claude Codeのログイントークンを使用） | 5時間、7日 |

## インストール

Homebrewの場合:

```sh
brew install --cask scolor-dev/tap/agent-meter
```

または、[GitHub Releases](https://github.com/scolor-dev/agent-meter/releases/latest) から `AgentMeter-<バージョン>.zip` をダウンロードして展開し、`AgentMeter.app` を `/Applications` に移動します。

## アップデート

インストール方法にかかわらず、[Sparkle](https://sparkle-project.org) でアプリ自身が更新します。**Settings → Updates** で、自動確認と自動インストールのオン／オフを切り替えられます。メニューの **Check for Updates…** から手動で確認することもできます。

手動で更新する場合:

- Homebrew: `brew upgrade --cask --greedy agent-meter`（Caskに `auto_updates` を指定しているため、通常の `brew upgrade` では対象外です）
- GitHub: Releasesから最新のZIPをダウンロードして、アプリを置き換えます

## 動作要件

- macOS 14以降
- Codex CLIまたはCodex対応IDE拡張（Codexを表示する場合）
- Claude Code CLIまたはClaude Code対応IDE拡張（Claude Codeを表示する場合）

表示したいサービスの分だけで構いません。
- ソースからビルドする場合はXcode

外部CLIを実行するため、App Sandboxは無効です。Mac App Storeではなく、GitHub ReleasesとHomebrewで配布します。

## 開発

Xcodeでプロジェクトを開きます。

```sh
open AgentMeter.xcodeproj
```

コマンドラインでのDebugビルド:

```sh
xcodebuild \
  -project AgentMeter.xcodeproj \
  -scheme AgentMeter \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/xcode \
  CODE_SIGNING_ALLOWED=NO \
  build
```

`xcode-select` がCommand Line Toolsを向いている場合は、先頭に
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` を付けてください。

ユニットテスト:

```sh
xcodebuild -project AgentMeter.xcodeproj -scheme AgentMeter \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  test -only-testing:AgentMeterTests
```

## Claude Code連携とプライバシー

Agent Meterは、Claude用の独自ログインを持ちません。ターミナルまたは対応IDE拡張で行ったClaude Codeのログインをそのまま使います。

**Settings → Accounts** で、Claude Codeの **Add**（追加済みなら **Manage**）を選びます。

- すでにログイン済み（`claude auth login`）なら、**Recheck** を押します。
- 未ログインの場合は、**Log in** で公式の `claude auth login`（ブラウザのOAuth）を起動します。

使用率の取得には、Claude CodeがmacOSキーチェーン（`Claude Code-credentials`）に保存しているアクセストークンを読み取り、Anthropicの利用状況エンドポイントを呼び出します。読み取りには、Claude Codeが書き込みに使っているのと同じmacOS標準の `security` コマンドを使うため、読み取りのたびに許可を求められることを避けられるようにしています。それでも許可のダイアログが表示される場合は、**常に許可**を選んでください。トークンの更新はClaude Codeに任せます。期限切れのときは `claude auth status` を実行してClaude Code自身に更新させ、読み直します。Agent Meterがトークンを更新・書き込み・保存することはありません。

使用率の値はメモリ上にだけ保持します。ディスクに保存するのは、追加したサービスと、メニューバーの表示設定だけです。プロンプト、応答、作業ディレクトリは保存しません。

## リリース手順

`scripts/release.sh` は、Archive、Developer IDでの書き出し、Notarization、Sparkle用のZIP署名、GitHub Releaseの作成（`AgentMeter-<バージョン>.zip` と `appcast.xml`）を行います。Homebrewの Cask は、[scolor-dev/homebrew-tap](https://github.com/scolor-dev/homebrew-tap) のCIが、新しい安定版のリリースを1時間以内に反映します（アプリの署名とNotarizationを確認してから公開します。すぐに反映したい場合は、tap側の `Update cask` ワークフローを手動で実行してください）。

初回のみ必要な準備:

1. ログインキーチェーンにDeveloper ID Application証明書
2. Notarization用の認証情報: `xcrun notarytool store-credentials agent-meter-notary`
3. SparkleのEdDSA鍵: パッケージ解決後の `SourcePackages/artifacts/sparkle/Sparkle/bin` にある `generate_keys` を実行し、表示された公開鍵をアプリターゲットのビルド設定 `SPARKLE_PUBLIC_ED_KEY` に設定します。秘密鍵は `generate_keys -x <ファイル>` でバックアップしてください。失うと、既存のインストールを更新できなくなります。
4. `gh auth login`

その後、`MARKETING_VERSION` と `CURRENT_PROJECT_VERSION` を上げ（Sparkleは、インストール済みよりビルド番号が大きい版だけを提示します）、コミットして、次を実行します。

```sh
scripts/release.sh
```

作業ツリーはきれいな状態にしてください。新しいアカウントでは、Notarizationに数分から数時間かかることがあり、スクリプトは完了まで待ちます。`--no-publish` を付けると、リリースを作らずにZIPと `appcast.xml` だけを作ります。`--skip-notarize` はNotarizationを省略します（ローカルでの確認専用で、公開とは併用できません）。

## ライセンス

Agent Meterは [MIT License](LICENSE) で公開しています。

同梱している [Sparkle](https://sparkle-project.org) には独自のライセンスがあります。[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) を参照してください。CodexとClaude CodeのアイコンはOpenAIとAnthropicの商標で、このライセンスの対象外です。Agent MeterはOpenAIおよびAnthropicとは無関係です。
