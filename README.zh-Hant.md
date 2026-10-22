# Vitrine

[English](README.md) · **繁體中文** · [简体中文](README.zh-Hans.md) · [日本語](README.ja.md)
> 本文譯自[英文版](README.md)，內容如有出入以英文版為準。

[![CI](https://github.com/cioufong/vitrine/actions/workflows/ci.yml/badge.svg)](https://github.com/cioufong/vitrine/actions/workflows/ci.yml)

**免費、開源的 Apple Silicon 虛擬機器，你和你的 AI agent 都能操作——
支援 macOS、Linux 和 Windows。**

Vitrine 以原生速度在 Apple 的 Virtualization.framework 上執行虛擬機器（macOS 與 Linux 客體系統），
Apple 框架做不到的部分（Windows 11、x86_64 模擬）則交給 QEMU。採用 Apache-2.0 授權。

- **給 AI agent**：`vitrinectl mcp` 是一個 [Model Context Protocol](docs/mcp.md) 伺服器。agent 可以
  用無人值守安裝建立 Windows 11 或 Debian 虛擬機器（在 macOS 27 主機上也能建立 macOS），接著
  觀看它的畫面、點按、以任何語言輸入文字、透過 SSH 執行指令與複製檔案，還能為它拍快照或複製：
  一台乾淨的機器，可以拿來測試 App、重現 bug，或讓 agent 在裡面工作，而不是直接在你的 Mac 上動手。
  一切都在本機執行，不會傳到任何雲端服務。
- **給你**：那些別人要付費才有的整合功能：客體系統的 App 以一般視窗出現在你的桌面上（無縫模式）、
  共享剪貼簿、共享資料夾、即時快照、休眠／繼續執行，以及一鍵安裝。

![Windows 11 的記事本、檔案總管和小算盤以獨立視窗顯示在 Mac 上，旁邊是 Vitrine 的控制中心](docs/images/seamless-windows.png)

> 狀態：v0.1，積極開發中。請參閱[目前可用的功能](#what-works-today)（附日期的測試結果
> 見 [docs/verification.md](docs/verification.md)）以及[開發藍圖](#roadmap)。

### 下載

從[最新版本](https://github.com/cioufong/vitrine/releases/latest)下載 `Vitrine-<version>.zip`，
解壓縮後把 `Vitrine.app` 移到「應用程式」資料夾。這個 App 採 ad-hoc 簽署，目前尚未經過公證，所以
macOS 會阻擋第一次啟動；而在 macOS 15 及更新版本上，按右鍵 ▸「打開」已經無法繞過這個限制：
請先開啟 Vitrine 一次，然後前往 **系統設定 ▸ 隱私權與安全性**，往下捲動並按一下
**強制打開**（或執行 `xattr -dr com.apple.quarantine /Applications/Vitrine.app`）。這個 App 的
命令列工具兼 MCP 伺服器是 `/Applications/Vitrine.app/Contents/MacOS/vitrinectl`。

### 讓 agent 來操作

```bash
./scripts/build-cli.sh                                        # → .build/release/vitrinectl
claude mcp add vitrine -- "$PWD/.build/release/vitrinectl" mcp  # 或任何 MCP 用戶端，見 docs/mcp.md
```

接著你可以這樣要求，例如：*「建立一台叫 win-test 的 Windows 11 虛擬機器，等它設定完成，
在裡面安裝 7-Zip，並把它開啟時的畫面截圖下來。」* agent 會使用 `create_vm`、輪詢 `create_status`，
再透過 `exec`、`screenshot`、`click` 和 `type_text` 操作客體系統；客體系統帳號的密碼
一直存放在虛擬機器套件中，從不會顯示給 agent。

## 重點功能

| 功能 | Vitrine 支援情況與需求 |
|---|---|
| 價格／授權 | 免費，Apache-2.0 |
| AI agent（MCP） | 建立（無人值守安裝 Debian 13、Windows 11、macOS）、複製、啟動／停止、截圖、點按、輸入（美式鍵盤，或透過客體系統 agent 輸入任何字元）、SSH 執行指令與複製檔案、快照——[docs/mcp.md](docs/mcp.md) |
| 無縫客體系統視窗 | macOS、Linux/X11 與 Windows 客體系統 agent |
| 一鍵安裝 macOS | macOS 27 自動佈建＋自動安裝 agent |
| 一鍵安裝 Linux 桌面 | 以雲端映像檔＋cloud-init 安裝 Debian 13 Xfce |
| Windows 11 on Arm／x64 | QEMU＋HVF／實驗性 TCG 模擬 |
| 快照 | 以 APFS 複製套件內的磁碟，可選擇一併保存記憶體狀態；請見下方的快照安全性 |
| 休眠／繼續執行 | VZ 與 QEMU，包含 Windows on Arm |
| 結束 App 時的行為 | 預設會讓執行中的虛擬機器休眠；失敗時會回報，而不是默默丟棄狀態 |
| 剪貼簿 | macOS：文字、RTF、HTML、影像；Linux／Windows：文字與 PNG |
| 把檔案拖進虛擬機器 | macOS 與 Windows 客體系統；Linux 客體系統接收檔案仍在開發藍圖上 |
| 共享資料夾 | VZ 客體系統用 virtiofs；Windows 客體系統用 Samba |
| GPU | macOS 客體系統用 Metal；Linux 與 Windows 使用 2D 顯示，3D 仍在開發藍圖上 |
| USB 直通 | QEMU 主機 USB；VZ 主機 USB 需要 macOS 27 和 Apple 的受限 entitlement |
| 客體系統 App 出現在 Mac Dock | Agent 的 App 目錄與 Dock 代理啟動器 |
| 虛擬機器視窗狀態列 | 由 agent 提供客體系統的 CPU、記憶體、磁碟、開機時間與 IP；網路線、剪貼簿、調整顯示大小、相機、藍牙與 USB 的開關（顯示方式 ▸ 顯示狀態列（View ▸ Show Status Bar），⌘/） |
| 在客體系統中使用 Mac 相機 | Linux 客體系統：狀態列開關開啟時，agent 會把 Mac 的相機變成 v4l2loopback 網路攝影機；macOS 客體系統：agent 的 *Vitrine Camera* 延伸功能，需搭配團隊簽署的 agent；Windows 11 客體系統：Media Foundation 虛擬相機（[docs/camera.md](docs/camera.md)） |
| 在客體系統中使用 Mac 藍牙（實驗性） | Linux 客體系統會得到一個模擬的低功耗藍牙控制器（`hci0`），它的掃描、連線與 GATT 流量都經由 Mac 的藍牙進行（[docs/bluetooth.md](docs/bluetooth.md)） |
| 網路 | NAT、僅限主機、具名的虛擬機器互連網路、橋接（root 輔助程式）、TCP/UDP 連接埠轉送——[docs/networking.md](docs/networking.md) |
| 磁碟格式 | ASIF（macOS 26 以上）或稀疏 raw |
| CLI | `vitrinectl` |

<a id="what-works-today"></a>
## 目前可用的功能

已在執行 macOS 27 的 M1 Max 上完成端對端驗證：

- **macOS 客體系統**：下載 IPSW → 安裝 → 第一次開機就建立你的帳號（不經過「設定輔助程式」）、
  啟用 SSH，Vitrine 自動安裝它的 agent；無縫模式提供清晰的 1:1 Retina 視窗、
  滑鼠、鍵盤（含快速鍵與合成文字）、雙向剪貼簿；可從 Finder 把檔案拖到虛擬機器上
  （檔案會出現在客體系統的桌面）；休眠／繼續執行；APFS 快照。
- **Linux 客體系統（VZ）**：UEFI＋ISO 安裝、直接核心開機（自動解開 gzip 與 EFI-zboot 核心）、
  透過 cloud-init 一鍵安裝 **Debian 13 Xfce**（使用者、SSH、桌面、自動登入、virtiofs 掛載）、
  以 Rosetta 執行 x86_64 二進位檔、序列主控台記錄。
- **QEMU 後端**：HVF 上的 aarch64 與 x86_64 模擬（TCG）、UEFI、NVMe、USB 安裝媒體、供 Windows 11
  使用的 TPM 2.0（swtpm）、App 內建 VNC 顯示並傳送原始 scancode、QMP 控制、透過遷移（migration）
  實現休眠／繼續執行（期間會熱拔除 USB 音訊，因此連 Windows on Arm 也能休眠）。
- **Windows 11 on Arm（QEMU＋HVF）**：以官方 26H2 ISO（build 26300.9457）驗證——
  完全無人值守安裝（帳號、自動登入、virtio 驅動程式、OpenSSH、Vitrine agent），agent
  在第一次登入時就連上；鍵盤（含 Unicode 文字）、焦點、視窗清單、畫面擷取與雙向
  剪貼簿都通過 `vitrinectl agent probe`；休眠／繼續執行（6 GB RAM 映像，約 50 秒），以及從
  已安裝的磁碟冷開機。安裝過程在 ramfb 上進行；之後 Windows 改用 virtio-gpu（viogpudo），解析度
  1920×1080，Vitrine 會自行完成收尾（退出安裝媒體、刪除含有密碼的種子媒體、再開機一次）。
- **Windows 11 x64（TCG 模擬）**——實驗性。2026-10-18 記錄的驗收測試在 M1 Max 上
  以 1 小時 53 分鐘完成無人值守安裝，包含 SSH 與 agent。離線安裝與預先植入的 OpenSSH
  避開了先前在 OOBE／Windows Update 卡住的問題。完整的 x64 模擬仍比 Windows on Arm 慢得多；
  請見[實測結果](docs/benchmarks.md)。這些是該組態的記錄結果，並非對每一種 Windows ISO 或主機的驗收測試。
- **驗證**：哪些功能在全新安裝的 Debian、Windows 11 Arm 與 macOS 上測試過，
  在哪個日期、哪個 commit，以及顯示延遲和已知問題——[docs/verification.md](docs/verification.md)。
- **日常虛擬機器功能**：拋棄式模式（每次執行都從同一份磁碟開始）、擁有各自 MAC 與 DHCP 主機名稱的
  APFS 複製、NAT／僅限主機／可指定固定位址的具名虛擬機器互連網路／
  橋接（透過只需安裝一次的小型 root 輔助程式）／無網路，兩種後端都支援 TCP 與 UDP 連接埠轉送
  （[docs/networking.md](docs/networking.md)）、
  共享資料夾（VZ 用 virtiofs、QEMU Linux 用 9p）、序列主控台（`vitrinectl console`，可寫成腳本）、
  QEMU GDB stub、透過 SSH 推送／拉取檔案、匯入 qcow2/VMDK/VHDX/VDI 磁碟與 UTM 虛擬機器、
  用於自動化的 `vitrine://start|show|suspend|stop?vm=NAME` URL、虛擬機器執行時讓 Mac 保持喚醒，
  以及 x86_64 QEMU 客體系統使用 Microsoft 金鑰的 Secure Boot（已驗證 Debian 的已簽署 shim → GRUB；
  開啟 Secure Boot 的 Windows 尚未驗證）。
- **語言**：App 提供英文、繁體中文、簡體中文和日文介面，並依照「系統設定」中設定的語言顯示；
  新增語言的方式請見 [CONTRIBUTING.md](CONTRIBUTING.md#translations)。CLI 為英文。
- **AI agent（MCP）**：`vitrinectl mcp` 讓 MCP 用戶端能以無人值守安裝 Debian、
  Windows 11 或 macOS 的方式建立虛擬機器、複製它們、啟動與停止、看到它們的畫面、輸入文字
  與點按（以虛擬機器自己的鍵盤和指標裝置進行，所以在登入畫面與安裝程式中也能用）、透過 SSH 執行
  指令與複製檔案，以及拍快照——請見 [docs/mcp.md](docs/mcp.md)。美式鍵盤打不出來的文字
  （重音符號、中日韓文字、emoji）會經由客體系統 agent 輸入。目前已完全透過 MCP 端對端建立過的有：
  無介面的 Debian 13、Windows 11 Arm 與 macOS 27；Unicode 輸入已在 Debian Xfce 終端機、
  Windows PowerShell 與 macOS「終端機」中逐位元組核對（在 agent 不能打字時改由客體系統
  剪貼簿貼上）（[驗證](docs/verification.md)）。
- **客體系統 agent**：macOS（Swift）、Linux/X11 與 Windows（共用一套 Go 程式碼）。Windows 使用 GDI 擷取
  與 `SendInput`；其 agent 預設會等待 virtio-serial。TCP 是需要明確指定、安全性較弱的
  相容性傳輸方式，不會自動作為客體系統 agent 的備援。

> **繼續執行需要 Mac 處於解鎖狀態。** Virtualization.framework 會用 Secure Enclave 金鑰加密已儲存的
> 虛擬機器記憶體，而 macOS 只有在你已登入且解鎖時才會釋出這把金鑰。在螢幕鎖定時嘗試繼續執行
> 會失敗；Vitrine 會保留已儲存的狀態，並請你解鎖後重試（或用 **捨棄休眠狀態（Discard Suspended State）**／
> `vitrinectl discard-state` 將它丟棄）。

## 無縫模式的運作方式

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

一條擷取串流供應所有視窗，因此無論開了多少個客體系統視窗，每次畫面更新都只是對共享 IOSurface 做一次
`memcpy`。（程式碼中把這項功能稱為 *Coherence*：`CoherenceController`、`--coherence`。）
設計與程式碼皆為無塵室（clean-room）實作——沒有檢視或使用任何專有程式碼。

## 系統需求

- Apple Silicon Mac，macOS 14 以上（建議 macOS 27：可自動設定 macOS 帳號、使用 ASIF 磁碟）
- 建置需要 Xcode 16 以上／Swift 6
- Windows／x86_64 客體系統需要：`brew install qemu swtpm`
- Windows 共享資料夾與從主機拖放檔案到客體系統需要：`brew install samba`
- Linux 無縫整合需要 X11 工作階段；不支援 Wayland。

## 建置與執行

```bash
git clone https://github.com/cioufong/vitrine && cd vitrine
./scripts/build-app.sh          # → dist/Vitrine.app（以 ad-hoc 簽署，含虛擬化 entitlement）
open dist/Vitrine.app
```

ad-hoc 建置不需要 Apple 帳號。VZ 自己的橋接網路、VZ USB 直通，以及 macOS
客體系統的相機，需要 Apple 核發給開發者團隊的 entitlement。若要啟用這些功能，請用你自己的團隊
簽署建置結果：見 [docs/signing.md](docs/signing.md)。

使用 **檔案 → 新增…（File → New…）**（即「安裝輔助程式」）：

- **下載 macOS**——你的 Mac 所支援的最新版本。
- **Debian 13 (Xfce)**——現成的桌面環境，自動完成設定。
- **Linux**——任何 arm64 安裝 ISO（Ubuntu、Fedora、Debian……）。
- **Windows 11**——選擇一個 Microsoft ISO；可選 Arm64（建議——x64 App 透過 Prism 執行）或
  x64（完整模擬，實驗性）。

要在 macOS 虛擬機器中使用無縫模式，請按一下虛擬機器視窗頂端橫幅中的 **允許…（Allow…）**（或選擇
*動作 ▸ 允許 Vitrine Agent 控制…（Actions ▸ Allow Vitrine Agent Control…）*）一次，並在虛擬機器內允許兩個提示
（「螢幕錄製」和「輔助使用」），然後按 **⌃⌘C**（或工具列按鈕）。由 `vitrinectl run` 執行的虛擬機器
則用 `vitrinectl agent permissions <vm>` 來詢問。在你這麼做之前，agent 不會要求任何權限，所以只從主機
操作的虛擬機器永遠不會顯示這些提示。Linux 與 Windows 的 agent 不需要任何權限：按 **⌃⌘C** 即可，
*動作 ▸ 結束無縫模式（Actions ▸ Exit Seamless Mode）*（或再按一次 ⌃⌘C）會讓虛擬機器視窗回來。

### 命令列

```bash
./scripts/build-cli.sh                                   # .build/release/vitrinectl
vitrinectl create dev --user me --password '…'            # macOS 虛擬機器
vitrinectl create-linux deb --distro debian-13 --user me --password '…'
vitrinectl create-linux alpine --iso alpine.iso           # 任何 Linux ISO（VZ）
vitrinectl create-windows win --iso Win11_Arm64.iso --user me --password '…'   # 無人值守安裝 Windows 11
vitrinectl set win --eject                                # 安裝完成後：卸除安裝媒體與種子媒體
vitrinectl agent probe win --editor Notepad               # 端對端 agent 檢查（QEMU 客體系統）
vitrinectl run dev [--gui] [--console]                    # Ctrl-C 關機
vitrinectl suspend dev                                    # 用 `run` 繼續執行（由 App 執行的虛擬機器也適用）
vitrinectl discard-state dev                              # 丟棄已儲存的記憶體，下次從磁碟開機
vitrinectl snapshot create dev clean-install
vitrinectl share add dev ~/Projects
vitrinectl exec dev 'uname -a'                            # 透過 SSH 在客體系統中執行指令
vitrinectl agent install dev
vitrinectl agent camera dev                               # 安裝客體系統的虛擬相機（Linux、Windows 11）
vitrinectl agent bluetooth dev                            # Linux 客體系統：安裝藍牙橋接（BlueZ、hci_uart）
vitrinectl agent permissions mac                          # macOS 客體系統：在其中詢問 agent 無縫模式所需的權限
vitrinectl screenshot win shot.png                        # 任何執行中的虛擬機器
vitrinectl keys deb --combo ctrl+alt+t; vitrinectl click deb 640 400
vitrinectl mcp                                            # 給 AI agent 用的 MCP 伺服器（docs/mcp.md）
vitrinectl set deb --disposable on                        # 丟棄每次執行的變更
vitrinectl port add deb 2222:22                           # 把主機 127.0.0.1:2222 轉送到客體系統的 SSH
vitrinectl network create lab; vitrinectl set deb --network network:lab   # 虛擬機器互連網路
vitrinectl set deb --network bridged:en0                  # 在區域網路上擁有自己的位址（docs/networking.md）
vitrinectl push deb ./notes /home/me/notes                # 複製進去（pull 則是複製出來）
vitrinectl console deb                                    # 序列主控台；Ctrl-] 中斷連接
vitrinectl import old.utm                                 # 或 .qcow2/.vmdk/.vhdx/.vdi 磁碟
open 'vitrine://start?vm=deb'                             # 從腳本 start/show/suspend/stop
vitrinectl list
```

### 快照安全性

可寫入的磁碟必須是一般檔案，並以虛擬機器套件內的安全路徑參照。快照與複製在做出任何變更之前，
會拒絕外部的可寫入磁碟、上層目錄遍歷（parent traversal）與符號連結別名。請先把這些磁碟移入套件，
或改以唯讀方式連接。外部的唯讀媒體只會被參照、不會被擷取；請讓它們留在原本的位置保持可用。

還原快照時，會在取代虛擬機器狀態之前檢查其 manifest、必要的磁碟與已儲存記憶體的中繼資料。
不完整的舊版快照會被拒絕。帶有可寫入熱插拔 USB 媒體或主機 USB 裝置的已儲存狀態
無法安全地拍快照；請在儲存前關機或卸除這些裝置。
共享的主機資料夾不在快照範圍內，永遠不會被回復。

如果還原及其回復都失敗，Vitrine 會保留原始備份、回報它們的復原目錄，並在該工作區復原之前
阻止虛擬機器啟動與再次還原。在復原其中的檔案之前，絕對不要刪除保留下來的 `.restore-*` 目錄。

### 測試

```bash
swift test                     # 單元測試（協定、framebuffer、無縫視窗管線、QEMU 參數……），
                               # 對腳本化客體系統執行 agent probe，macOS 輸入注入只記錄、不實際送出
python3 scripts/tests/lifecycle-integrity.py "$(swift build -c release --show-bin-path)/vitrinectl"
                               # 拋棄式 CLI 套件＋合成 QMP 故障復原；請先建置 release
./scripts/smoke-linux.sh       # 在 Virtualization.framework 上開機 Alpine
./scripts/smoke-qemu.sh        # 在 QEMU/HVF 上開機 Alpine，休眠後再繼續執行
ARCH=x86_64 ./scripts/smoke-qemu.sh   # 同上，改用 x86_64 模擬
./scripts/tests/ninep-share-e2e.sh     # QEMU Linux：序列主控台登入、9p 共享資料夾、GDB stub
./scripts/tests/network-qemu-e2e.sh    # QEMU Linux：連接埠轉送、NAT 下可連網際網路、僅限主機時不可
./scripts/tests/secureboot-e2e.sh      # x86_64 QEMU：拒絕未簽署的載入程式，Debian 的已簽署 shim 可開機
./scripts/tests/automation-qemu-e2e.sh # QEMU：透過 QMP 截圖、輸入與點按
python3 scripts/tests/mcp-e2e.py "$(swift build --show-bin-path)/vitrinectl" <vm>  # 對執行中的桌面虛擬機器測試 MCP
python3 scripts/tests/mcp-create-e2e.py "$(swift build --show-bin-path)/vitrinectl" <new-vm>  # MCP 建立、複製、快照
python3 scripts/tests/mcp-unicode-e2e.py "$(swift build --show-bin-path)/vitrinectl" <vm> [linux|windows|macos]  # 非美式鍵盤輸入
open dist/Vitrine.app --args --coherence-demo   # 對合成客體系統測試無縫模式
```

cloud-init YAML 測試需要 Python 3 與 PyYAML（CI 固定使用 6.0.3）。GUI 整合測試需要
作用中的顯示器，沒有顯示器時會明確略過。Socket、Samba 與 ISO 掛載整合測試需要
對應的本機權限／工具；如果沙箱阻擋了這些資源，請在一般的本機 shell 中執行。CLI 生命週期執行器
與 agent probe 測試只使用暫時的假資料虛擬機器和腳本化 agent；它們從不會開機任何客體系統。

## 專案結構

| 路徑 | 內容 |
|---|---|
| `Sources/VitrineCore` | 虛擬機器組態、套件、ASIF/raw 磁碟、APFS 快照與複製、核心解包、客體系統網路查詢 |
| `Sources/VitrineVZ` | Virtualization.framework 後端、macOS 安裝程式、雲端映像檔 Linux 安裝程式、agent 安裝程式、虛擬機器控制器 |
| `Sources/VitrineQEMU` | QEMU 後端：參數產生器、QMP、VNC 用戶端＋顯示視圖、swtpm、Windows 建立 |
| `Sources/VitrineAgentProtocol` | 主機⇄客體系統傳輸協定、通道、剪貼簿同步 |
| `Sources/VitrineAgentHost` | Agent 工作階段、IOSurface framebuffer、無縫視窗、相機擷取、模擬的低功耗藍牙控制器 |
| `Sources/VitrineNet` | 兩種後端與橋接輔助程式共用的 vmnet 介面與 frame socket |
| `Sources/vitrine-bridged` | 提供橋接網路的 root LaunchDaemon（依需求安裝） |
| `Sources/VitrineApp` | SwiftUI App（控制中心、安裝輔助程式、組態）；UI 字串位於 `Resources/Localizable.xcstrings` |
| `Sources/vitrinectl` | CLI |
| `guest/macos-agent` | macOS 客體系統 agent（`VitrineAgent.app`） |
| `guest/macos-camera-extension` | 供 macOS 客體系統使用的 *Vitrine Camera* CoreMediaIO 延伸功能（位於 `VitrineAgent.app` 內） |
| `guest/linux-agent` | Linux（X11）與 Windows（Win32）客體系統 agent，Go；`btbridge` 是 root 藍牙橋接 |
| `guest/windows-camera` | 供 Windows 11 客體系統使用的 *Vitrine Camera* Media Foundation 媒體來源（C++，以 zig 建置） |
| `docs/` | 研究筆記、效能測試、驗證矩陣、網路、相機、藍牙、簽署、MCP、Linux GPU 開發藍圖 |

<a id="roadmap"></a>
## 開發藍圖

- Windows x64 模擬：提升速度，並在更多主機／ISO 組態上重複驗收；
  「安裝一次」範本以及在主機上套用 install.wim，仍是未來可能的工作。
- Windows：跟隨視窗或無縫畫面變動的解析度——內建的 viogpudo 驅動程式只提供
  固定的一組標準模式（640×480 … 5120×2160），因此任意尺寸需要支援自訂模式的
  驅動程式，或由 agent 端選擇最接近的模式；比 USB 大量儲存裝置更快的安裝
  媒體；在開啟 Secure Boot 的情況下進行 Windows 驗收；拖放檔案到
  Linux 客體系統。
- Arm 客體系統的 Secure Boot（Homebrew 的 QEMU 沒有附帶支援 Secure Boot 的 Arm 韌體），以及填入內容的
  撤銷清單（dbx；目前為空）。
- Linux 3D 加速：QEMU＋virglrenderer/ANGLE 子行程，或 libkrun Venus——
  [docs/linux-gpu-roadmap.md](docs/linux-gpu-roadmap.md)。
- 無縫模式中的客體系統選單列；從客體系統把檔案拖到主機。
- 網路：在更多台 Mac 上透過已安裝的 root 輔助程式測試橋接執行；無介面的 Linux agent
  模式，讓沒有 X 的伺服器也能回報其位址。
- 更廣泛的 USB 直通驗收測試；VZ 實體 USB 與 VZ 自己的橋接網路需要
  受限的 entitlement，因此只能在團隊簽署的建置中運作（[docs/signing.md](docs/signing.md)）。
- 在 Windows 11 上測試 Windows 客體系統相機；以團隊簽署的 agent 端對端測試 macOS 客體系統相機。
- 藍牙：客體系統端的廣播與周邊裝置角色、L2CAP 通道、測試更多裝置。

## 授權

Apache License 2.0。請見 [LICENSE](LICENSE)。QEMU（GPL）僅作為獨立程式使用，不會隨 Vitrine
一起散布，也不會連結進 Vitrine。內附的客體系統 agent 包含採 BSD 授權的第三方 Go 套件；
請見 [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES)。

Vitrine 是獨立專案，與 Apple、Parallels、Microsoft 或 UTM 專案均無關聯，也未獲其背書或贊助；
產品名稱為其各自擁有者的商標，僅用於說明相容性。
