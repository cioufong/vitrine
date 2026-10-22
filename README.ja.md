# Vitrine

[English](README.md) · [繁體中文](README.zh-Hant.md) · [简体中文](README.zh-Hans.md) · **日本語**
> この文書は[英語版](README.md)の翻訳です。内容に相違がある場合は英語版が優先されます。

[![CI](https://github.com/cioufong/vitrine/actions/workflows/ci.yml/badge.svg)](https://github.com/cioufong/vitrine/actions/workflows/ci.yml)

**あなたと AI エージェントの両方が操作できる、Apple Silicon 向けの無料・オープンソースの仮想マシン —
macOS、Linux、Windows に対応。**

Vitrine は Apple の Virtualization.framework 上でネイティブ速度で VM を実行し（macOS および Linux ゲスト）、
Apple のフレームワークで対応できない場合（Windows 11、x86_64 エミュレーション）は QEMU 上で実行します。
ライセンスは Apache-2.0 です。

- **AI エージェント向け**: `vitrinectl mcp` は [Model Context Protocol](docs/mcp.md) サーバーです。エージェントは
  無人インストールで Windows 11 や Debian の VM を作成でき（macOS 27 ホストでは macOS も可能）、さらにその画面を見て、
  クリックし、任意の言語で入力し、SSH 経由でコマンドの実行やファイルのコピーを行い、スナップショットや複製を作成できます。
  アプリのテストやバグの再現に使えるクリーンなマシン、あるいは Mac 本体ではなくエージェントに作業させるための場所として使えます。
  すべてローカルで動作し、クラウドサービスには何も送信されません。
- **あなた向け**: 有料製品で求められる統合機能を備えています。ゲストのアプリをデスクトップ上の通常のウインドウとして表示
  （シームレスモード）、共有クリップボード、共有フォルダ、瞬時のスナップショット、サスペンド/再開、ワンクリックインストールです。

![Windows 11 のメモ帳、エクスプローラー、電卓が Mac 上の独立したウインドウとして表示され、隣に Vitrine のコントロールセンターがある様子](docs/images/seamless-windows.png)

> ステータス: v0.1、活発に開発中です。[現在動作するもの](#what-works-today)（日付入りのテスト結果は
> [docs/verification.md](docs/verification.md) にあります）と[ロードマップ](#roadmap)をご覧ください。

### ダウンロード

[最新リリース](https://github.com/cioufong/vitrine/releases/latest)から `Vitrine-<version>.zip` を入手し、
展開して `Vitrine.app` をアプリケーションフォルダに移動してください。このアプリはアドホック署名されており、まだ公証されていないため、
macOS は初回起動をブロックします。また macOS 15 以降では右クリック ▸「開く」でもこれを回避できなくなりました。
一度 Vitrine を開いてから **システム設定 ▸ プライバシーとセキュリティ** に移動し、下にスクロールして
**「このまま開く」** をクリックしてください（または `xattr -dr com.apple.quarantine /Applications/Vitrine.app` を実行します）。
アプリのコマンドラインツール兼 MCP サーバーは `/Applications/Vitrine.app/Contents/MacOS/vitrinectl` です。

### エージェントに操作させる

```bash
./scripts/build-cli.sh                                        # → .build/release/vitrinectl
claude mcp add vitrine -- "$PWD/.build/release/vitrinectl" mcp  # または任意の MCP クライアント。docs/mcp.md を参照
```

あとは、たとえば次のように依頼します: *「win-test という名前の Windows 11 VM を作成し、セットアップが終わるまで待ってから
7-Zip をインストールし、それを開いた状態のスクリーンショットを撮ってください。」* エージェントは `create_vm` を使い、
`create_status` をポーリングし、`exec`、`screenshot`、`click`、`type_text` でゲストを操作します。ゲストアカウントの
パスワードは VM バンドル内に保持され、エージェントに表示されることはありません。

## 主な機能

| 機能 | Vitrine の対応状況と要件 |
|---|---|
| 価格 / ライセンス | 無料、Apache-2.0 |
| AI エージェント（MCP） | 作成（Debian 13、Windows 11、macOS の無人インストール）、複製、起動/停止、スクリーンショット、クリック、入力（US キーボード、またはゲストエージェント経由で任意の文字）、SSH によるコマンド実行とファイルコピー、スナップショット — [docs/mcp.md](docs/mcp.md) |
| シームレスなゲストウインドウ | macOS、Linux/X11、Windows のゲストエージェント |
| ワンクリック macOS | macOS 27 のプロビジョニング＋エージェントの自動インストール |
| ワンクリック Linux デスクトップ | クラウドイメージ＋cloud-init による Debian 13 Xfce |
| Windows 11 on Arm / x64 | QEMU＋HVF / 実験的な TCG エミュレーション |
| スナップショット | バンドル内のディスクの APFS クローン、メモリ状態は任意。後述の「スナップショットの安全性」を参照 |
| サスペンド / 再開 | VZ と QEMU、Windows on Arm を含む |
| 終了時の動作 | デフォルトでは実行中の VM をサスペンドします。状態を黙って破棄せず、失敗した場合は報告します |
| クリップボード | macOS: テキスト、RTF、HTML、画像。Linux/Windows: テキストと PNG |
| VM へのファイルのドラッグ | macOS および Windows ゲスト。Linux ゲストでのファイル受信は引き続きロードマップ上にあります |
| 共有フォルダ | VZ ゲストは virtiofs、Windows ゲストは Samba |
| GPU | macOS ゲストは Metal。Linux と Windows は 2D ディスプレイを使用し、3D は引き続きロードマップ上にあります |
| USB パススルー | QEMU はホストの USB。VZ でのホスト USB には macOS 27 と Apple の制限付き entitlement が必要です |
| Mac の Dock にゲストアプリ | エージェントのアプリカタログと Dock プロキシランチャー |
| VM ウインドウのステータスバー | エージェントから取得したゲストの CPU、メモリ、ディスク、稼働時間、IP。ネットワークケーブル、クリップボード、ディスプレイのリサイズ、カメラ、Bluetooth、USB のスイッチ（表示 ▸ ステータスバーを表示（Show Status Bar）、⌘/） |
| ゲストで Mac のカメラを使用 | Linux ゲスト: ステータスバーのスイッチがオンの間、エージェントが Mac のカメラを v4l2loopback の Web カメラにします。macOS ゲスト: チーム署名されたエージェントでの、エージェントの *Vitrine Camera* 拡張機能。Windows 11 ゲスト: Media Foundation の仮想カメラ（[docs/camera.md](docs/camera.md)） |
| ゲストで Mac の Bluetooth を使用（実験的） | Linux ゲストには、スキャン・接続・GATT 通信が Mac の Bluetooth を経由する、エミュレートされた Bluetooth LE コントローラー（`hci0`）が提供されます（[docs/bluetooth.md](docs/bluetooth.md)） |
| ネットワーク | NAT、ホストオンリー、名前付きの VM 間ネットワーク、ブリッジ（root ヘルパー）、TCP/UDP ポートフォワード — [docs/networking.md](docs/networking.md) |
| ディスク形式 | ASIF（macOS 26 以降）またはスパース raw |
| CLI | `vitrinectl` |

<a id="what-works-today"></a>
## 現在動作するもの

macOS 27 を実行する M1 Max でエンドツーエンドに検証済みです:

- **macOS ゲスト**: IPSW のダウンロード → インストール → 初回起動時にアカウントを作成し（設定アシスタントなし）、
  SSH を有効化し、Vitrine がエージェントを自動でインストールします。1:1 のくっきりした Retina ウインドウによるシームレスモード、
  マウス、キーボード（ショートカットと合成テキストを含む）、双方向クリップボード。Finder から VM へのファイルのドラッグ
  （ゲストのデスクトップに置かれます）。サスペンド/再開。APFS スナップショット。
- **Linux ゲスト（VZ）**: UEFI＋ISO によるインストール、ダイレクトカーネルブート（gzip および EFI-zboot カーネルは自動的に展開）、
  cloud-init によるワンクリックの **Debian 13 Xfce**（ユーザー、SSH、デスクトップ、自動ログイン、virtiofs のマウント）、
  x86_64 バイナリ用の Rosetta、シリアルコンソールのログ。
- **QEMU バックエンド**: HVF 上の aarch64 と x86_64 エミュレーション（TCG）、UEFI、NVMe、USB インストールメディア、
  Windows 11 用の TPM 2.0（swtpm）、raw スキャンコードによるアプリ内 VNC ディスプレイ、QMP による制御、マイグレーションによる
  サスペンド/再開（その前後で USB オーディオをホットアンプラグするため、Windows on Arm でもサスペンドできます）。
- **Windows 11 on Arm（QEMU＋HVF）**: 公式の 26H2 ISO（ビルド 26300.9457）で検証済み —
  完全な無人インストール（アカウント、自動ログオン、virtio ドライバー、OpenSSH、Vitrine エージェント）、エージェントは
  初回ログオン時に接続します。Unicode テキストを含むキーボード、フォーカス、ウインドウ一覧、キャプチャ、双方向クリップボードが
  `vitrinectl agent probe` に合格。サスペンド/再開（6 GB RAM のイメージで約 50 秒）と、インストール済みディスクからのコールドブート。
  セットアップは ramfb 上で実行され、その後 Windows は 1920×1080 の virtio-gpu（viogpudo）を使用し、Vitrine は
  セットアップを自動で完了します（メディアを取り出し、パスワードを含むシードを削除し、再起動します）。
- **Windows 11 x64（TCG エミュレーション）** — 実験的です。記録された 2026-10-18 の受け入れテストでは、M1 Max 上で
  SSH とエージェントを含む無人セットアップが 1 時間 53 分で完了しました。オフラインセットアップと事前投入した OpenSSH により、
  以前の OOBE/Windows Update での停止を回避しています。完全な x64 エミュレーションは Windows on Arm よりはるかに
  低速なままです。[測定結果](docs/benchmarks.md)を参照してください。これはその構成での記録された結果であり、
  すべての Windows ISO やホストに対する受け入れテストではありません。
- **検証**: Debian、Windows 11 Arm、macOS の新規インストールでどの機能を、どの日付・どのコミットでテストしたか、
  ディスプレイのレイテンシや既知の問題とあわせて記載しています — [docs/verification.md](docs/verification.md)。
- **日常的な VM 機能**: 使い捨てモード（毎回同じディスクから起動）、独自の MAC アドレスと DHCP ホスト名を持つ APFS クローン、
  NAT / ホストオンリー / 固定アドレス付きの名前付き VM 間ネットワーク / ブリッジ（一度インストールする小さな root ヘルパー経由）/
  ネットワークなし、両バックエンドでの TCP および UDP ポートフォワード（[docs/networking.md](docs/networking.md)）、
  共有フォルダ（VZ では virtiofs、QEMU の Linux では 9p）、シリアルコンソール（`vitrinectl console`、スクリプト化可能）、
  QEMU の GDB スタブ、SSH によるファイルの push/pull、qcow2/VMDK/VHDX/VDI ディスクおよび UTM VM のインポート、
  自動化用の `vitrine://start|show|suspend|stop?vm=NAME` URL、VM 実行中に Mac をスリープさせない機能、
  x86_64 QEMU ゲストでの Microsoft の鍵による Secure Boot（Debian の署名済み shim → GRUB は検証済み。
  Secure Boot を有効にした Windows は未検証）。
- **言語**: アプリは英語、繁体字中国語、簡体字中国語、日本語に対応しており、システム設定で設定された言語に従います。
  言語の追加方法は [CONTRIBUTING.md](CONTRIBUTING.md#translations) に記載しています。CLI は英語です。
- **AI エージェント（MCP）**: `vitrinectl mcp` により、MCP クライアントは Debian、Windows 11、macOS の無人インストールで
  VM を作成し、複製し、起動・停止し、画面を確認し、入力やクリックを行い（VM 自身のキーボードとポインターとして動作するため、
  ログイン画面やインストーラーでも使えます）、SSH 経由でコマンドの実行やファイルのコピーを行い、スナップショットを作成できます
  — [docs/mcp.md](docs/mcp.md) を参照してください。US キーボードで入力できないテキスト（アクセント記号、CJK、絵文字）は
  ゲストエージェント経由で送られます。これまでに MCP でエンドツーエンドに作成できたのは、ヘッドレスの Debian 13、
  Windows 11 Arm、macOS 27 です。Unicode 入力は Debian Xfce のターミナル、Windows PowerShell、macOS のターミナル
  （エージェントが入力を許可されていない間はゲストのクリップボード経由で貼り付け）でバイト単位で確認しています
  （[検証](docs/verification.md)）。
- **ゲストエージェント**: macOS（Swift）、Linux/X11 と Windows（単一の Go コードベース）。Windows は GDI キャプチャと
  `SendInput` を使用し、そのエージェントはデフォルトで virtio-serial を待ちます。TCP は明示的に指定する、より弱い互換用の
  トランスポートであり、ゲストエージェントの自動フォールバックではありません。

> **再開には Mac のロック解除が必要です。** Virtualization.framework は、保存された VM のメモリを Secure Enclave の鍵で
> 暗号化します。macOS はログインしてロックを解除している間しかこの鍵を提供しません。画面がロックされている間に再開を試みると
> 失敗します。Vitrine は保存された状態を保持し、ロックを解除して再試行するよう求めます（または **サスペンド状態を破棄**
> （Discard Suspended State）/ `vitrinectl discard-state` で破棄できます）。

## シームレスモードの仕組み

```
 guest (VM)                                           host (your Mac)
┌───────────────────────────┐  vsock (VZ) or     ┌──────────────────────────────────┐
│ Vitrine Agent              │  virtio-serial     │ AgentSession                     │
│  • one display stream     │ ─────────────────► │  • IOSurface framebuffer         │
│    (ScreenCaptureKit /    │  dirty rects       │ CoherenceController              │
│    X11 damage), no        │  window list       │  • one borderless NSWindow per   │
│    wallpaper/Dock/shadows │                    │    guest window, cropping the    │
│  • window geometry        │ ◄───────────────── │    shared surface (contentsRect) │
│  • input injection        │  pointer, keys,    │  • native host shadows & z-order │
│  • clipboard sync         │  focus, clipboard  │ DisplaySink keeps the guest at   │
└───────────────────────────┘                    │  host-screen resolution          │
                                                 └──────────────────────────────────┘
```

1 本のキャプチャストリームがすべてのウインドウに供給されるため、ゲストのウインドウがいくつ開いていても、フレームの更新は
共有 IOSurface への 1 回の `memcpy` で済みます。（コード内ではこの機能を *Coherence* と呼んでいます: `CoherenceController`、
`--coherence`。）設計とコードはクリーンルーム方式です — プロプライエタリなコードを調査したり使用したりはしていません。

## 動作要件

- Apple Silicon Mac、macOS 14 以降（macOS 27 を推奨: macOS アカウントの自動セットアップ、ASIF ディスク）
- ビルドには Xcode 16 以降 / Swift 6
- Windows / x86_64 ゲストには: `brew install qemu swtpm`
- Windows の共有フォルダとホストからゲストへのファイルのドロップには: `brew install samba`
- Linux のシームレス統合には X11 セッションが必要です。Wayland には対応していません。

## ビルドと実行

```bash
git clone https://github.com/cioufong/vitrine && cd vitrine
./scripts/build-app.sh          # → dist/Vitrine.app（virtualization entitlement 付きでアドホック署名）
open dist/Vitrine.app
```

アドホックビルドには Apple アカウントは不要です。VZ 独自のブリッジネットワーク、VZ の USB パススルー、macOS ゲストのカメラには、
Apple が開発者チームに付与する entitlement が必要です。これらを有効にするには、自分のチームでビルドに署名してください:
[docs/signing.md](docs/signing.md) を参照してください。

**ファイル → 新規…**（File → New…、インストールアシスタント）を使用します:

- **macOS をダウンロード**（Download macOS） — お使いの Mac が対応する最新バージョン。
- **Debian 13 (Xfce)** — 自動的に構成される、すぐに使えるデスクトップ。
- **Linux** — 任意の arm64 インストーラー ISO（Ubuntu、Fedora、Debian…）。
- **Windows 11** — Microsoft の ISO を選択し、Arm64（推奨 — x64 アプリは Prism 経由で動作）または
  x64（完全エミュレーション、実験的）を選びます。

macOS VM でシームレスモードを使うには、VM ウインドウ上部のバーにある **許可…**（Allow…）をクリックし（または
*アクション ▸ Vitrine Agent による制御を許可…*（Actions ▸ Allow Vitrine Agent Control…）を選択し）、一度だけ VM 内の
両方の確認ダイアログ（画面収録とアクセシビリティ）を許可してから、**⌃⌘C**（またはツールバーのボタン）を押します。
`vitrinectl run` で実行している VM では `vitrinectl agent permissions <vm>` で許可を求めます。エージェントはあなたが求めるまで
何も要求しないため、ホストから操作するだけの VM ではこれらのダイアログは表示されません。Linux と Windows のエージェントには
許可は不要です。**⌃⌘C** を押してください。*アクション ▸ シームレスモードを終了*（Actions ▸ Exit Seamless Mode）
（またはもう一度 ⌃⌘C）で VM ウインドウに戻ります。

### コマンドライン

```bash
./scripts/build-cli.sh                                   # .build/release/vitrinectl
vitrinectl create dev --user me --password '…'            # macOS VM
vitrinectl create-linux deb --distro debian-13 --user me --password '…'
vitrinectl create-linux alpine --iso alpine.iso           # 任意の Linux ISO（VZ）
vitrinectl create-windows win --iso Win11_Arm64.iso --user me --password '…'   # 無人インストールの Windows 11
vitrinectl set win --eject                                # インストール後: インストーラーとシードのメディアを取り外す
vitrinectl agent probe win --editor Notepad               # エージェントのエンドツーエンドチェック（QEMU ゲスト）
vitrinectl run dev [--gui] [--console]                    # Ctrl-C でシャットダウン
vitrinectl suspend dev                                    # `run` で再開（アプリで実行中の VM にも有効）
vitrinectl discard-state dev                              # 保存されたメモリを破棄し、次回はディスクから起動
vitrinectl snapshot create dev clean-install
vitrinectl share add dev ~/Projects
vitrinectl exec dev 'uname -a'                            # SSH 経由でゲスト内のコマンドを実行
vitrinectl agent install dev
vitrinectl agent camera dev                               # ゲストの仮想カメラをインストール（Linux、Windows 11）
vitrinectl agent bluetooth dev                            # Linux ゲスト: Bluetooth ブリッジをインストール（BlueZ、hci_uart）
vitrinectl agent permissions mac                          # macOS ゲスト: エージェントのシームレスモード用の許可をゲスト内で求める
vitrinectl screenshot win shot.png                        # 実行中の任意の VM
vitrinectl keys deb --combo ctrl+alt+t; vitrinectl click deb 640 400
vitrinectl mcp                                            # AI エージェント用の MCP サーバー（docs/mcp.md）
vitrinectl set deb --disposable on                        # 各実行での変更を破棄
vitrinectl port add deb 2222:22                           # ホストの 127.0.0.1:2222 をゲストの SSH に転送
vitrinectl network create lab; vitrinectl set deb --network network:lab   # VM 間ネットワーク
vitrinectl set deb --network bridged:en0                  # LAN 上で独自のアドレスを持つ（docs/networking.md）
vitrinectl push deb ./notes /home/me/notes                # コピーして入れる（pull でコピーして取り出す）
vitrinectl console deb                                    # シリアルコンソール。Ctrl-] で切り離す
vitrinectl import old.utm                                 # または .qcow2/.vmdk/.vhdx/.vdi ディスク
open 'vitrine://start?vm=deb'                             # スクリプトから start/show/suspend/stop
vitrinectl list
```

### スナップショットの安全性

書き込み可能なディスクは、VM バンドル内の安全なパスで参照される通常のファイルでなければなりません。スナップショットと
クローンは、変更を加える前に、外部の書き込み可能なディスク、親ディレクトリへの遡り（parent traversal）、シンボリックリンクによる
別名を拒否します。そうしたディスクは、先にバンドル内に移動するか、読み取り専用で接続してください。外部の読み取り専用メディアは
取り込まれずに参照されるため、元の場所で利用できる状態を保ってください。

スナップショットの復元では、VM の状態を置き換える前に、マニフェスト、必要なディスク、保存されたメモリのメタデータを確認します。
不完全な旧形式のスナップショットは拒否されます。書き込み可能なホットプラグ USB メディアやホストの USB デバイスを含む保存状態は、
安全にスナップショットを作成できません。保存する前にシャットダウンするか、それらのデバイスを取り外してください。
ホストの共有フォルダはスナップショットの対象外であり、ロールバックされることはありません。

復元とそのロールバックの両方が失敗した場合、Vitrine は元のバックアップを保持し、その復旧用ディレクトリを報告し、
その作業領域が復旧されるまで VM の起動と別の復元をブロックします。保持された `.restore-*` ディレクトリは、
その中のファイルを復旧する前に決して削除しないでください。

### テスト

```bash
swift test                     # ユニットテスト（プロトコル、フレームバッファ、シームレスウインドウのパイプライン、QEMU 引数など）、
                               # スクリプト化したゲストに対するエージェントプローブ、macOS の入力注入は記録のみで送信しない
python3 scripts/tests/lifecycle-integrity.py "$(swift build -c release --show-bin-path)/vitrinectl"
                               # 使い捨ての CLI バンドル＋合成した QMP 障害からの復旧。先に release をビルドすること
./scripts/smoke-linux.sh       # Virtualization.framework 上で Alpine を起動
./scripts/smoke-qemu.sh        # QEMU/HVF 上で Alpine を起動し、サスペンドして再開
ARCH=x86_64 ./scripts/smoke-qemu.sh   # 同上、x86_64 エミュレーションで
./scripts/tests/ninep-share-e2e.sh     # QEMU Linux: シリアルコンソールでのログイン、9p 共有フォルダ、GDB スタブ
./scripts/tests/network-qemu-e2e.sh    # QEMU Linux: ポートフォワード、NAT でのインターネット接続、ホストオンリーでは接続なし
./scripts/tests/secureboot-e2e.sh      # x86_64 QEMU: 未署名のローダーは拒否され、Debian の署名済み shim は起動する
./scripts/tests/automation-qemu-e2e.sh # QEMU: QMP 経由のスクリーンショット、入力、クリック
python3 scripts/tests/mcp-e2e.py "$(swift build --show-bin-path)/vitrinectl" <vm>  # 実行中のデスクトップ VM に対する MCP
python3 scripts/tests/mcp-create-e2e.py "$(swift build --show-bin-path)/vitrinectl" <new-vm>  # MCP での作成、複製、スナップショット
python3 scripts/tests/mcp-unicode-e2e.py "$(swift build --show-bin-path)/vitrinectl" <vm> [linux|windows|macos]  # US 以外の文字の入力
open dist/Vitrine.app --args --coherence-demo   # 合成ゲストに対するシームレスモード
```

cloud-init の YAML テストには Python 3 と PyYAML が必要です（CI では 6.0.3 に固定）。GUI の統合テストにはアクティブな
ディスプレイが必要で、ディスプレイがない場合は明示的にスキップされます。ソケット、Samba、ISO マウントの統合テストには、
対応するローカルの権限やツールが必要です。サンドボックスがそれらのリソースをブロックする場合は、通常のローカルシェルで実行してください。
CLI のライフサイクルランナーとエージェントプローブのテストは、一時的なダミーデータの VM とスクリプト化したエージェントのみを使用し、
ゲストを起動することはありません。

## プロジェクトの構成

| パス | 内容 |
|---|---|
| `Sources/VitrineCore` | VM の構成、バンドル、ASIF/raw ディスク、APFS スナップショットとクローン、カーネルの展開、ゲストのネットワーク情報の取得 |
| `Sources/VitrineVZ` | Virtualization.framework バックエンド、macOS インストーラー、クラウドイメージによる Linux インストーラー、エージェントインストーラー、VM コントローラー |
| `Sources/VitrineQEMU` | QEMU バックエンド: 引数ビルダー、QMP、VNC クライアント＋ディスプレイビュー、swtpm、Windows の作成 |
| `Sources/VitrineAgentProtocol` | ホスト⇄ゲスト間のワイヤープロトコル、チャネル、クリップボード同期 |
| `Sources/VitrineAgentHost` | エージェントセッション、IOSurface フレームバッファ、シームレスウインドウ、カメラキャプチャ、エミュレートされた Bluetooth LE コントローラー |
| `Sources/VitrineNet` | 両バックエンドとブリッジヘルパーで共有される vmnet インターフェイスとフレームソケット |
| `Sources/vitrine-bridged` | ブリッジネットワークを提供する root の LaunchDaemon（要求に応じてインストール） |
| `Sources/VitrineApp` | SwiftUI アプリ（コントロールセンター、インストールアシスタント、構成）。UI 文字列は `Resources/Localizable.xcstrings` |
| `Sources/vitrinectl` | CLI |
| `guest/macos-agent` | macOS ゲストエージェント（`VitrineAgent.app`） |
| `guest/macos-camera-extension` | macOS ゲスト用の *Vitrine Camera* CoreMediaIO 拡張機能（`VitrineAgent.app` に内蔵） |
| `guest/linux-agent` | Linux（X11）および Windows（Win32）のゲストエージェント、Go。`btbridge` は root で動作する Bluetooth ブリッジ |
| `guest/windows-camera` | Windows 11 ゲスト用の *Vitrine Camera* Media Foundation メディアソース（C++、zig でビルド） |
| `docs/` | 調査メモ、ベンチマーク、検証マトリクス、ネットワーク、カメラ、Bluetooth、署名、MCP、Linux GPU ロードマップ |

<a id="roadmap"></a>
## ロードマップ

- Windows x64 エミュレーション: 速度を改善し、より多くのホスト/ISO 構成で受け入れテストを繰り返すこと。
  一度だけインストールするテンプレートや、ホスト上での install.wim の適用は、将来の作業として引き続き検討の余地があります。
- Windows: ウインドウやシームレス画面に追従する解像度 — 標準の viogpudo ドライバーは固定された標準モードの一覧
  （640×480 … 5120×2160）しか提供しないため、任意のサイズにはカスタムモード対応のドライバーか、エージェント側での
  最も近いモードの選択が必要です。USB マスストレージより高速なインストーラーメディア。Secure Boot を有効にした状態での
  Windows の受け入れテスト。Linux ゲストへのドラッグ＆ドロップ。
- Arm ゲストでの Secure Boot（Homebrew の QEMU には Secure Boot 対応の Arm ファームウェアが付属していません）と、
  失効リスト（dbx。現在は空）の整備。
- Linux の 3D アクセラレーション: QEMU＋virglrenderer/ANGLE の子プロセス、または libkrun Venus —
  [docs/linux-gpu-roadmap.md](docs/linux-gpu-roadmap.md)。
- シームレスモードでのゲストのメニューバー。ゲストからホストへのファイルのドラッグ。
- ネットワーク: インストール済みの root ヘルパーを介したブリッジ接続を、より多くの Mac で実行すること。X のないサーバーでも
  アドレスを報告できるよう、ヘッドレスの Linux エージェントモード。
- より幅広い USB パススルーの受け入れテスト。VZ の物理 USB と VZ 独自のブリッジネットワークには制限付きの entitlement が
  必要なため、チームで署名されたビルドでのみ動作します（[docs/signing.md](docs/signing.md)）。
- Windows 11 での Windows ゲストカメラのテスト。チーム署名されたエージェントでの macOS ゲストカメラのエンドツーエンドテスト。
- Bluetooth: ゲスト側でのアドバタイズとペリフェラルロール、L2CAP チャネル、より多くのデバイスでのテスト。

## ライセンス

Apache License 2.0。[LICENSE](LICENSE) を参照してください。QEMU（GPL）は別個のプログラムとしてのみ使用されており、
Vitrine とともに配布されることも、Vitrine にリンクされることもありません。同梱のゲストエージェントには BSD ライセンスの
サードパーティ製 Go パッケージが含まれています。[THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES) を参照してください。

Vitrine は独立したプロジェクトです。Apple、Parallels、Microsoft、UTM プロジェクトとは提携しておらず、これらによる承認や
後援も受けていません。製品名は各所有者の商標であり、互換性を説明する目的でのみ使用しています。
