# 機構內規查詢系統（第一版）

這是一個純靜態網站，不需要資料庫、不需要伺服器程式。

## 檔案說明

- `index.html`：網站首頁
- `styles.css`：畫面樣式
- `app.js`：搜尋、分類與顯示功能
- `data/regulations.json`：所有內規內容

## 如何新增或修改內規

只需要修改 `data/regulations.json`。

每一份內規都有：

- id：英文識別碼，不可重複
- title：內規名稱
- category：分類
- version：版本
- effectiveDate：生效日期
- updatedAt：最後更新日期
- summary：摘要
- content：本文段落

修改完成後，將網站重新發布即可。

## 本機測試

因為瀏覽器安全限制，不建議直接雙擊 index.html。
最簡單做法：

1. 安裝 Python。
2. 在本資料夾開啟命令提示字元。
3. 執行：`python -m http.server 8000`
4. 瀏覽器開啟：`http://localhost:8000`

## 正式發布

推薦第一版使用 GitHub Pages。
後續可以再升級為：
- 後台登入
- 網頁直接編輯內規
- 草稿 / 發布流程
- 歷史版本
- 權限管理
