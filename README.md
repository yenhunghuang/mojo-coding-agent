# Mojo Coding Agent

用 **Pixi + Mojo 1.0** 學習 coding agent：一個看得完的 tool loop、四個工具，以及可以逐步擴充的清楚邊界。

**應用程式與測試全部使用 Mojo。** CLI、JSON、檔案操作、程序逾時與輸出管理都在 Mojo 實作。唯一額外工具是 Pixi 管理的 `curl`，負責 HTTP／TLS 傳輸；模型統一使用 OpenAI-compatible Chat Completions 格式，透過 Bifrost 切換 provider。

## 開始

需要 [Pixi](https://pixi.prefix.dev/latest/installation/)。支援 Apple Silicon macOS、Linux x86-64／ARM64；`pixi.lock` 鎖定各平台環境，Mojo 固定為 1.0.0。

```bash
git clone https://github.com/yenhunghuang/mojo-coding-agent.git
cd mojo-coding-agent
pixi install --locked
pixi run test                 # 離線測試，不需要 Bifrost 或 API key
pixi run start --help
```

先啟動並設定好 [Bifrost gateway](https://docs.getbifrost.ai/quickstart/gateway/setting-up)，在 gateway 設定 provider 憑證，再設定 client：

```bash
export OPENAI_BASE_URL="http://localhost:8080/v1"
export OPENAI_MODEL="openai/your-tool-capable-model"
# Gateway 需要驗證時才設定；provider key 通常由 Bifrost 管理。
export OPENAI_API_KEY=""

pixi run start --tools read "讀取 README.md，說明這個專案的架構"
pixi run start --workspace /absolute/path/to/your/project \
  "讀取程式，修正問題，並用 bash 執行相關測試"
```

將 model 換成你在 Bifrost 設定的 `provider/model`。直連其他 OpenAI-compatible 服務也可，只需調整 base URL、model 與 API key。Base URL 包含服務所需前綴（例如 `/v1`）；程式只附加 `/chat/completions`。模型必須支援 function tool calling。`.env.example` 是 shell 設定範例，程式不會自動載入 `.env`。

## 先讀哪裡

```text
src/main.mojo       CLI → configuration → agent
src/config.mojo     少量明確的 CLI 參數
src/agent.mojo      訊息歷史 → 模型 → 工具 → 下一輪
    ├── client.mojo     OpenAI request 與完整性檢查
    └── tools.mojo      read / write / edit / bash
src/tools.json      模型看到的四個工具規格
src/support/
    ├── files.mojo      原生文字 I/O 與路徑檢查
    ├── json.mojo       有深度限制的 JSON 解析／序列化
    ├── process.mojo    POSIX 程序、pipe、poll、timeout
    └── http.mojo       有界的 curl 傳輸
```

從 [逐步教學](docs/learning.md) 開始，再讀 [架構與擴充](docs/architecture.md)。先看核心流程，再進入 `support/` 的基礎設施。每一步都使用同一套程式，避免維護多份逐漸失同步的 agent。

WebUI 與桌面版的選型及分階段設計見 [WebUI 與 Desktop 規劃](docs/web-desktop-ui-plan.md)；目前是規劃，不代表已提供 Web 服務或桌面應用程式。

## 四個工具

| 工具 | 行為 | Mojo 練習重點 |
|---|---|---|
| `read` | UTF-8 文字、1-based 行號、行數與輸出上限 | 字串、檔案 I/O、錯誤處理 |
| `write` | 建立／完整覆寫檔案；父目錄須已存在 | 參數驗證、寫入行為 |
| `edit` | 舊文字必須唯一匹配才替換；新文字可為空 | 比對、歧義檢查、可預期修改 |
| `bash` | 工作目錄內執行命令；回傳輸出、退出碼、逾時狀態 | 程序、逾時、輸出管理 |

- `read` 預設從第 1 行讀取 200 行，最多回傳 16,000 個 Unicode code points。`truncated` 表示後續內容省略；超出 EOF 回傳空內容。行分隔以 LF 為準。
- 檔案工具最多處理 1 MiB UTF-8 文字，拒絕 NUL。`read`／`edit` 拒絕無效 UTF-8；`edit` 保留未修改部分，包括 CRLF。
- `edit` 的零次、多次與重疊匹配都不會寫入；空的 `old_text` 不接受。`write` 不自動建立目錄，可透過 bash 建立。
- `bash` 預設逾時 30 秒（最多 300），保留 16,000 bytes 輸出（最多 100,000）。超出部分持續 drain 但丟棄；無效或截斷 UTF-8 以 replacement character 解碼。
- bash 合併 stdout／stderr。非零 `exit_code` 表示命令失敗；被 signal 終止則是負的 signal number。逾時另回傳 `timed_out: true`。
- 工具錯誤以 `{"ok": false, "error": "..."}` 傳回模型；模型連線／協定錯誤則停止程式。最多 20 次模型請求，可用 `--max-turns 40` 調整。

這是具有檔案修改與 shell 權限的本機 agent。檔案工具檢查 workspace 路徑與 symlink，但 **bash 不是 sandbox**，仍可存取其他路徑、網路與環境變數；請在可信任的工作環境使用。寫入直接覆寫，沒有交易、備份或並行編輯保護，適合在 Git 工作目錄操作。

## 開發

```bash
pixi run format
pixi run test
pixi run build
pixi run ./build/mojo-agent --help
```

編譯後的 executable 與 `tools.json` 放在 `build/`。仍需 Pixi 環境中的 Mojo runtime 與 curl，因此使用 `pixi run` 啟動。

測試會編譯真正的 Mojo 程式，驗證檔案、JSON、CLI、子程序清理，並啟動 **Mojo 寫的本機 HTTP 假模型**，讓真正的 curl 呼叫串起四個工具與多輪訊息。CI 在 macOS ARM64 與 Linux x86-64 執行相同測試。ARM64 Linux 有鎖檔，目前未設 CI runner。

專案不直接依賴或呼叫 Python；Mojo 工具鏈本身可能包含 Python 等傳遞依賴。

第一版採用單一任務、非串流、依序執行工具。REPL、session 持久化、context 壓縮、自動重試與 plugin 系統可沿既有邊界逐步加入。

MIT License.
