## Why

目前 CLI 每次只能提交一個任務，模型回應需等整個 HTTP request 完成才顯示；無法在同一段對話追問，也難以觀察 agent 的執行進度。下一階段加入可逐步閱讀與練習的 Mojo 原生互動迴圈及真正串流，讓學習路徑從單次 tool loop 延伸到 session 狀態與增量資料解析。

## What Changes

- 新增逐行互動 CLI：終端機無 prompt 時進入互動模式，也可用 `--interactive` 明確啟用；同一次執行保留對話與工具結果。
- 提供 `/help`、`/clear`、`/exit`，正確處理空行、EOF 與 Ctrl-C；首版採用終端機既有的行輸入行為。
- 互動模式預設 streaming；單次 prompt 維持目前非串流預設，兩者皆可用 `--stream`／`--no-stream` 明確選擇。
- assistant 文字寫入 stdout，互動提示、工具狀態與錯誤寫入 stderr；既有擷取工具提示的腳本需改讀 stderr。
- 使用 Chat Completions SSE 增量接收與顯示文字，處理跨資料區塊的 UTF-8、SSE 分隔與 tool-call arguments；不加入人為延遲的打字動畫。
- 工具呼叫先完整組裝與驗證，再依序執行；串流未完成時不執行該次模型回應中的工具。保留既有工具權限、錯誤結果與資源上限。
- 模型、協定或回合上限錯誤後保留已完成的工具副作用，不自動重試；互動模式提示先 `/clear` 開始新對話。
- 以純 Mojo 測試與本機 mock server 驗證多輪互動、串流時序、工具呼叫及失敗清理，補上循序學習文件。

## Capabilities

### New Capabilities

- `interactive-cli`: 模式選擇、記憶體 session、互動指令、輸出分流、失敗後的 session 狀態與結束方式。
- `streaming-chat-completions`: 有界 SSE 傳輸、文字增量輸出、工具片段組裝、完成條件與錯誤處理。

### Modified Capabilities

無；目前 `openspec/specs/` 尚無既有規格。本次以新增 capability 描述新行為及其必要的相容性要求。

## Impact

- CLI 與 loop：`src/config.mojo`、`src/main.mojo`、`src/agent.mojo`；新增簡潔的互動與終端機 I/O 模組。
- 協定與傳輸：`src/client.mojo`、`src/support/http.mojo`、`src/support/process.mojo`；新增獨立 SSE parser，沿用 `support/json.mojo`。
- 驗證與教學：`tests/test_agent.mojo`、`tests/mock_server.mojo`、必要的新 Mojo 測試模組、`README.md`、`docs/learning.md`、`docs/architecture.md`。
- 沿用 Pixi、Mojo 1.0.0 與 curl；不新增 Python、Node.js runtime、SDK、TUI framework 或原生 TLS 實作。執行平台仍為 macOS／Linux，Windows 使用 WSL。
- 本次不含 session 落盤／恢復、context 壓縮、工具輸出串流、全螢幕 TUI、歷史按鍵／補完、多行編輯、自動重試或 Ctrl-C 後接續同一任務。
