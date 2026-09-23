# Split-MergeFile.ps1 使用說明

`Split-MergeFile.ps1` 是一個適用於 Windows PowerShell 5.1 以上版本的檔案切割與合併工具，可依指定的「每段大小」或「分段數量」切割大型檔案，並透過 JSON 資訊清單安全地合併及驗證檔案完整性。

## 主要功能

- 依每段大小切割，例如每段最多 200 MB
- 依指定數量平均切割，例如固定分成 5 份
- 自動產生 `.parts.json` 資訊清單
- 記錄分段順序、檔名、大小、原始檔名與 SHA-256
- 合併前檢查所有分段是否存在及大小是否正確
- 合併後預設使用 SHA-256 驗證內容完整性
- 支援 `-Force` 覆寫既有輸出檔案
- 支援 `-WhatIf` 預覽操作
- 使用串流方式處理大型檔案，不會將整個檔案一次載入記憶體

## 系統需求

- Windows 11
- Windows PowerShell 5.1 或 PowerShell 7 以上版本
- 足夠的磁碟空間存放分段檔案或合併後的檔案

## 基本語法

### 依大小切割

```powershell
.\Split-MergeFile.ps1 `
    -Mode Split `
    -InputPath "輸入檔案路徑" `
    -PartSizeMB 每段大小MB
```

### 依數量切割

```powershell
.\Split-MergeFile.ps1 `
    -Mode Split `
    -InputPath "輸入檔案路徑" `
    -PartCount 分段數量
```

### 合併檔案

```powershell
.\Split-MergeFile.ps1 `
    -Mode Join `
    -ManifestPath "資訊清單路徑"
```

## 使用範例

### 1. 依大小切割，每段最多 200 MB

```powershell
.\Split-MergeFile.ps1 `
    -Mode Split `
    -InputPath "D:\Data\large.iso" `
    -PartSizeMB 200
```

預設會將分段及資訊清單放在原始檔案所在目錄：

```text
large.iso.part001
large.iso.part002
large.iso.part003
large.iso.parts.json
```

> PowerShell 的 `1MB` 等於 1,048,576 bytes，也就是 1 MiB。若原始檔案為 1 GiB，使用 `-PartSizeMB 200` 會產生 6 份，前 5 份各 200 MiB，最後一份約 24 MiB。

### 2. 固定切成 5 份

如果需求是一定切成 5 份，而不是限制每份最多 200 MB，請使用：

```powershell
.\Split-MergeFile.ps1 `
    -Mode Split `
    -InputPath "D:\Data\large.iso" `
    -PartCount 5
```

程式會將檔案平均分配到 5 個分段，各分段大小最多相差 1 byte。

### 3. 指定切割輸出目錄

```powershell
.\Split-MergeFile.ps1 `
    -Mode Split `
    -InputPath "D:\Data\large.iso" `
    -PartCount 5 `
    -OutputDirectory "D:\FileParts"
```

### 4. 合併檔案

合併時指定切割時產生的 `.parts.json` 資訊清單：

```powershell
.\Split-MergeFile.ps1 `
    -Mode Join `
    -ManifestPath "D:\FileParts\large.iso.parts.json"
```

若未指定 `-OutputPath`，程式會將檔案合併至資訊清單所在目錄，並使用原始檔名。

### 5. 指定合併後的輸出路徑

```powershell
.\Split-MergeFile.ps1 `
    -Mode Join `
    -ManifestPath "D:\FileParts\large.iso.parts.json" `
    -OutputPath "D:\Restored\large-restored.iso"
```

### 6. 覆寫既有檔案

若切割分段、資訊清單或合併後的輸出檔案已存在，預設會停止操作。確認要覆寫時，請加入 `-Force`：

```powershell
.\Split-MergeFile.ps1 `
    -Mode Join `
    -ManifestPath "D:\FileParts\large.iso.parts.json" `
    -OutputPath "D:\Restored\large.iso" `
    -Force
```

### 7. 預覽操作，不實際寫入

```powershell
.\Split-MergeFile.ps1 `
    -Mode Split `
    -InputPath "D:\Data\large.iso" `
    -PartCount 5 `
    -WhatIf
```

### 8. 略過合併後的 SHA-256 驗證

一般情況不建議略過檔案驗證。若因效能或特殊需求必須略過，可使用：

```powershell
.\Split-MergeFile.ps1 `
    -Mode Join `
    -ManifestPath "D:\FileParts\large.iso.parts.json" `
    -SkipHashVerification
```

## 完整操作範例

