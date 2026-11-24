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

既定のHTTP/1.1ではストリーミング、SSE、ファイル配信を利用できます。[平文HTTP/2](docs/guides/deployment.md#opt-in-http2)を選ぶと、入力と出力の逐次処理、トレーラー、非圧縮gRPCの全4形式を利用できます。どちらもIPv4・IPv6のTCPとファイルパスを使うUnixソケットに対応しています。

## axum・Goとの比較

roxumは、型付きHTTP処理とRocによる純粋性の保証・明示的な副作用を組み合わせます。
まだ若いプラットフォームで、エコシステムと通信機能の対応範囲は限定的です。
機能の違いは[比較](docs/comparison.md)、ワークロードごとの測定結果は
[性能の現状](docs/performance.md)を参照してください。

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
| RPC | [gRPC](integrations/roxum-grpc/README.md) · [実行例](integrations/roxum-grpc/example/README.md) |
| データと外部API | [PostgreSQL](integrations/roxum-postgres/README.md)、[HTTPクライアント](integrations/roxum-http-client/README.md) |
| ブラウザクライアント | [CORS](integrations/roxum-cors/README.md)、[Cookie](integrations/roxum-cookie/README.md)、[Server-Sent Events](integrations/roxum-sse/README.md) |
| トラフィック制御 | [レート制限](integrations/roxum-rate-limit/README.md)、[同時実行数の制限](integrations/roxum-concurrency-limit/README.md) |
| リクエストとレスポンスの処理 | [パスの正規化](integrations/roxum-normalize-path/README.md)、[プロキシヘッダー](integrations/roxum-proxy-headers/README.md)、[レスポンスヘッダー](integrations/roxum-set-header/README.md)、[トレーシング](integrations/roxum-trace/README.md) |

コアとintegrationは独立してバージョン管理します。[バージョニング](docs/design/versioning.md)と[integrationのリリース](docs/design/integration-releases.md)を参照してください。

## 制約

- 受信TLS・HTTP/3は[リバースプロキシ](docs/guides/reverse-proxy.md)で終端します。HTTP/1トレーラーは未対応です。WebSocketサーバー、CONNECT、TRACE、任意の拡張メソッドは[強い要望がない限り対応対象外](docs/design/non-goals.md#features-excluded-unless-strong-demand-emerges)です。
- タイムアウトで任意のRocの計算を強制中断することはできません。
- 実行時圧縮はgzip。事前圧縮したBrotliは配信可能、複数バイトレンジは未対応です。
- セッション・CSRF・OAuth・JWT・OpenAPIはライブラリまたはintegrationが担います。[対応範囲の方針](docs/design/non-goals.md#features-owned-by-libraries-and-integrations)を参照してください。
- 配信ルート配下はドットファイルも公開対象です。非公開ファイルは外に置いてください。

## 貢献・問い合わせ

不具合報告には最小の再現コード、ツールチェーンのリビジョン、OS、コマンドと出力を記載し、ログの認証情報は削除してください。変更時は[プロジェクトのルール](AGENTS.md)、[Rocのコーディングルール](roc_coding_rules.md)、[ローカル検証とPRの手順](docs/contributing.md)を参照してください。

## ライセンス

roxumは[MITライセンス](LICENSE)で提供します。
