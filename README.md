# 劉信子居家長照機構－內部管理系統 V2

更新內容：
- Google 帳號登入
- Supabase 員工白名單
- RLS 保護內規資料
- 內規改由 Supabase 讀取
- 登入後顯示姓名與角色

GitHub 更新：
1. 覆蓋 index.html
2. 覆蓋 styles.css
3. 覆蓋 app.js
4. 測試登入成功後，刪除 data/regulations.json

安全提醒：
- Supabase publishable key 可出現在前端
- 不可將 Google Client Secret、Supabase Secret Key、Service Role Key 放到 GitHub