```powershell
# 將檔案固定切成 5 份
.\Split-MergeFile.ps1 `
    -Mode Split `
    -InputPath "C:\Temp\backup.zip" `
    -PartCount 5 `
    -OutputDirectory "C:\Temp\backup-parts"

# 根據資訊清單合併，並自動驗證 SHA-256
.\Split-MergeFile.ps1 `
    -Mode Join `
    -ManifestPath "C:\Temp\backup-parts\backup.zip.parts.json" `
    -OutputPath "C:\Temp\restored\backup.zip"
```

## 參數說明

| 參數 | 適用模式 | 必要性 | 說明 |
|---|---|---:|---|
| `-Mode` | Split、Join | 必要 | 指定操作模式，可使用 `Split` 或 `Join`。 |
| `-InputPath` | Split | 必要 | 要切割的來源檔案完整路徑。 |
| `-PartSizeMB` | Split | 擇一必要 | 指定每個分段的大小上限，單位為 MiB。不可與 `-PartCount` 同時使用。 |
| `-PartCount` | Split | 擇一必要 | 指定要平均切割成多少份。不可與 `-PartSizeMB` 同時使用。 |
| `-OutputDirectory` | Split | 選用 | 指定分段檔案及資訊清單的輸出目錄。預設為來源檔案所在目錄。 |
| `-ManifestPath` | Join | 必要 | 切割時產生的 `.parts.json` 資訊清單路徑。 |
| `-OutputPath` | Join | 選用 | 指定合併完成後的檔案路徑。預設為資訊清單所在目錄及原始檔名。 |
| `-SkipHashVerification` | Join | 選用 | 略過合併後的 SHA-256 驗證。一般情況不建議使用。 |
| `-Force` | Split、Join | 選用 | 允許覆寫既有的分段、資訊清單或輸出檔案。 |
| `-BufferSizeMB` | Split、Join | 選用 | 指定串流讀寫緩衝區大小，預設為 4 MB。 |
| `-WhatIf` | Split、Join | 選用 | 顯示預計執行的操作，但不實際建立或覆寫檔案。 |
| `-Verbose` | Split、Join | 選用 | 顯示額外的處理及驗證訊息。 |

## JSON 資訊清單

切割完成後，程式會建立類似以下名稱的資訊清單：

```text
large.iso.parts.json
```

資訊清單包含：

- 原始檔名
- 原始檔案大小
- 原始檔案 SHA-256
- 建立時間
- 分段總數
- 每個分段的索引、檔名及大小

合併時應將資訊清單與所有分段檔案放在同一個目錄。程式會根據資訊清單中的順序合併，而不是單純依檔名字串排序。

## SHA-256 完整性驗證

切割完成後，程式會計算並記錄原始檔案的 SHA-256。合併完成後，程式會再次計算 SHA-256 並與資訊清單比對。

如果驗證失敗：

1. 程式會停止操作。
2. 刪除驗證失敗的合併輸出檔案。
3. 顯示預期值與實際值，方便進一步排查。

除非有明確需求，否則不建議使用 `-SkipHashVerification`。

## PowerShell 執行原則

若 PowerShell 因執行原則阻擋本機腳本，可只針對目前 PowerShell 處理程序暫時放行：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

接著在同一個 PowerShell 視窗執行腳本。當視窗關閉後，此設定即失效。

也可以使用以下方式單次啟動腳本：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Split-MergeFile.ps1" `
    -Mode Split `
    -InputPath "D:\Data\large.iso" `
    -PartCount 5
```

## 注意事項

1. 切割檔案前，請確認輸出磁碟具有足夠空間。
2. 合併時，所有分段及 `.parts.json` 資訊清單必須位於同一目錄。
3. 不要重新命名分段檔案，除非也同步正確修改 JSON 資訊清單。
4. 傳輸分段時，應一併傳送 JSON 資訊清單。
5. `-PartSizeMB` 代表每段大小上限，不保證分成特定數量。
6. 要求固定分段數量時，請使用 `-PartCount`。
7. 使用 `-Force` 前請先確認既有檔案可以安全覆寫。
8. 若合併驗證失敗，請檢查分段是否在傳輸過程中受損或被替換。

## 疑難排解

### 找不到資訊清單

確認 `-ManifestPath` 指向切割時產生的 `.parts.json` 檔案。

### 缺少分段檔案

確認所有 `.part001`、`.part002` 等分段均已放在資訊清單所在目錄。

### 分段大小不符

代表分段可能不完整、已損壞或被修改。請重新複製或重新切割來源檔案。

### SHA-256 驗證失敗

至少有一個分段內容與原始切割結果不一致。請重新取得分段，或從原始檔案重新切割。

### 輸出檔案已存在

改用其他輸出路徑，或確認可覆寫後加上 `-Force`。

## 參考資料

- Microsoft Learn: Get-FileHash  
  https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/get-filehash
