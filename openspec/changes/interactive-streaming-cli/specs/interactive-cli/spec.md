## Purpose

讓使用者在同一次 CLI 執行中逐行提交任務、追問及管理記憶體中的對話，並清楚區分回答、工具狀態與失敗情況。保留既有單次 prompt 工作方式，提供可觀察、可離線驗證且適合學習的互動行為。

## ADDED Requirements

### Requirement: Explicit and automatic interaction modes

CLI SHALL 在沒有 positional prompt 且 stdin 為 TTY 時進入互動模式；`--interactive` SHALL 明確啟用互動模式，並允許從 pipe 逐行讀取。提供 positional prompt 而未指定 `--interactive` 時 SHALL 維持單次任務模式；指定 `--interactive` 並提供 prompt 時 SHALL 先執行此 prompt，再讀後續輸入。`--help` SHALL 不需要模型設定且不發送 request。

#### Scenario: Start an interactive terminal session
- **WHEN** stdin 為 TTY，模型設定有效，且沒有 positional prompt
- **THEN** CLI 顯示輸入提示並等待使用者送出一行，不因缺少 prompt 而報錯

#### Scenario: Preserve a one-shot invocation
- **WHEN** 使用者執行 `mojo-agent "hello"` 且設定有效
- **THEN** CLI 只執行該任務，成功後以 exit code 0 結束，不讀下一行

#### Scenario: Script explicit interactive input
- **WHEN** 使用者以 pipe 提供多行輸入並指定 `--interactive`
- **THEN** CLI 依序處理每行，且一次只有一個使用者任務進行中

#### Scenario: Do not implicitly consume redirected input
- **WHEN** stdin 不是 TTY，沒有 positional prompt，也沒有 `--interactive`
- **THEN** CLI 以 exit code 1 顯示需要 prompt 或 `--interactive` 的用法，不等待或呼叫模型

#### Scenario: Reject an explicitly empty positional prompt
- **WHEN** 使用者明確提供空字串或全空白的 positional prompt
- **THEN** CLI 回報參數錯誤，不把它視為省略 prompt

### Requirement: Predictable streaming selection

CLI SHALL 在互動模式預設開啟 streaming，在單次模式預設關閉 streaming。`--stream` 與 `--no-stream` SHALL 可覆寫任一模式的預設，且兩者同時出現時 SHALL 在發送 request 前回報參數錯誤。現有 model、base URL、workspace、tools 與 max-turns 設定 SHALL 在兩種模式沿用。

#### Scenario: Choose the default for each mode
- **WHEN** 未指定 streaming flags，分別進行互動任務與單次任務
- **THEN** 前者的模型 request 使用 `stream: true`，後者使用 `stream: false`

#### Scenario: Override a mode default
- **WHEN** 互動模式帶 `--no-stream`，或單次模式帶 `--stream`
- **THEN** CLI 分別以完整回應或 SSE 方式處理該模式中的每次模型 request

#### Scenario: Reject conflicting streaming flags
- **WHEN** 同一指令同時包含 `--stream` 與 `--no-stream`
- **THEN** CLI 以 exit code 1 結束，且不發送任何 HTTP request

### Requirement: Session history across user submissions

互動 CLI SHALL 保留同一次執行中已接受的 user messages、完整 assistant messages 與 tool results；system message SHALL 只初始化一次。成功的最終回答 SHALL 在下一次使用者提交時出現在歷史中。`--max-turns` SHALL 限制每次使用者提交內的模型 request 次數，並在下一次提交重新計數。

#### Scenario: Follow up on a completed answer
- **WHEN** 第一個問題已得到完整回答，使用者再提交第二個問題
- **THEN** 第二個 request 依序包含一個 system message、第一個 user、完整 assistant 回答與第二個 user

#### Scenario: Follow up after tool execution
- **WHEN** 第一個任務曾執行工具後完成，使用者再追問
- **THEN** 後續 request 保留 assistant tool_calls、依序且各自配對的 tool_call_id 結果及最終回答

#### Scenario: Reset the request budget for a new submission
- **WHEN** 第一個任務在 `--max-turns` 上限內成功，接著提交第二個任務
- **THEN** 第二個任務享有相同的完整上限，不扣除上一個任務使用的 request 次數

### Requirement: Local session commands and bounded line input

CLI SHALL 提供 `/help`、`/clear`、`/exit`；指令以去除前後空白後的完整一行判斷。空白行、指令與未知 slash command SHALL 不發送模型 request。`/clear` SHALL 只重設對話為原 system message，不改 model、workspace、tools、streaming 設定或磁碟檔案。一般非空白輸入 SHALL 保留原文字，僅移除行尾分隔；每行 SHALL 限制在 1 MiB UTF-8 bytes 內，拒絕 NUL 與無效 UTF-8。

#### Scenario: Local commands do not invoke the model
- **WHEN** 使用者輸入空白行、`/help` 或 `/unknown`
- **THEN** CLI 分別重新提示、顯示用法或顯示未知指令錯誤，歷史與 HTTP request 數保持不變

#### Scenario: Clear the conversation without undoing files
- **WHEN** 某次任務已寫入檔案，使用者輸入 `/clear` 再提交問題
- **THEN** 新 request 只包含原 system message 與新 user message，先前檔案內容及工具設定保持不變

