# 架構與擴充

目標是讓初學者從入口一路追到副作用，不需要先理解框架。程式按責任切分；四個工具使用明確的 if 分派，沒有 registry、event bus 或多層繼承。

## 架構圖

- [目前實作架構](diagrams/current-architecture.html)：單次 prompt、非串流、記憶體內 tool loop。
- [目標架構](diagrams/future-architecture.html)：加入 REPL、session 持久化、context 管理、重試與擴充機制後的建議設計。
- [WebUI 與 Desktop 規劃](web-desktop-ui-plan.md)：Svelte 5／Tauri 2 選型、共用事件協定、安全邊界與分階段驗收；目前尚未實作。

目標架構中的「⚑ 尚未實作」節點是規劃，不代表目前程式已具備這些能力。圖中的 SRC 連結指向目前程式或 `docs/architecture.md` 的擴充方向；candidate JSON 位於 `docs/diagrams/`，可在 Repository authoring 驗證後重建 HTML。

## 責任邊界

| 模組 | 擁有的責任 | 擴充方向 |
|---|---|---|
| `main` / `config` | CLI 與設定 | REPL、輸入方式 |
| `agent` | 訊息歷史、回合、工具結果關聯 | session、context 壓縮、事件 callback |
| `client` | 模型 request 與完整性驗證 | usage、串流、重試策略 |
| `tools` | 參數驗證、四個工具、統一結果 | 改善工具內部 |
| `tools.json` | 模型看到的規格 | 參數說明與 schema |
| `support/files` | 文字 I/O 與路徑 | 寫入策略 |
| `support/process` | 有界程序執行 | 程序政策、取消 |
| `support/http` | curl 傳輸 | 需要時換成原生 HTTP library |
| `support/json` | JSON 值與語法 | 需要時換成成熟的 Mojo JSON library |

全部邏輯與測試都使用 Mojo。`curl` 提供成熟的 TLS／HTTP 傳輸；POSIX C ABI 是作業系統邊界。選擇這個組合，是為了避免把 TLS 實作放進教學範圍，同時讓程序、逾時與輸出管理保留為 Mojo 練習。

JSON 使用小型、擁有原始文字的值，而非 recursive heap tree。方法只做這個 agent 需要的讀取與 builder 操作，解析支援 Unicode surrogate pair、保留數字文字、拒絕重複 key，深度最多 64。`Json(raw)` 用於程式自己建立的有效 JSON，外來輸入必須先 `Json.parse()`；builder 的 `add`／`append` 只用於正確的 object／array，`add` 不覆寫既有 key。資料越大，重複解析與複製成本越明顯；第一版優先易讀而非 throughput。

## 失敗的分類

工具參數錯誤、檔案不存在、edit 歧義都回傳 tool message，模型可以修正。HTTP 錯誤、無效模型格式、不完整 tool response 與回合上限則以非零碼結束 CLI。curl 錯誤只回報退出碼，不回顯 gateway 的錯誤 body。

同一輪工具依序執行，因此 write → read → edit 的依賴關係可預期。執行前先驗證整輪 tool call 的基本格式與唯一 ID；工具參數個別驗證並回傳錯誤。整輪不是交易，前面的成功操作不會因後面的失敗回滾。

HTTP request 最多 16 MiB、response 最多 4 MiB、每輪最多 16 個工具，設定最多 100 輪。模型歷史仍可能超過 context，第一版會回報服務錯誤，沒有自動摘要。curl deadline 120 秒，程序層再以 125 秒上限清理；不自動跟隨 redirect。

## 往可擴充 agent 前進

依真實需求逐項加入：

1. 讓 `agent` 暴露訊息歷史，CLI 建立 REPL 與保存 session。
2. 在 `client` 保留 usage，先量測 context，再設計裁切／摘要。
3. 將進度輸出改成很小的 callback，讓 TUI 或 logging 共用同一個 loop。
4. 若需要執行前審核，在 tool dispatch 前加 policy hook，不把 UI 混入工具。
5. 在 transport 確有第二種需求時加入 adapter；provider 差異先交給 Bifrost。

四個工具可以一直保留。大部分新功能應加入 session、UI、模型連線或執行政策層，讓核心維持小而穩定。

## 邊界與限制

workspace 檢查避免意外路徑越界，無法防禦硬連結、路徑競態或惡意並行程序。檔案直接覆寫，I/O 期間失敗可能留下部分內容，尚未提供 atomic write／backup。

bash 使用使用者環境與權限；process group 清理不等同容器隔離，另行建立 session 的子程序可能逃離 group。不支援互動程式、長期 background service 或外部取消協定。`process.mojo` 使用 POSIX ABI，適用 macOS／Linux，不支援原生 Windows。

需要隔離或交易式寫入時，先加入獨立的執行環境／寫入策略，再保持四個工具介面不變。

## 參考

- [Mojo 安裝與 Pixi](https://mojolang.org/install/)
- [Mojo C FFI](https://mojolang.org/docs/manual/c-ffi/)
- [Mojo 字串](https://mojolang.org/docs/std/collections/string/string/String/)
- [Bifrost Request Options](https://docs.getbifrost.ai/providers/request-options)
- [Bifrost OpenAI SDK 相容介面](https://docs.getbifrost.ai/integrations/openai-sdk/overview)
- [curl 使用手冊](https://curl.se/docs/manpage.html)
