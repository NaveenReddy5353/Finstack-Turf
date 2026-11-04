# Finstack Turf — Kiddy Bank (v2)

A private club app for the weekly cricket crew: members, a shared "Kiddy Bank" wallet per player,
deposit requests, match attendance, automatic cost splitting, one-click settlement and reports.

| Who | Can do |
|-----|--------|
| **Admin** | Add members directly (no signup needed), approve self-signups, edit/deactivate members, record deposits, approve/reject members' deposit requests, create / edit / delete / settle matches, view club ledger and reports, export CSV. |
| **Member** | Sign in, see own wallet and ledger, submit "I have paid ₹X via UPI/cash" deposit requests, see all matches, their own share and attendance. |

**Stack:** plain HTML/CSS/JS (no build step) on **GitHub Pages**, with **Supabase** for login and the Postgres database. Free tier is enough for a club of 24.

```text
finstack-turf/
├── index.html          # the whole UI (auth + app + dialogs)
├── css/style.css
├── js/config.js        # ← paste your Supabase URL + anon key here
├── js/app.js
├── database/schema.sql # ← run once in Supabase SQL Editor
├── email-templates/magic-link.html  # ← paste into Supabase email templates
└── README.md
```

---

## 1. Create the Supabase project (10 minutes)

1. Go to https://supabase.com, sign in and click **New project** (free plan). Pick a strong database password and the region closest to you (e.g. Mumbai).
2. When the project is ready open **Project Settings → API**. Copy the **Project URL** and the **anon / publishable** key.
3. Open **SQL Editor → New query**, paste the entire contents of `database/schema.sql`, and click **Run**. It should finish with "Success. No rows returned".
4. Open **Authentication → Providers → Email**. Leave Email enabled.
   - For the easiest start, turn **Confirm email** *off* so members can sign in right after creating an account. (Turn it on later if you want; then also set up SMTP under **Authentication → SMTP settings**, because Supabase's built-in mailer is rate-limited.)
5. Open **Authentication → URL Configuration** and set, once you know your GitHub Pages address (step 3):
   - Site URL: `https://YOUR-GITHUB-USERNAME.github.io/finstack-turf/`
   - Redirect URLs: `https://YOUR-GITHUB-USERNAME.github.io/finstack-turf/**`

## 2. Configure the app

Edit `js/config.js`:

```js
window.FINSTACK_CONFIG = {
  SUPABASE_URL: "https://xxxxxxxxxxxx.supabase.co",
  SUPABASE_ANON_KEY: "eyJhbGciOi..."   // the public anon / publishable key
};
```

Only the public **anon** key goes here. Never put the `service_role` key, the database password or any secret in these files — they are published on GitHub.

## 3. Publish on GitHub Pages

1. Create a **public** GitHub repository named `finstack-turf` (on a free GitHub account, Pages only works for public repositories — the code contains no secrets, only the public anon key).
2. Upload the **contents** of this folder (`index.html`, `css/`, `js/`, `database/`, `README.md`) to the repository root.
3. Repository **Settings → Pages → Build and deployment**: Source = *Deploy from a branch*, Branch = `main`, Folder = `/ (root)`. Save.
4. After a minute the site is live at `https://YOUR-GITHUB-USERNAME.github.io/finstack-turf/`. Put that address into Supabase (step 1.5).

To test locally before publishing, just open `index.html` in a browser (or run `python -m http.server` in the folder) — the app talks to Supabase directly.

## 4. First login — you become the admin automatically

1. Open the site, choose **Create account**, register with your own email and a password.
2. Sign in. **The very first account created becomes the admin automatically** — no SQL needed.
3. To make someone else an admin later: **Members → Edit → Role = Admin**.

## 5. Add your 24 members — with invite emails

Go to **Members → ＋ Add member** and enter each player's name and email. With **"Email them an invite link now"** ticked (default), the player receives an email with a one-tap **Open Finstack Turf** button. Clicking it signs them in; the app then asks them to set a password (they can skip and keep using email links). They are linked and approved automatically because you added their email.

On the Members page each row shows **INVITED** (email sent, not opened yet) or **LINKED** (they've signed in). Use **Resend invite** / **Send login link** on a row any time. On the login page, anyone can also enter their email and click **"Email me a login link"** — handy for players who forget passwords.

For invite emails to work you need two one-time setups: **custom SMTP** (section 5a) and the app **hosted on a public URL** (section 3) with that URL set as `APP_URL` in `js/config.js` and in Supabase's Redirect URLs.

If someone signs up with an email you did not add, they appear as *PENDING* on the Members page and you click **Approve**.

### 5a. Send emails through Gmail (custom SMTP)

Supabase's built-in mailer only allows ~2 emails per hour, so connect your Gmail:

1. In your Google account open **Security → 2-Step Verification** and turn it on (required).
2. Go to https://myaccount.google.com/apppasswords, create an app password named *Finstack Turf*, and copy the 16-character code.
3. In Supabase open **Project Settings → Authentication** (or **Authentication → Emails → SMTP Settings**) and enable **Custom SMTP**:
   - Sender email: your Gmail address · Sender name: `Finstack Turf`
   - Host: `smtp.gmail.com` · Port: `465` · Username: your Gmail address · Password: the 16-character app password
   - Save, then use **Send test email** if offered.
4. **Authentication → Rate Limits**: raise *emails sent per hour* to 30 or more (default is low), save.
5. **Authentication → Emails → Magic Link**: set the subject to `Your Finstack Turf login link` and paste the body from `email-templates/magic-link.html`. Save.
6. **Authentication → URL Configuration**: Site URL = your app address; Redirect URLs = your app address plus `**` (e.g. `https://you.github.io/finstack-turf/**`).

Gmail allows roughly 500 emails a day, which is plenty for a club.

Members who stop playing: **Edit → Status = Inactive**. They keep their history but disappear from match attendance and from the default list. A member with no history at all can be deleted.

## 6. Money — how the Kiddy Bank works

- Wallet balances are never edited directly; every rupee is a line in the ledger (`wallet_transactions`).
- **Admin records a deposit:** Members → *Record deposit* (or the *Wallet* link on a member row for deposits, refunds or manual deductions).
- **Member requests a deposit:** after paying you via UPI/cash they open **Deposits**, enter the amount, how they paid and the UPI reference. You see it under **Deposits → Pending requests** (and a badge in the menu), click **Review** and **Approve** (wallet credited) or **Reject** with a note. The member sees the result in their history.
- **Match:** Matches → *New match* → date, venue, booking cost, extra expenses (balls, water…), tick who played. The total is split equally between the ticked players; the last player absorbs any paise rounding so the shares add up exactly. Absent players pay ₹0.
- **Edit / delete** an unsettled match any time (wrong attendance, cost, date).
- **Settle:** the confirmation shows every player's share against their balance and warns who is short. Settlement is atomic — if any attendee can't cover their share nothing is deducted; top them up and retry. A settled match is locked.

Example: five players have ₹500 each. Four attend a ₹1,200 match → each attendee is charged ₹300; balances become ₹200 ×4 and ₹500 for the absent player.

## 7. Reports

Admins get a per-player summary (deposits, match charges, other debits, balance, matches attended) and two CSV exports: the summary and the full ledger. Members see their own ledger under **Kiddy Bank**.

## 8. Security notes

- Row-level security is on. Members can read only their own wallet, ledger and deposit requests; everyone approved can see the member list, matches and attendance (needed to show who played). Admins see everything.
- Browsers can **never write** to the tables directly — every change goes through a database function that checks the caller's role. Even someone who copies the anon key from the site cannot give themselves money or admin rights.
- Deposit requests are *claims*; the app does not verify UPI transfers. The admin confirms against their own bank/UPI app before approving.
- Keep the Supabase account itself safe (strong password, 2FA). Export the CSVs now and then as a backup.

## 9. Troubleshooting

- **"Setup required" on the login page** → `js/config.js` still has the placeholder values.
- **"Invalid API key"** → wrong URL or key in `js/config.js`.
- **Sign up works but sign in says "awaiting admin approval"** → the email used does not match a member the admin added; admin approves them on the Members page.
- **"Your profile is still being created"** → the SQL in `database/schema.sql` was not run completely; run it again (it is safe to re-run).
- **"Email signups are disabled"** → Authentication → Sign In / Providers → Email → *Enable email provider* on; Authentication → Settings → *Allow new users to sign up* on.
- **"Email not confirmed"** → Authentication → Sign In / Providers → Email → turn *Confirm email* off; confirm the stuck account with `update auth.users set email_confirmed_at = now() where email = '…';` in the SQL Editor.
- **Invite link opens a broken page / "otp expired"** → the link is single-use and expires in 1 hour; send a fresh one with *Resend invite*. Also check `APP_URL` in `js/config.js` and Supabase Redirect URLs match the deployed address.
- **"email rate limit exceeded"** → custom SMTP is not set up yet (section 5a) or the hourly limit under Rate Limits is too low.
- **Confirmation / reset emails never arrive** → either turn off *Confirm email* in Supabase, or configure SMTP; also check Redirect URLs match the deployed address exactly.
- **Settle fails with "Insufficient wallet balance: …"** → top up those players or remove them from attendance, then settle again.

## 10. Ideas for later

- Charge absentees or set custom shares per match.
- Push/WhatsApp reminders when balance drops below ₹300.
- PWA install / offline shell.
