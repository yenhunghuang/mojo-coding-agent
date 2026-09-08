## 1. 原生 CLI 輸入與輸出邊界

- [ ] 1.1 在 `src/config.mojo` 加入 `--interactive`、`--stream`、`--no-stream`、prompt 是否提供的狀態與 TTY mode resolution；以參數測試覆蓋模式表、flags 衝突、空 prompt、既有帶值選項與每次提交的 max-turns 語意。
- [ ] 1.2 新增 `src/support/terminal.mojo` 的原生逐行讀取、TTY 判斷、直接 fd 輸出及最小 SIGINT 旗標，建立所需的 native I/O fixture；在固定 Mojo 1.0.0 下編譯並驗證空行、LF／CRLF、末行 EOF、1 MiB／無效 UTF-8／NUL 拒絕與下一行復原，以及等待輸入期間的 Ctrl-C。
- [ ] 1.3 新增 `src/output.mojo` 的小型同步輸出接收器與 terminal 實作，提供測試用記憶體接收器；驗證文字即時寫出、不重印、stdout/stderr 分流、補換行，以及 bash 非零／timeout 顯示失敗且不暴露 arguments／結果 body。

## 2. 可增量讀取的程序與 HTTP 傳輸

- [ ] 2.1 將 `src/support/process.mojo` 的 spawn／poll／waitpid 核心拆出原始 byte reader，讓 `run_command()` 成為既有 capture 行為的 wrapper；以現有 process 測試確認輸出合併、截斷後 drain、exit code、timeout、stdin `/dev/null` 與 child cleanup 無回歸，另驗證 raw chunk 不經 lossy decode。
- [ ] 2.2 接通 reader 的 SIGINT、EINTR、提前關閉與例外清理，提供 HTTP 所需的 stderr 丟棄模式；以 native fixture 驗證取消和 reader 提早離開都回收受管理 process group，且一般 bash 的 stderr 合併保持原狀。
- [ ] 2.3 擴充 `tests/mock_server.mojo`，保留舊 JSON 回覆並支援 SSE byte fragments、提早斷線與有 timeout 的同步閘門；驗證 fixture 能記錄 request，且只在測試端放行後送出尾段，供後續 transport／client 測試使用。
- [ ] 2.4 在 `src/support/http.mojo` 抽出共用私有 curl 設定並新增 SSE 傳輸，開啟 no-buffer、分離有界 HTTP headers 與 body、驗證 HTTP 200／event-stream；以本機 HTTP fixture 驗證 interim headers、非 SSE／401／500、不跟隨 redirect、憑證不進 argv／診斷，以及 16 MiB request、4 MiB body、120／125 秒預設與不重置 deadline。

## 3. SSE 與串流協定

- [ ] 3.1 新增 `src/support/sse.mojo`，實作有界 bytes-to-data-event parser；以純 Mojo 測試覆蓋中文 UTF-8 切塊、LF／CRLF／CR、BOM、comments、metadata、多 data 行、多事件單次 read、無效 UTF-8 與未結束事件 EOF。
- [ ] 3.2 在 `src/client.mojo` 增加 choice 0 accumulator、content 增量交付及 finish/DONE 狀態；以測試驗證 role-only、null content、空 delta、usage-only、忽略其他 choices、頂層 error、型別錯誤、finish 後增量與 DONE 後 data 拒絕。
- [ ] 3.3 加入 tool-call index 的 name／arguments 片段組裝、id/type 一致性與整批結構檢查，並共用完整 assistant 驗證；以測試確認交錯的兩個工具、0..15 連續索引、重複／缺少 ID、空 name、超過 16 calls、合法 finish/DONE/transport 三條件及 malformed arguments 仍交由工具回傳錯誤。
- [ ] 3.4 將 SSE transport、parser 與 accumulator 串接為 client 的 streaming request 路徑，並保留 buffered complete；以本機 fixture 驗證 request 設定一致、真正增量交付、格式不相容時提示 `--no-stream`，且失敗不隱含重試或降級。

## 4. Session 與互動迴圈

- [ ] 4.1 在 `src/agent.mojo` 分離 system-only 初始化與單次使用者提交入口，由外部擁有 `mut messages`，保留單次 `run` wrapper；以 mock request 驗證最終 assistant 被 append、system 僅一次、工具 messages 正確配對，及兩次提交各自重設 max-turns。
- [ ] 4.2 將 agent 的文字與工具狀態接到輸出接收器，加入每次模型 request 和每個工具 dispatch 前後的中斷檢查；以測試驗證 stream final 不重印、buffered final 只輸出一次，以及第一個工具中斷後不執行第二個工具或模型 request。
- [ ] 4.3 新增 `src/repl.mojo`，處理一般行、`/help`、`/clear`、`/exit`、未知指令、EOF 與 `ready`／`needs_clear`；以記憶體輸入及 mock request 驗證本地命令零 request、clear 保留設定與檔案、任務級錯誤必須 clear、工具級錯誤仍可交給模型修正。
- [ ] 4.4 更新 `src/main.mojo` 的模式 dispatch、optional initial prompt、help 與最外層結束碼；以 compiled CLI 驗證 TTY 自動模式、明確 pipe 模式、單次 prompt 相容、stream flags、help 無憑證、正常退出 0、單次失敗 1 與 Ctrl-C 清理後 130。

## 5. 跨層離線驗收

- [ ] 5.1 加入真正 curl + compiled CLI 的串流時序測試：測試端讀到 stdout prefix 才放行服務端的 finish/DONE，包含跨 byte boundary 的中文且只出現一次；不使用固定短 sleep 判斷成功，並覆蓋無 Content-Length 的上限、keepalive deadline 與 headers/stderr 隔離。
- [ ] 5.2 加入串流四工具 loop 與截斷測試：在合法完成前確認檔案未被修改、畸形第二個 call 令整批零執行，完成後依序執行一次並正確回傳結果；另確認後續 request 失敗不重播已完成工具，partial assistant 不進 history。
- [ ] 5.3 加入 compiled CLI 多輪 pipe 與 native PTY fixture，分開擷取 stdout/stderr；覆蓋追問、工具後追問、clear、initial prompt、空行／未知指令、超限輸入、無末尾換行 EOF、needs_clear 及 bash 不消耗後續輸入。
- [ ] 5.4 加入 SIGINT、parser 失敗、stdout pipe 關閉與 HTTP 失敗的跨層清理驗收；確認沒有後續工具／request、受管理 child 被回收、私有暫存目錄被移除，且錯誤不暴露 fake API key 或 server error body。

## 6. 教學與完整驗證

- [ ] 6.1 更新 `README.md`、`docs/learning.md`、`docs/architecture.md` 與 `openspec/config.yaml`，以「逐行 REPL → session ownership → byte reader／SSE → 串流工具」安排學習路徑；確認文件包含可執行 CLI 範例、Mojo/curl 分工、stderr 遷移、`/clear` 不復原檔案、Ctrl-C 終止及尚未支援的能力。
- [ ] 6.2 將必要的新 Mojo 測試模組接入 `tests/test_agent.mojo` 的既有測試入口；在 Linux／WSL 執行 `pixi install --locked`、`pixi run format`、`pixi run test`、`pixi run build` 及 source／compiled CLI help，確認依賴與 lockfile 不因本次功能變動，所有既有與新增測試通過。
- [ ] 6.3 透過既有 macOS ARM64 執行環境或取得發布授權後的既有 CI，執行相同測試並確認 POSIX／PTY／SIGINT 行為；記錄結果，若無可用 runner 明確標示未驗證，不以 Linux 結果宣稱 macOS 通過。
