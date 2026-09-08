## Context

動機見 [proposal.md](proposal.md)。此變更橫跨 CLI、對話生命週期與 transport，需要先固定 ownership 與完成條件。

已確認的程式現況：

- `config.parse_args()` 將所有 `--` 選項視為帶值選項，且最後拒絕空 prompt；boolean flags 必須在取下一個 argument 前處理。
- `main.main()` 載入與篩選 tool schemas 後只呼叫一次 `agent.run()`。工具提示及錯誤目前都使用 stdout。
- `agent.run()` 每次重建 system + user messages，最終 content 直接 return，沒有 append 最終 assistant；工具 assistant 與對應 results 則已存入歷史。
- `client.request_body()` 固定 `stream: false`；`assistant_message()` 已集中處理完成原因、最多 16 個工具及唯一 ID 的驗證。
- `support.http.post_json()` 使用私有 request/config 暫存檔與 curl，request 上限 16 MiB，response 上限 4 MiB，curl deadline 120 秒，程序 deadline 125 秒。
- `support.process.run_command()` 已有 `fork`／`poll`／process group／`waitpid` 的 Mojo 實作，但 stdout/stderr 合併、收集到 EOF 才回傳，最後使用 lossy UTF-8 decode。child stdin 為 `/dev/null`。
- 現有 Mojo `MockServer` 逐個回覆完整 JSON；`test_loop`、`test_recovery_and_limits` 與 `test_compiled_cli` 可延伸為新的離線整合驗證。

## Goals / Non-Goals

**Goals:**

- 用同步、逐層可追蹤的資料流連接 REPL、session、SSE、terminal，讓每一層都能單獨練習與測試。
- 將「已顯示的文字」與「已驗證並可寫入 history／執行工具的 message」分開，維持串流下的完整性。
- 沿用既有 runner 的子程序清理和工具語意，避免形成兩套程序控制邏輯。

**Non-Goals:**

- 不建立 async runtime、event bus、plugin registry 或多模型 transport framework。
- 不模擬 tokenizer；顯示單位是模型提供的 content delta，並非保證逐 token 或逐字。
- 不讓 bash 工具變成互動 shell，不處理已脫離受管理 process group 的 daemon。
- 不恢復失敗任務、不清除已印出的文字、不回滾檔案；使用者以 `/clear` 開始新 session。

## Decisions

### 1. 互動模式與相容性在 CLI 層決定

模式表是使用者未指定細節時的預設選擇：

| 輸入 | 模式 | 預設 stream |
|---|---|---|
| positional prompt | 單次 | 關閉 |
| 無 prompt，stdin TTY | 互動 | 開啟 |
| `--interactive`，任意 stdin | 互動 | 開啟 |
| `--interactive "first question"` | 先執行首輪，再互動 | 開啟 |
| 無 prompt，非 TTY，無 `--interactive` | 用法錯誤 | 不發 request |

`parse_args` 另外記錄 prompt 是否有提供，避免 `""` 與省略 prompt 混淆；以顯式的 `stdin_is_tty` 輸入或獨立 mode resolution 保持 parser 可測。新增 flags 在帶值選項之前解析，兩種 streaming flags 同時出現直接拒絕。`--max-turns` 的 help 說明改為「每次使用者任務的模型 request 上限」。

選擇保留單次預設，是因既有腳本與教學使用完整 JSON endpoint；互動預設 stream 直接符合本輪體驗。相較要求所有使用者額外加 `--interactive`，TTY 自動判斷更容易開始；pipe 則要求明確啟用，避免無意消耗輸入。`--interactive` 的 initial positional prompt 是一般問題，不走本地 slash-command dispatcher。

### 2. Session 由 REPL 擁有，agent 執行一次提交

新增 `src/repl.mojo`，由它持有 `Json` messages 與簡單狀態 `ready`／`needs_clear`。`agent.mojo` 提供只有 system 的初始化，以及接收 `mut messages`、prompt 與輸出接收器的單次提交入口；舊 `run(config, schemas)` 保留為單次 wrapper，降低既有測試改動。

每次提交先 append user，再進入現有有界迴圈。每個完整、驗證通過的 assistant 只 append 一次；有工具時 append assistant 後依序 append tool results，無工具時 append 最終 assistant 再回傳。`max_turns` 是單次入口的區域計數器。

