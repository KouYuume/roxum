# roxum

[English](README.md) | 日本語

roxumは、[Roc](https://github.com/roc-lang/roc)の思想に沿ったWebサーバープラットフォームを目指しています。アプリケーションは簡潔に記述し、業務ロジックは純粋に、副作用は明示的に。型付きハンドラーでHTTPの振る舞いを表現し、I/Oと実行管理はプラットフォームが担います。

独立して配備できるHTTP API・バックエンドサービスに注力します。[対応範囲と対象外の方針](docs/design/non-goals.md)と、ブラウザーUIやハイパーメディアアプリ向けにJoy・rouxなどを紹介する[用途に応じたRocプラットフォームの選び方](docs/design/non-goals.md#choosing-a-roc-platform-for-your-application)を参照してください。

## 主な特徴

- **定型コードを減らす。** 型付きextractor、JSONの自動エンコード、`Try(Reply, Reply)` でリクエスト処理を簡潔に記述。
- **小さな関数でDDDを表現する。** 純粋なドメイン関数と関数によるDIで、層の接続とテストをシンプルに。純粋関数へのI/O混入はコンパイルエラーになります。[DDDサンプル](examples/ddd/README.md)を参照してください。
- **開発の反復を短くする。** `--opt=dev` でLLVM最適化を省略。アプリだけの変更ではビルド済みZigホストを再利用。
- **I/Oを順番に書ける。** I/O待ちはリクエストのfiberが中断するため、アプリ側の `async` / `await` は不要。
- **ルートをビルド時に検査する。** トップレベルで定義したルーターの不正なパターンや重複をコンパイル時に検出。
- **タグと実行段階でミドルウェアを制御する。** 独自の型付きタグで対象を絞り、`BeforeBody`・`OnChunk`・`AfterBody`・`AfterHandler` に処理を配置。[ミドルウェア](docs/guides/middleware.md)と[タグとミドルウェアの例](examples/middleware/README.md)を参照してください。

ホストはリクエスト単位のメモリ再利用・回収も管理します。ストリーミング、SSE、ファイル配信、gzip、PostgreSQL、外向きHTTPSにも対応。[アーキテクチャ](docs/design/architecture.md)と[メモリモデル](docs/design/execution-model.md)で仕組みを説明しています。

## axum・Goとの比較

roxumはaxumと同じく、ハンドラーの入力を型で受け取り、Goにない型による検査（error処理、null、data race、網羅的なmatch）を持ちます。axumに加えて、ドメインの純粋性をコンパイラが保証し、routeをビルド時に検査します。その代わり、受信のTLS、HTTP/2、WebSocketには対応せず（TLSとHTTP/2はリバースプロキシを前に置きます）、ミドルウェアはroxumのintegrationだけを使え、まだ若いプロジェクトです。実行性能はまだaxumに届かず、2コアで固定応答を返す負荷ではaxumの73〜96%でした。最適化ビルドは、変更がなくても約3秒かかります。

観点ごとの評価と根拠は[比較](docs/comparison.md)、測定は[性能の現状](docs/performance.md)にあります。

## クイックスタート

roxumは開発中です。Zig 0.17.1と[指定リビジョンのRoc](.roc-revision)を用意し、[ツールチェーンをセットアップ](docs/toolchain.md)してください。対応環境はApple silicon搭載macOSと、muslを使うarm64 / x86_64 Linuxです。

リポジトリのルートで実行します。

```sh
zig build host
roc build --opt=dev --output=hello examples/hello/app.roc
./hello
```

[helloサンプル](examples/hello/app.roc)のルート定義：

```roc
routes : Router(Model, [], {})
routes = Router.new
	.route("/", MethodRouter.get(Handler.static(|{}| Reply.text("Hello, Roc!\n"))))
```

表示されたポートを使って `curl http://127.0.0.1:<port>/` で確認し、Ctrl-Cで停止します。最適化ビルドには `--opt=speed` を使用。ホストのソースやコンパイラABIを変更した場合はホストも再ビルドしてください。

次に読む：[入門ガイド](docs/guides/getting-started.md) · [hello](examples/hello/README.md) · [DDD](examples/ddd/README.md) · [タグとミドルウェア](examples/middleware/README.md) · [ドキュメント一覧](docs/README.md)。

## Integrations

| 分野 | パッケージ |
|---|---|
| データと外部API | [PostgreSQL](integrations/roxum-postgres/README.md)、[HTTPクライアント](integrations/roxum-http-client/README.md) |
| ブラウザクライアント | [CORS](integrations/roxum-cors/README.md)、[Cookie](integrations/roxum-cookie/README.md)、[Server-Sent Events](integrations/roxum-sse/README.md) |
| トラフィック制御 | [レート制限](integrations/roxum-rate-limit/README.md)、[同時実行数の制限](integrations/roxum-concurrency-limit/README.md) |
| リクエストとレスポンスの処理 | [パスの正規化](integrations/roxum-normalize-path/README.md)、[プロキシヘッダー](integrations/roxum-proxy-headers/README.md)、[レスポンスヘッダー](integrations/roxum-set-header/README.md)、[トレーシング](integrations/roxum-trace/README.md) |

コアとintegrationは独立してバージョン管理します。[バージョニング](docs/design/versioning.md)と[integrationのリリース](docs/design/integration-releases.md)を参照してください。

## 制約

- IPv4・IPv6のTCPとファイルパスを使うUnixソケットに対応。HTTP/1.1のみ。受信TLS・HTTP/2・HTTP/3は[リバースプロキシ](docs/guides/reverse-proxy.md)で終端。
- WebSocket、CONNECT、TRACE、拡張メソッド、HTTPトレーラーは未対応。
- CONNECT、TRACE、任意の拡張メソッドは、強い利用者要望がない限り[対応対象外](docs/design/non-goals.md)とする。
- タイムアウトで任意のRocの計算を強制中断することはできません。
- 実行時圧縮はgzip。事前圧縮したBrotliは配信可能、複数バイトレンジは未対応。
- セッション、CSRF対策、OAuth、JWT、OpenAPIはコアに含みません。
- セッション、CSRF対策、OAuth、JWTはライブラリまたはintegrationが担い、コアでは必要な汎用能力の提供を検討します。[対応範囲の方針](docs/design/non-goals.md#sessions-csrf-oauth-and-jwt)を参照してください。
- OpenAPIの生成・検証・ドキュメントUIはライブラリまたはintegrationが担います。[対応範囲の方針](docs/design/non-goals.md#openapi)を参照してください。
- 配信ルート配下はドットファイルも公開対象です。非公開ファイルは外に置いてください。

## 貢献・問い合わせ

issueには最小の再現コード、ツールチェーンのリビジョン、OS、コマンドと出力を記載し、ログの認証情報は削除してください。変更前に[プロジェクトのルール](AGENTS.md)と[Rocのコーディングルール](roc_coding_rules.md)を読み、関連テスト・ドキュメントと両READMEを更新してください。

```sh
zig build test
zig build test-e2e
zig build test-e2e -Dcontract-alloc=true
zig build test-contract
```

全体の検証は `speed`・`dev`・`interpreter` を対象とし、push の前に手元で実行します（[contributing](docs/contributing.md)）。リリース検証は `tools/release-check.sh`、Linux検証は `tools/linux/run-tests.sh`、ファジングは `zig build fuzz` の後に `tools/fuzz.sh 10000` を実行します。

## ライセンス

roxumは[MITライセンス](LICENSE)で提供します。
