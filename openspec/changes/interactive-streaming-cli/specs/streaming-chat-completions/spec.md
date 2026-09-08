## Purpose

讓 coding agent 在模型仍生成回應時顯示文字，同時維持完整回應驗證、工具執行順序與資源上限。此能力定義 Chat Completions SSE 的增量處理契約，避免傳輸切塊、截斷或工具參數片段導致錯誤文字或提前執行副作用。

## ADDED Requirements

### Requirement: Stream requests and deliver text before completion

串流模式 SHALL 向既有 base URL 的 `/chat/completions` 發送 `stream: true`，保留相同 model、messages、啟用的 tools 與驗證設定。收到完整有效的 `choices[index=0].delta.content` 字串時 SHALL 立即交付顯示，不等待 `[DONE]`、HTTP EOF 或整個任務完成，也不加入打字延遲；非串流模式 SHALL 繼續接受完整 JSON 回應。

#### Scenario: Observe a prefix while the server is still waiting
- **WHEN** 測試服務端送出一個完整文字 delta 事件，並等待測試端確認已讀到 CLI 的 stdout 後才送剩餘事件
- **THEN** CLI 在服務端送出 finish reason 與 `[DONE]` 前就輸出該文字，且最終內容無重複

#### Scenario: Keep request configuration consistent
- **WHEN** 同一組設定分別以串流及非串流方式執行
- **THEN** endpoint、model、messages、tools 與 Authorization 語意一致，只有 streaming 相關欄位與回應格式不同

### Requirement: Parse event framing independently of transport chunks

串流接收 SHALL 正確處理 UTF-8、LF／CRLF／CR 行尾、以空白行分隔的 SSE 事件、多個 `data:` 行以換行串接，以及任意傳輸切塊。SHALL 忽略串流開頭的單一 UTF-8 BOM、comment／keepalive 行及非 `data` 欄位；事件完整前 SHALL 不解析半段 JSON，也不以 replacement character 掩蓋無效 UTF-8。沒有 data 的事件 SHALL 不影響回應內容。

#### Scenario: Split Chinese text and event delimiters across reads
- **WHEN** 一個中文字的 UTF-8 bytes、JSON 字串與 CRLF 分隔分別跨越多次傳輸讀取
- **THEN** 最終文字與未切塊時相同，沒有亂碼、遺失或重複事件

#### Scenario: Process several events in one read
- **WHEN** 一次讀取包含多個完整事件與下一個事件的前半部
- **THEN** 依序處理完整事件，保留未完成部分等下次讀取

#### Scenario: Tolerate SSE metadata
- **WHEN** stream 含開頭 BOM、comment、`event:`／`id:` 行、空事件，以及以多個 data 行組成的有效 JSON
- **THEN** 只解析串接後的有效 data，不把 metadata 當成 assistant 文字

### Requirement: Assemble one assistant response from deltas

每次模型 request SHALL 只處理 choice index 0，忽略其他 choice；SHALL 依序累積文字片段，接受空 delta、`content: null`、單獨 role 與 `choices: []` 的 usage 事件。已出現的 role SHALL 為 assistant；必要欄位型別錯誤、JSON 語法錯誤或頂層 error SHALL 視為協定失敗。usage 與 provider 額外欄位 SHALL 不作為顯示文字或 history message。

#### Scenario: Accept role and usage without text
- **WHEN** stream 先包含 assistant role 與空 delta，之後有 choice 0 文字與合法 finish reason，最後包含 usage-only 事件及 `[DONE]`
- **THEN** 成功組裝一個完整 assistant message，不顯示 role 或 usage

#### Scenario: Ignore unrelated choices
- **WHEN** stream 同時包含 choice index 0 及其他 index 的文字
- **THEN** 只輸出及記錄 choice 0 的文字，不混合不同回答

#### Scenario: Reject an invalid payload without exposing its body
- **WHEN** data 不是有效 JSON、content 型別錯誤，或含頂層 error
- **THEN** request 失敗，診斷不包含原始 response body 或憑證，也不提交部分 assistant message

### Requirement: Assemble and validate tool calls before execution

串流 tool calls SHALL 以 `delta.tool_calls[].index` 累積，依序串接 function name 與 arguments 字串片段，保留一致的 id 與 type。索引 SHALL 為 0 到 15 的整數，完成時 SHALL 連續且沒有空缺；id SHALL 非空且在同一個 assistant response 內唯一，type SHALL 為 `function`，name SHALL 非空。整次模型回應達成完成條件且所有 tool-call 結構通過驗證前，SHALL 不執行其中任何工具。完成後 SHALL 依 index 順序沿用工具權限與逐工具 arguments 驗證。