沿用 `Json` 可聚焦 `mut`、ownership、String 與 List，不額外建立可序列化 session 模型。代價是長對話會增加 JSON 複製成本；每次 request 建立時繼續執行 16 MiB 檢查，超限後走需要清除的流程，不偷偷裁掉歷史。首版不宣稱固定總 RAM 用量。

### 3. 任務失敗後需要明確清除

REPL 的狀態轉換：

```text
ready -> submit -> complete -> ready
               -> request/protocol/limit failure -> needs_clear
needs_clear -> /clear -> system-only history -> ready
ready or needs_clear -> /exit or EOF -> exit 0
any active state -> SIGINT -> cleanup -> exit 130
```

工具本身的 `ok: false` 繼續回到模型；只有離開 agent 的任務級錯誤會令 session 需要清除。保留已記錄的完整 assistant/tool messages，但不把未完成的模型 response 放進 history。未知輸入、空白行與本地命令不改變此狀態。

選擇 `needs_clear` 而不做歷史 rollback 或自動修補，是因先前工具可能已修改檔案，且例外可能落在工具批次中途。這個狀態避免發出懸空 tool_call 的 history，也避免模糊地繼續半個任務。`/clear` 提示只清除對話、已執行操作未復原；正常 `/exit` 或 EOF 仍為 0，即使之前曾有已顯示的任務錯誤。單次任務失敗維持 1。

### 4. 原生逐行輸入與單一輸出接收器

新增 `src/support/terminal.mojo`，以 Mojo byte buffer、原生 I/O 及必要 POSIX C ABI 處理 stdin、`isatty`、stdout/stderr 與 SIGINT。保留 terminal canonical mode，不改 raw mode、不接管方向鍵。line reader 區分空行與 EOF，支援 LF／CRLF 與 EOF 前未換行末行；以 1 MiB bytes 為上限，超限持續 drain 到行尾再回報。只對完整行作嚴格 UTF-8 decode。

在 `src/output.mojo` 定義小型同步輸出接收器介面，具備文字片段、模型回應結束、工具開始與工具結果四種明確操作。CLI 實作放在 terminal 模組，負責寫到正確 fd、必要行尾與即時寫出；測試使用記憶體接收器。介面只服務這些實際事件，不引入事件註冊或任意 payload。Mojo 標準 I/O／Writer 能直接表達的部分先使用；需要控制 fd 與讀寫錯誤時才包裝 `external_call`。

stream client 只交付 content，不直接 `print`；`main` 不再無條件 `print(run(...))`。buffered CLI 將最終回答交付一次；stream CLI 將每個 content delta 交付一次，最終只補必要換行。工具事件不輸出 arguments 或結果 body，原本 `append_results` 的 `print` 改由接收器處理。連接到同一個 terminal 時，先完成 stdout 寫出再顯示 stderr 狀態。

一般工具以 `ok` 判斷完成狀態；bash 還要 `exit_code == 0` 且 `timed_out == false` 才顯示成功。現有 bash 的 envelope `ok: true` 代表 dispatcher 成功回傳結果，不代表命令成功；此處只調整呈現，不改工具結果契約。

這比在 client 直接印字多一個小介面，但能隔離測試、保持單次 wrapper 安靜，並避免 final 重印。輸出 fd 失敗屬終止條件：停止 request 並清理，而非繼續執行工具。

父程序忽略 SIGPIPE，讓關閉的 stdout pipe 以 write error 回到正常清理路徑；child exec 前恢復預設 SIGPIPE。stdout／stderr 寫入失敗時不再嘗試維持 REPL，清理後以非零碼退出。

### 5. 將現有 runner 拆成可逐步讀取的同步 reader

在 `support/process.mojo` 保留一套 spawn／poll／waitpid／process-group cleanup 核心，提供可取回原始 byte chunks 的 reader。`run_command()` 變成它的 bounded capture wrapper，保留原有合併 stdout/stderr、輸出截斷後繼續 drain、逾時與 lossy decode 語意。

