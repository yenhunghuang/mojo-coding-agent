# 從四個工具學 Mojo agent

先執行 `pixi run test`。測試由 Mojo 編寫，會啟動本機 HTTP 假模型，因此不需要 API key 就能驗證。實際對話先依 README 設定 Bifrost。

## 第一步：read 與 tool loop

```bash
pixi run start --tools read "讀取 src/agent.mojo，說明模型如何取得工具結果"
```

依序閱讀 `main.mojo` → `agent.mojo` → `client.mojo` → `tools.mojo` 的 `read_file`。

每輪只有三件事：

1. 把完整 `messages` 與工具 schema 傳給模型。
2. assistant 有 `tool_calls` 時，先保存該 assistant message，再依序執行工具。每個結果帶上對應的 `tool_call_id`。
3. 把 tool message 加回歷史，再問模型。沒有工具呼叫的完整文字回應才是最終答案。

`--tools read` 同時限制模型看到的規格與 dispatcher 允許的執行，因此模型即使要求 write，也只會得到工具錯誤。

注意 Mojo 的 `def ... raises`、`var`、`with open(...)` 與 `try/except`。`read_file` 拆行、加上行號並控制輸出，避免無限制塞入 context。`return value^` 表示把值的 ownership 移交給呼叫端；需要保留原值時使用 `.copy()`。

Mojo 1.0 的字串沒有模糊的 `len(string)`：bytes、Unicode code points 與使用者看到的 graphemes 不同。本專案在檔案大小用 bytes、read 輸出用 code points，透過 `codepoint_slices()` 避免切壞中文字。

練習：改變 `start_line`、`limit` 與 `max_output`，觀察空檔、結尾換行、中文、超出 EOF 的結果。對照 `tests/test_agent.mojo` 的 `test_files`。

## 第二步：write，再加入 edit

```bash
mkdir -p /tmp/mojo-agent-practice
pixi run start --workspace /tmp/mojo-agent-practice --tools read,write,edit \
  "建立 hello.txt，內容為 hello Mojo，讀取它，再將 hello 精確改成 welcome"
```

閱讀 `text_arg` → `support/files.mojo` 的 `write_text` → `edit_file`。

`text_arg` 在寫入前檢查型別與空值。`write_text` 使用 `write_all` 確保完整輸出；父目錄需已存在。`edit_file` 找到第一個匹配，再從下一個 byte 搜尋第二次：`aaa` 裡的 `aa` 互相重疊，仍然是歧義。

這裡採用「先驗證，再修改」：零匹配、多匹配、空舊文字都會在覆寫前失敗；只有唯一匹配才呼叫 `replace` 與 `write_text`。刪除文字就是 `new_text=""`。

練習：將檔案改成兩行相同文字，要求模型只修改其中一行。模型應透過更長的 `old_text`（加入上下文）消除歧義。測試會確認失敗後檔案仍維持原內容。

## 第三步：bash 串起測試

```bash
pixi run start --workspace /tmp/mojo-agent-practice \
  "建立 hello.mojo，main 印出 hello，執行 mojo hello.mojo 並驗證輸出"
```

閱讀 `execute` 的 bash 分支，再看 `support/process.mojo`。程序管理的整個流程由 Mojo 編寫：

```text
pipe → fork
       ├─ child: setpgid → chdir → dup2 → exec bash
       └─ parent: poll → read bounded output → waitpid
                           deadline → kill process group
```

`external_call` 呼叫作業系統的 POSIX C ABI；`c_int` 與 `Pointer` 對應 C 的型別與指標。這不是另一個 Python runtime。把這些細節放在 support 模組，讓初學者先看懂工具，再逐步練習底層。

| 狀態 | 如何判斷 |
|---|---|
| 正常完成 | `exit_code == 0` 且 `timed_out == false` |
| 測試失敗 | `exit_code != 0`；模型仍可讀 output 修正程式 |
| 超時 | `timed_out == true`；清理 process group |

輸出達上限後仍 drain pipe，避免子程序因 pipe 滿而卡住。即使 stdout 提早關閉，deadline 也繼續生效。沒有互動式 stdin，也不支援長期留在背景的服務。

## 再深入基礎設施

`support/json.mojo` 採 recursive descent 解析。Json 值擁有原始文字，`get()`／`items()` 在需要時讀取子值；數字保留原始文字，避免浮點精度損失。這是為小型 agent 選擇的簡單表示法，不是高效能通用 JSON 引擎。

`support/http.mojo` 把 request 寫入私人暫存目錄，呼叫 curl 處理 TLS，再把有界的回應交給 Mojo JSON parser。API key 不放在子程序 argv。讀取此模組時可練習資源生命週期、shell quoting 與錯誤分層。

下一步先加入每輪編號與 token usage，再做 REPL。每次只改一個邊界，維持四個工具的介面。詳見 [架構與擴充](architecture.md)。