#### Scenario: Interleave fragmented tool arguments
- **WHEN** 兩個 tool calls 的 arguments 與 function name 跨多個事件交錯到達
- **THEN** CLI 正確組裝每個 call，完成驗證後依 index 0、1 各執行一次，再以相符 tool_call_id 回傳結果

#### Scenario: Do not execute a seemingly complete early fragment
- **WHEN** 第一個工具的 arguments 已看似完整，但 stream 尚未達成完成條件
- **THEN** 該工具仍不執行，包括後續 stream 截斷或第二個 call 驗證失敗的情況

#### Scenario: Reject an invalid tool-call batch
- **WHEN** 完整回應包含重複 ID、缺少 ID／name、衝突的 id／type、負數或有空缺的 index，或超過 16 個 calls
- **THEN** 整次模型回應失敗，該批次任何工具均未執行

#### Scenario: Keep argument errors as tool results
- **WHEN** stream 已完整且 call 結構有效，但組裝後的 arguments 不是有效 JSON 或不符合工具參數
- **THEN** 該 call 產生 `ok: false` 的 tool result，且仍遵循現有依序執行語意

### Requirement: Require a complete protocol and transport result

成功的串流 response SHALL 同時具備 choice 0 的合法 finish reason、以完整 SSE 事件收到的 `[DONE]`、正常 HTTP 傳輸結束，以及通過完整 assistant 驗證。含工具的回應 SHALL 使用 `finish_reason: tool_calls`；無工具的回應 SHALL 使用 `finish_reason: stop` 並具有非空最終文字。finish reason 之後 SHALL 僅接受空 delta／usage／metadata 與 `[DONE]`；額外文字或工具片段 SHALL 視為失敗。

`[DONE]` 之後 SHALL 不再接受 data 事件，只可忽略 comment／空白。

#### Scenario: Fail a truncated completion
- **WHEN** EOF 前缺少 `[DONE]`、缺少合法 finish reason，或最後一個 SSE 事件未由空白行結束
- **THEN** request 失敗，即使已顯示部分文字也不把它當成完成回答，且該 response 的工具不執行

#### Scenario: Fail an incomplete model result
- **WHEN** finish reason 是 `length`／`content_filter`、與工具狀態不相符，或最後沒有任何有效文字／工具
- **THEN** request 失敗，不提交 assistant message 或執行工具

#### Scenario: Do not accept a valid marker after transport failure
- **WHEN** 已收到 finish reason 與 `[DONE]`，但 HTTP 傳輸稍後回報失敗
- **THEN** request 仍失敗，不執行該 response 的工具

### Requirement: Bound transfer and isolate diagnostics

每次 request body SHALL 維持 16 MiB 上限；串流 response body 的所有 bytes（包含 SSE framing 與 keepalive）SHALL 受 4 MiB 累計上限限制，不論是否有 Content-Length。HTTP request SHALL 保持 120 秒 deadline 與程序層 125 秒清理上限，收到片段 SHALL 不延長 deadline。HTTP status 錯誤、curl 診斷及非 SSE body SHALL 不混入 assistant 文字。任何 parser、輸出或傳輸失敗 SHALL 清理受管理的子程序、pipe 與私有暫存資料。

#### Scenario: Reject an unbounded event stream
- **WHEN** 沒有 Content-Length 的 stream 持續送出超過 4 MiB 的資料或未結束事件
- **THEN** request 被停止並回報大小錯誤，且不因等待事件分隔而持續增長記憶體

#### Scenario: Enforce the deadline despite keepalives
- **WHEN** 服務端持續送 keepalive 或文字但超過 request deadline
- **THEN** request 逾時，子程序在清理上限內被回收，不延長等待

#### Scenario: Keep HTTP failures private
- **WHEN** 服務端回傳 HTTP 401／500、非 SSE response，或 curl 回報 transport error
- **THEN** CLI 顯示適當的簡短診斷，不將私有錯誤 body、Authorization、curl stderr 或 HTTP headers 當成回答

### Requirement: No automatic fallback or replay

串流失敗時 SHALL 不自動重試 request、不降級發送非串流 request，也不重複執行先前成功的工具。診斷 SHALL 在格式不相容時提示可重新以 `--no-stream` 啟動。已顯示的部分文字 SHALL 保留於 terminal／stdout，但錯誤 SHALL 清楚標示該回答未完成；session 復原依 `interactive-cli` 的明確清除契約處理。

#### Scenario: An endpoint does not support streaming
- **WHEN** 要求 streaming 的 endpoint 回傳完整 JSON 或拒絕 streaming
- **THEN** CLI 報錯並指出 `--no-stream` 選項，不暗中發送第二次 request

#### Scenario: Fail after showing a visible prefix
- **WHEN** 已輸出部分文字後 stream 發生錯誤
- **THEN** stdout 不重播或刪除該文字，stderr 標示未完成，且沒有隱含 retry 或工具重播