HTTP streaming 使用同一 reader，但只讀 stdout；curl stderr 導向 `/dev/null`，依 exit code 產生既有風格的簡短診斷。這比新增第二條 stderr pipe 更簡單，且與目前不回顯 transport body 的行為一致。reader 的 chunks 保持 bytes，SSE 不可使用 `String(from_utf8_lossy=chunk)`。

新增 `post_sse` 與私有的共享 curl 設定建構。串流使用 `--no-buffer`、`Accept: text/event-stream` 與 `--include --suppress-connect-headers`；HTTP 層先解析有界 header blocks（最多 64 KiB），略過合法 1xx，要求最終 HTTP 200 且 media type 為 `text/event-stream`（接受 charset 參數）。只有 body bytes 進入 SSE parser。不跟隨 redirect，保留協定限制、私有 request/config、憑證不放 argv、curl `--fail` 與現有 deadlines。

HTTP 層逐次計算 response body bytes，含 framing／keepalive，超過 4 MiB 立即失敗；不依賴 Content-Length 或 curl 單獨實作上限。各 parser buffer 與組裝訊息都受這個每次 response 上限約束，不另保存整份 SSE transcript。deadline 不因 chunk 到達而重置。

採同步 reader 而不使用 background thread、FIFO 輪詢檔案或 async，是為了讓資料與資源生命週期仍能逐行追蹤。TLS 仍交給 curl；「Mojo 原生」指 CLI、session、parser、工具與測試由 Mojo 實作，延續目前架構。

### 6. SSE framing 與 Chat Completions 組裝分層

新增 `src/support/sse.mojo` 只負責 bytes 到 data event：處理開頭 BOM、LF／CRLF／CR、跨 read 的 delimiter、空白行 dispatch、data 多行串接、comment 與未完成 EOF。嚴格 UTF-8 驗證在完整行／事件邊界進行，不把網路切塊當成 JSON 或文字邊界。

`client.mojo` 增加串流 accumulator，消費 data event：

1. 完整 data 為 `[DONE]` 時記錄結束標記；其餘用既有 `Json.parse()` 驗證。
2. 拒絕頂層 error 與必要欄位型別錯誤；只處理 choice index 0，接受 role-only、空 delta、null content 與 usage-only 事件。
3. 累積 content 並同步交付輸出接收器；以最多 16 個 slot，依 tool index 累積 name／arguments，id／type 採首次非空值並要求後續值一致。
4. 記錄合法 finish reason；之後只容許空 delta／usage／metadata，禁止新增內容。`[DONE]` 後若仍有額外 data 事件，視為協定錯誤；comment／空白可忽略。
5. HTTP 完成且 curl 成功後，以累積欄位建構與 buffered response 相同的 assistant 結構，共用 `assistant_message()` 的完成驗證，再交回 agent。補上 streaming 必要的 index／空名稱檢查；參數 JSON 留到現有 `tool_result` 驗證。

真正執行工具必須在此函式成功 return 之後。即使先收到 `finish_reason: tool_calls` 或看似完整的 arguments，也不提前 dispatch。對同一 request，`[DONE]`、合法 finish reason、傳輸成功三者缺一不可。

這個完整性選擇會拒絕少送 finish reason 或 `[DONE]` 的相容 endpoint；使用者可明確改用 `--no-stream`，不自動 downgrade 或 retry。原生 Responses API 不在此協定範圍。

### 7. Ctrl-C 僅作可清理的終止

CLI 的 native SIGINT handler 僅記錄中斷旗標，不分配記憶體、不寫 UI、不丟例外。line reader 與 process poll loop 檢查中斷，並在新 request、工具 dispatch 及最後返回前檢查旗標；由一般執行路徑向外傳遞中斷並展開 Mojo 資源生命週期，待 Child 與 TemporaryDirectory 清理後才在最外層 exit 130。

必須將中斷與一般 `ok: false` 工具錯誤分開：既有 `tool_result` 捕捉一般 Error，因此 agent 在 dispatch 後也須檢查中斷旗標，不能再把中斷當成可修正結果發給模型。多次 Ctrl-C 不應繞過清理；`poll/read/write/waitpid` 對 EINTR 的處理要與中斷狀態一致。child exec 前恢復預期 signal 狀態與原有 stdin `/dev/null`。