#### Scenario: Reject invalid or oversized input and resume reading
- **WHEN** 一行包含 NUL、無效 UTF-8 或超過 1 MiB
- **THEN** CLI 顯示輸入錯誤、丟棄該行剩餘內容，並能讀取下一行；無模型 request 或歷史變更

### Requirement: Separate answers from interface output

CLI SHALL 將 assistant 回答寫入 stdout，將輸入提示、指令回饋、工具開始／結束狀態及錯誤寫入 stderr。增量文字 SHALL 僅輸出一次，結束回應後 SHALL 不重印完整答案；在顯示工具狀態或下一個 prompt 前 SHALL 結束尚未換行的回答。工具狀態 SHALL 包含工具名稱與成功／失敗，不輸出原始 arguments、工具結果 body 或 API key。首版 SHALL 使用一般文字行，不需要 ANSI 畫面控制。

一般工具 SHALL 以 `ok` 判斷執行狀態；bash SHALL 同時滿足 `ok: true`、`exit_code: 0` 與 `timed_out: false` 才顯示成功。此顯示判斷 SHALL 不改變送給模型的 tool result 格式。

#### Scenario: Finish a streamed reply once
- **WHEN** 模型依序輸出「你好」與「，Mojo」，最後正常完成
- **THEN** stdout 依序顯示「你好，Mojo」一次，並在需要時補一個行尾，不重複完整回答

#### Scenario: Display tool progress between model responses
- **WHEN** 模型輸出文字後要求工具，工具執行完成後模型繼續回答
- **THEN** stderr 可見工具開始與完成狀態，stdout 只含 assistant 文字，狀態和後續 prompt 不黏在未結束的回答行上

#### Scenario: Redirect answers for a script
- **WHEN** 使用者將 stdout 導向檔案，且任務包含工具執行或錯誤
- **THEN** 檔案不包含互動提示、工具狀態或錯誤診斷；失敗的單次任務仍以非零碼結束

#### Scenario: Report a failed bash command accurately
- **WHEN** bash 回傳 `ok: true`，但 `exit_code` 非零或 `timed_out: true`
- **THEN** stderr 顯示工具失敗，模型仍收到原本的結果並可繼續修正

### Requirement: Explicit recovery after an interrupted task

模型連線、回應協定、request 大小或回合上限錯誤 SHALL 結束目前任務，不自動重試、不追加未完成的 assistant response、不回滾已完成工具的磁碟副作用。互動 CLI SHALL 顯示錯誤並進入需要清除的狀態，僅接受 `/help`、`/clear`、`/exit` 或 EOF；一般 prompt SHALL 被拒絕直到 `/clear`。工具回傳的 `ok: false` SHALL 仍作為 tool result 交給模型修正，不單獨觸發需要清除的狀態。

#### Scenario: Fail after earlier tools have succeeded
- **WHEN** 工具已成功寫入檔案，但下一個模型 request 失敗
- **THEN** CLI 明確指出任務未完成且已執行操作未復原，不再自動呼叫模型，保留已完成的歷史記錄並提示 `/clear`

#### Scenario: Resume only after an explicit clear
- **WHEN** CLI 需要清除時收到一般文字，之後依序收到 `/clear` 與新問題
- **THEN** 一般文字不觸發 request；清除後的新問題可正常執行且不帶上失敗任務的歷史

#### Scenario: Recover from a tool-level error inside the same task
- **WHEN** 模型呼叫停用的工具或給出無效工具 arguments
- **THEN** 模型收到 `ok: false` 的 tool result 並可在上限內繼續，不要求使用者清除 session

### Requirement: Clean session termination and input ownership

`/exit` 與等待輸入時的 EOF SHALL 正常以 exit code 0 結束；EOF 前若有未換行的非空白末行，SHALL 先處理該行。Ctrl-C SHALL 終止 CLI、清理目前受管理的子程序與暫存資源後以 exit code 130 結束，不繼續呼叫模型或執行下一個工具。工具子程序 SHALL 不讀取 REPL 的 stdin；單次任務的設定或模型錯誤 SHALL 維持 exit code 1。

#### Scenario: Exit without a model request
- **WHEN** 等待輸入時收到 `/exit` 或空的 EOF
- **THEN** CLI 正常結束，沒有額外模型 request

#### Scenario: Consume a final line before EOF
- **WHEN** 明確互動模式的 pipe 在有效問題後直接 EOF，沒有末尾換行
- **THEN** CLI 完成該問題後正常結束

#### Scenario: Interrupt while streaming or running a tool
- **WHEN** 使用者在串流讀取或工具執行期間按 Ctrl-C
- **THEN** CLI 停止接收與執行，回收其管理的子程序 process group 及暫存資源，並以 130 結束

#### Scenario: Preserve the next input line while a tool runs
- **WHEN** pipe 已送入下一行問題，而目前 bash 工具嘗試讀取 stdin
- **THEN** 工具讀到 EOF，下一行問題仍由 CLI 在目前任務結束後處理

#### Scenario: Stop a tool batch after interruption
- **WHEN** 一個已驗證的 response 包含兩個工具，第一個執行時收到 Ctrl-C
- **THEN** 第二個工具完全不執行，也不發送下一個模型 request，CLI 清理後以 130 結束
