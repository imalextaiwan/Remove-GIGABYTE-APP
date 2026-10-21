# Remove-GIGABYTE-APP

一鍵移除 Windows 上所有 GIGABYTE(技嘉)安裝的軟體。

## 使用方式

1. 下載整個資料夾。
2. 雙擊 `Remove-GIGABYTE.bat`,在 UAC 視窗按「是」。
3. 等它跑完(解除安裝程式跳出的確認視窗會自動點掉),完成後重新開機。

只想先看會移除哪些項目、不做任何變更:

```powershell
powershell -ExecutionPolicy Bypass -File .\Remove-GigabyteApps.ps1 -DryRun
```

## 會做的事

1. 建立系統還原點
2. 移除 GIGABYTE 排程工作
3. 停止並停用 GIGABYTE 服務
4. 結束執行中的 GIGABYTE 程序
5. 移除 GIGABYTE 的 Microsoft Store App
6. 靜默執行每個官方解除安裝程式(自動按掉「Will uninstall / Uninstall Success」等視窗;要求重新開機的視窗會按「否」)
7. 清除殘留的服務、開機啟動項目、資料夾、捷徑與「已安裝的應用程式」登錄項目

**不會移除任何驅動程式。**

## 參數

| 參數 | 說明 |
| --- | --- |
| `-DryRun` | 只列出會被移除的項目,不做任何變更(不需系統管理員權限) |
| `-PurgeUserData` | 一併刪除 `%APPDATA%` / `%LOCALAPPDATA%` 下的 GIGABYTE、GiMATE 設定資料夾 |
| `-NoRestorePoint` | 不建立系統還原點 |

執行記錄會存成腳本旁的 `Remove-GIGABYTE_<時間>.log`。若有項目因檔案使用中而未移除,重新開機後再執行一次即可。