保留最小 SIGINT handling，是因現有 child 會切到獨立 process group，單靠作業系統終止 parent 不保證它們被回收。相較支援取消後續聊，此設計只需要一條退出路徑；不承諾撤回已完成的 write/edit。

### 8. 離線測試直接證明串流時序

擴充 Mojo `MockServer` 回應模式：JSON fixture 繼續可用，另提供 `text/event-stream` 的 byte fragments、interim headers、狀態碼、正常／提早關閉及同步閘門。fixture 記錄 request，允許測試端讀到 CLI prefix 後才放行剩餘 response；閘門有 timeout，避免測試永久卡住。不得只在完整輸出後比對字串，或依靠固定短 sleep 推測串流有效。

分三層驗證：

- 純 parser／accumulator 測試覆蓋切塊、中文、CRLF、多 data、usage、工具交錯與完成規則。
- 真正 curl + mock server 驗證早到 prefix、HTTP header/stderr 隔離、無 Content-Length 的上限、截斷與零提前工具副作用。
- compiled CLI 以 pipe 輸入多輪對話，另以 Mojo 原生 PTY fixture 驗證 TTY 自動模式、prompt 與 Ctrl-C；分開擷取 stdout/stderr，驗證 history、clear、budget、工具 stdin 隔離、exit code 與 child/temp cleanup。

逾時的測試可使用 transport 內部可注入的較短 deadline，但正式預設仍由測試確認是 120／125 秒；parser 失敗、SIGINT 與 output fd 失敗都需確認不留受管理 child，HTTP 測試使用 fake credentials，不接真實 provider。

## Risks / Trade-offs

- [Mojo 1.0.0 的 FFI／ownership 細節] → 以既有 `Child` 為起點，先編譯 native I/O、SIGINT 與分段 reader 的小型驗證，再串入 client；不可直接套用 nightly 專用語法或因此升級工具鏈。
- [stdout 已出現前綴，後續才失敗] → 保留前綴並在 stderr 明示未完成，history 只收完整 response，單次失敗仍回傳非零碼。
- [相容 gateway 的 SSE 欄位不同] → 接受空 delta、usage、額外 metadata，嚴格完成規則保持一致，使用 `--no-stream` 作使用者選擇。
- [session 太長] → request 上限及 `/clear` 提供明確出口；不宣稱 token usage、context 自動壓縮或常數空間。
- [既有 stdout 擷取腳本包含工具提示] → README 明確記錄工具狀態與錯誤轉到 stderr；單次回答與預設非串流保留。
- [程序與 terminal 清理跨平台] → Linux x86-64 與 macOS ARM64 都跑 native fixture；WSL 用於 Windows 開發驗證。ARM64 Linux 維持目前未設 CI runner 的限制。

## Migration Plan

本次沒有資料格式或持久化遷移。先保留單次 wrapper 與既有測試，加入 byte reader／SSE，再接上 session 與 CLI；文件以 `pixi run start --interactive`、`pixi run start --stream "..."` 與 `--no-stream` 呈現三種練習入口。實作完成後同步更新 `openspec/config.yaml` 中已過時的「非串流／無 REPL」背景。

驗證使用既有 Pixi lock 與 Linux/macOS 的 `pixi run test`、`pixi run build` 及 CLI help smoke check。此 proposal 不需要變更依賴、不部署服務；如需回退功能，可回復這次實作變更，使用者資料沒有遷移需求。是否 commit／push 依另行授權處理。

## References

- [Bifrost Streaming Responses](https://docs.getbifrost.ai/quickstart/gateway/streaming)：Chat Completions 使用 content delta 與 `[DONE]`；設計將合法 finish reason 納入本專案完成契約。
- [SSE parsing standard](https://html.spec.whatwg.org/multipage/server-sent-events.html#parsing-an-event-stream)：framing 與多行 data 的參考；本專案不實作瀏覽器 EventSource 的自動重連。
- [OpenAI Function Calling — Streaming](https://developers.openai.com/api/docs/guides/function-calling#streaming)：工具 delta 依 index 累積的協定參考，未引入 SDK。
- [curl manual](https://curl.se/docs/manpage.html)：無緩衝輸出、headers 與 timeout 選項。
