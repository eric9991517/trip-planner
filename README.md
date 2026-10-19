# 一起去旅行

邀請制旅遊行程管理網站。前端是靜態頁面，使用 Supabase Auth 與 PostgreSQL；Cloudflare Pages 直接連結 GitHub repo 自動建置。

## 功能

- 會員以電子郵件註冊及登入，個人資料可跨活動沿用。
- 已登入會員可瀏覽已發布活動；只有使用有效邀請連結的會員能進入報名。
- 活動管理者建立國內／國外活動，設定房間床位、車輛乘客座位和旅平險保額與保費。
- 報名分兩階段：受邀者先填基本資料與參加意願；管理者確認名單並設定車輛／房間後，再開放選位。
- 擁有人與管理者可直接檢視活動內容，不需邀請成員資格；一般會員仍需有效邀請才能進入。
- 邀請連結採隨機 token，資料庫只保存 SHA-256 雜湊；可設定使用人數與 30 天效期。
- 房間與車位在 PostgreSQL 交易中鎖定名額，避免多人同時搶最後一個位子造成超額。
- 活動成員可選擇旅平險或自行投保；房間、車輛已選名單供該活動成員協調。
- 只有擁有人可授權其他管理者；管理者可管理活動但不能授予管理權。

## 建立 Supabase 專案

1. 建立 Supabase 專案，選擇離團員較近的資料區域；若主要團員在台灣，可先選 Singapore。
2. 按檔名順序在 SQL Editor 執行 `supabase/migrations/` 內所有 migrations，或使用 Supabase CLI 部署 migrations。
3. 使用網站註冊擁有人帳號、完成 email 驗證，再於 SQL Editor 將該帳號設為擁有人：

   ```sql
   update public.profiles
   set role = 'owner'
   where id = (select id from auth.users where email = 'YOUR_EMAIL');
   ```

4. Authentication 的 Site URL 與 Redirect URLs 加入兩個部署網址。email verification 的 redirect 使用目前邀請連結網址。
5. 從 Supabase Project Settings 複製 Project URL 與公開 anon/publishable key。**不可使用 service role key。**

## 部署

將本資料夾內容放進 GitHub repository 根目錄，設定 `main` 為預設分支。Cloudflare Pages 連結此 repo，Production branch 設為 `main`，Build command 設為 `npm run build`，Build output directory 設為 `dist`。在 Pages 的環境變數新增 `SUPABASE_URL` 與 `SUPABASE_ANON_KEY`（只能使用公開 anon/publishable key；不可填入 `service_role` 或 `sb_secret_` key）。每次推送至 `main` 便會自動部署。build script 會在 `dist/` 產生公開 `config.js`；Supabase RLS 和資料庫函式負責實際權限檢查。

## 個資與備份

姓名、護照英文名、電話及年齡屬個人資料。正式邀請團員前，請在 Supabase 設定 MFA、管理者帳號使用獨立強密碼，並定期匯出資料庫備份。免費方案不提供自動備份，且閒置專案可能暫停。邀請連結是持有人憑證，請只傳給預期受邀者；需要撤銷時可在 Supabase 刪除對應 `invitations` row。

## 本機預覽

1. 設定環境變數 `SUPABASE_URL` 和 `SUPABASE_ANON_KEY`。
2. 在此資料夾執行 `npm run build`。
3. 使用任一靜態檔案伺服器提供此資料夾（例如 `npx serve .`），再開啟其網址。
