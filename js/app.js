(() => {
  "use strict";
  const APP_VERSION = "3.0";
  const cfg = window.FINSTACK_CONFIG || {};
  const configured = cfg.SUPABASE_URL && !cfg.SUPABASE_URL.includes("YOUR-PROJECT") &&
    cfg.SUPABASE_ANON_KEY && !cfg.SUPABASE_ANON_KEY.includes("YOUR_SUPABASE");
  const $ = (id) => document.getElementById(id);
  const APP_URL = (cfg.APP_URL && !cfg.APP_URL.includes("YOUR-")) ? cfg.APP_URL : location.href.split("#")[0].split("?")[0];
  // Supabase puts "type=magiclink|invite|recovery" in the URL when someone arrives from an email link.
  const linkParams = new URLSearchParams((location.hash.startsWith("#") ? location.hash.slice(1) : "") + "&" + location.search.slice(1));
  const arrivedVia = linkParams.get("type");
  const linkError = linkParams.get("error_description");

  // ---------------------------------------------------------------- state
  let db, user, profile;
  let members = [], transactions = [], matches = [], requests = [], votes = [], notifications = [];
  let realtimeChannel = null, refreshTimer = null, installPrompt = null;
  let currentPage = "overview";

  // -------------------------------------------------------------- helpers
  const money = n => new Intl.NumberFormat("en-IN", { style: "currency", currency: "INR" }).format(Number(n || 0));
  const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const dateFmt = s => s ? new Date(s + "T00:00:00").toLocaleDateString("en-IN", { day: "2-digit", month: "short", year: "numeric" }) : "—";
  const dtFmt = s => s ? new Date(s).toLocaleString("en-IN", { day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit" }) : "—";
  const todayIso = () => { const d = new Date(); return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10); };
  const nameOf = id => members.find(m => m.id === id)?.full_name || "Member";
  const methodLabel = m => ({ upi: "UPI", cash: "Cash", bank: "Bank", other: "Other" }[m] || m);
  function toast(msg, error = false) { const t = $("toast"); t.textContent = msg; t.className = "toast show" + (error ? " error" : ""); clearTimeout(toast.timer); toast.timer = setTimeout(() => t.className = "toast", 4200); }
  function fail(e) { console.error(e); toast(e?.message || "Something went wrong. Please try again.", true); }
  function isAdmin() { return profile?.role === "admin" && profile?.approved === true && profile?.active !== false; }
  function balanceFor(id) { return transactions.filter(x => x.profile_id === id).reduce((a, x) => a + Number(x.amount), 0); }
  function closeDialog(id) { const d = $(id); if (d.open) d.close(); }
  function busy(form, on) { form.querySelectorAll("button[type=submit]").forEach(b => b.disabled = on); }
  function confirmDialog(title, text, okLabel = "Yes, continue") {
    return new Promise(resolve => {
      $("confirmTitle").textContent = title; $("confirmText").textContent = text; $("confirmOk").textContent = okLabel;
      const dlg = $("confirmDialog"); const form = $("confirmForm");
      const onSubmit = e => { e.preventDefault(); cleanup(); dlg.close(); resolve(true); };
      const onClose = () => { cleanup(); resolve(false); };
      const cleanup = () => { form.removeEventListener("submit", onSubmit); dlg.removeEventListener("close", onClose); };
      form.addEventListener("submit", onSubmit); dlg.addEventListener("close", onClose); dlg.showModal();
    });
  }

  // ------------------------------------------------------------- auth/app
  function showAuth() { $("authView").classList.remove("hidden"); $("appView").classList.add("hidden"); }
  function showApp() {
    $("authView").classList.add("hidden"); $("appView").classList.remove("hidden");
    document.querySelectorAll(".admin-only").forEach(el => el.classList.toggle("hidden", !isAdmin()));
    document.querySelectorAll(".member-only").forEach(el => el.classList.toggle("hidden", isAdmin()));
  }
  async function getProfile() {
    let { data, error } = await db.from("profiles").select("*").eq("user_id", user.id).maybeSingle();
    if (error) throw error;
    if (!data) {
      // No member record linked to this login yet (e.g. member re-added after the login existed): link by email.
      const link = await db.rpc("link_my_profile"); if (link.error) throw link.error;
      ({ data, error } = await db.from("profiles").select("*").eq("user_id", user.id).maybeSingle()); if (error) throw error;
    }
    profile = data;
    if (!profile) { await db.auth.signOut(); showAuth(); toast("No member record found for this login. Ask the admin to add your email, then sign in again."); return false; }
    if (!profile.approved) { await db.auth.signOut(); showAuth(); toast("Your account is awaiting admin approval."); return false; }
    if (profile.active === false) { await db.auth.signOut(); showAuth(); toast("Your account has been marked inactive. Contact the admin."); return false; }
    return true;
  }
  async function refreshAll() {
    const [m, t, ma, r, v, n] = await Promise.all([
      db.from("profiles").select("id,user_id,full_name,email,phone,role,approved,active,created_at").order("full_name"),
      db.from("wallet_transactions").select("id,profile_id,amount,transaction_type,description,match_id,created_at").order("created_at", { ascending: false }).limit(1000),
      db.from("matches").select("id,match_date,venue,turf_cost,extra_cost,total_cost,notes,status,created_by,created_at,settled_at,voting_closed_at,match_attendance(profile_id,share_amount)").order("match_date", { ascending: false }).order("created_at", { ascending: false }).limit(200),
      db.from("deposit_requests").select("id,profile_id,amount,method,reference,note,status,created_at,reviewed_by,reviewed_at,review_note").order("created_at", { ascending: false }).limit(300),
      db.from("match_votes").select("match_id,profile_id,vote,updated_at"),
      db.from("notifications").select("id,kind,title,body,match_id,read,created_at").order("created_at", { ascending: false }).limit(100)
    ]);
    for (const x of [m, t, ma, r]) if (x.error) throw x.error;
    members = m.data || []; transactions = t.data || []; matches = ma.data || []; requests = r.data || [];
    votes = v.error ? [] : (v.data || []); notifications = n.error ? [] : (n.data || []);
    if (v.error || n.error) console.warn("v3 tables missing? Run database/upgrade-v3.sql", v.error || n.error);
    renderAll();
  }

  // --------------------------------------------------------------- render
  function renderAll() { renderHeader(); renderBell(); renderOverview(); renderMembers(); renderWallet(); renderDeposits(); renderMatches(); renderReports(); }
  const activeMembers = () => members.filter(m => m.approved && m.active !== false);
  function voteInfo(m) {
    const vs = votes.filter(v => v.match_id === m.id);
    const yes = vs.filter(v => v.vote === "yes").map(v => v.profile_id), no = vs.filter(v => v.vote === "no").map(v => v.profile_id);
    const pending = activeMembers().map(x => x.id).filter(id => !yes.includes(id) && !no.includes(id));
    const mine = vs.find(v => v.profile_id === profile.id)?.vote || null;
    return { yes, no, pending, mine, est: yes.length ? Number(m.total_cost) / yes.length : null };
  }
  const myOpenVotes = () => matches.filter(m => m.status === "voting" && !voteInfo(m).mine);
  function renderBell() {
    const unread = notifications.filter(n => !n.read).length;
    $("bellBadge").textContent = unread > 99 ? "99+" : unread; $("bellBadge").classList.toggle("hidden", !unread);
    const icons = { vote: "🗳", match: "🏏", wallet: "₹", deposit: "↧", admin: "★", info: "•" };
    $("notifList").innerHTML = notifications.length ? notifications.slice(0, 40).map(n => `<button class="notif ${n.read ? "" : "unread"}" data-notif="${n.id}" data-notif-match="${n.match_id || ""}" data-notif-kind="${esc(n.kind)}"><span class="notif-icon">${icons[n.kind] || "•"}</span><span><b>${esc(n.title)}</b><small>${esc(n.body || "")}</small><em>${dtFmt(n.created_at)}</em></span></button>`).join("") : '<div class="empty">No notifications yet.</div>';
    $("enableAlertsBtn").classList.toggle("hidden", !("Notification" in window) || Notification.permission === "granted");
  }
  function renderHeader() {
    $("topUserName").textContent = profile.full_name || user.email; $("topUserRole").textContent = isAdmin() ? "ADMIN" : "MEMBER";
    $("topAvatar").textContent = (profile.full_name || user.email || "P").trim()[0].toUpperCase();
    $("todayLabel").textContent = new Date().toLocaleDateString("en-IN", { weekday: "short", day: "numeric", month: "short", year: "numeric" });
    const pending = requests.filter(r => r.status === "pending" && (isAdmin() || r.profile_id === profile.id)).length;
    $("navDepositBadge").textContent = pending; $("navDepositBadge").classList.toggle("hidden", !pending);
  }
  function txRows(rows, showMember) {
    if (!rows.length) return '<div class="empty">No wallet activity yet.</div>';
    const typeLabel = { deposit: "Deposit", match_deduction: "Match", credit: "Credit", debit: "Debit" };
    return `<table><thead><tr><th>DATE</th><th>DETAIL</th><th>TYPE</th><th>AMOUNT</th></tr></thead><tbody>${rows.map(t =>
      `<tr><td>${dtFmt(t.created_at)}</td><td>${esc(t.description || "Wallet transaction")}${showMember ? `<small class="muted"> · ${esc(nameOf(t.profile_id))}</small>` : ""}</td><td><span class="status tx-${esc(t.transaction_type)}">${typeLabel[t.transaction_type] || esc(t.transaction_type)}</span></td><td class="${Number(t.amount) >= 0 ? "amount-positive" : "amount-negative"}">${Number(t.amount) >= 0 ? "+" : ""}${money(t.amount)}</td></tr>`
    ).join("")}</tbody></table>`;
  }
  function renderOverview() {
    $("myBalance").textContent = money(balanceFor(profile.id)); $("walletBalance").textContent = money(balanceFor(profile.id));
    $("myMatches").textContent = matches.filter(m => (m.match_attendance || []).some(a => a.profile_id === profile.id)).length;
    $("mySpend").textContent = money(-transactions.filter(t => t.profile_id === profile.id && t.transaction_type === "match_deduction").reduce((a, t) => a + Number(t.amount), 0));
    $("myPendingDeposits").textContent = requests.filter(r => r.profile_id === profile.id && r.status === "pending").length;
    const open = myOpenVotes(); $("myVotesNeeded").textContent = open.length;
    $("votePanel").classList.toggle("hidden", !open.length);
    $("voteList").innerHTML = open.map(m => { const vi = voteInfo(m); return `<div class="vote-item"><div><b>${esc(m.venue)}</b><small>${dateFmt(m.match_date)} · ${money(m.total_cost)} total · ${vi.yes.length} in so far${vi.est ? " · ~" + money(vi.est) + " each" : ""}</small></div><div class="btn-row"><button class="btn primary sm" data-vote="${m.id}" data-vote-value="yes">I'm in</button><button class="btn ghost sm" data-vote="${m.id}" data-vote-value="no">Can't make it</button></div></div>`; }).join("");
    if (isAdmin()) {
      $("clubBalance").textContent = money(members.filter(m => m.approved).reduce((a, m) => a + balanceFor(m.id), 0));
      const p = requests.filter(r => r.status === "pending");
      $("pendingDeposits").textContent = p.length;
      $("pendingDepositsHint").textContent = p.length ? `${money(p.reduce((a, r) => a + Number(r.amount), 0))} waiting for your review` : "No requests waiting";
    }
    $("overviewTransactions").innerHTML = txRows(transactions.filter(t => isAdmin() || t.profile_id === profile.id).slice(0, 6), isAdmin());
    const list = matches.slice(0, 5);
    $("overviewMatches").innerHTML = list.length ? list.map(m => {
      const mine = (m.match_attendance || []).find(a => a.profile_id === profile.id);
      return `<div class="mini-item"><div><b>${esc(m.venue)}</b><small>${dateFmt(m.match_date)} · ${m.status === "voting" ? voteInfo(m).yes.length + " in · voting open" : (m.match_attendance || []).length + " players · " + (m.status === "settled" ? "settled" : "team locked")}</small></div><strong>${mine ? money(mine.share_amount) + "<small> my share</small>" : money(m.total_cost)}</strong></div>`;
    }).join("") : '<div class="empty">No matches recorded yet.</div>';
  }
  function renderMembers() {
    if (!isAdmin()) return;
    const approved = members.filter(m => m.approved && m.active !== false);
    $("approvedCount").textContent = approved.length; $("pendingCount").textContent = members.filter(m => !m.approved).length;
    $("membersBalance").textContent = money(members.filter(m => m.approved).reduce((a, m) => a + balanceFor(m.id), 0));
    const showInactive = $("showInactive").checked;
    const rows = members.filter(m => showInactive || m.active !== false);
    $("membersTable").innerHTML = rows.length ? `<table><thead><tr><th>MEMBER</th><th>CONTACT</th><th>ROLE</th><th>STATUS</th><th>LOGIN</th><th>BALANCE</th><th>ACTIONS</th></tr></thead><tbody>${rows.map(m => {
      const status = m.active === false ? '<span class="status inactive">INACTIVE</span>' : m.approved ? '<span class="status">ACTIVE</span>' : '<span class="status pending">PENDING</span>';
      const login = m.user_id ? '<span class="status">LINKED</span>' : m.email ? '<span class="status pending">INVITED</span>' : '<span class="muted">No email</span>';
      const actions = [
        !m.approved ? `<button class="text-btn" data-approve="${m.id}">Approve</button>` : "",
        `<button class="text-btn" data-edit-member="${m.id}">Edit</button>`,
        m.approved ? `<button class="text-btn" data-adjust="${m.id}">Wallet</button>` : "",
        m.email && m.active !== false ? `<button class="text-btn" data-invite="${m.id}">${m.user_id ? "Send login link" : "Resend invite"}</button>` : "",
        m.id !== profile.id ? `<button class="text-btn danger" data-delete-member="${m.id}">Delete</button>` : ""
      ].filter(Boolean).join(" · ");
      return `<tr><td><b>${esc(m.full_name)}</b></td><td>${esc(m.email || "—")}${m.phone ? `<small class="muted"> · ${esc(m.phone)}</small>` : ""}</td><td>${esc(m.role)}</td><td>${status}</td><td>${login}</td><td>${money(balanceFor(m.id))}</td><td class="actions">${actions}</td></tr>`;
    }).join("")}</tbody></table>` : '<div class="empty">No members yet. Click “Add member” to add your squad.</div>';
    $("depositMember").innerHTML = approved.map(m => `<option value="${m.id}">${esc(m.full_name)}</option>`).join("");
    const f = $("walletFilter"); const cur = f.value;
    f.innerHTML = '<option value="">All members</option>' + members.filter(m => m.approved).map(m => `<option value="${m.id}">${esc(m.full_name)}</option>`).join("");
    f.value = cur;
  }
  function renderWallet() {
    if (isAdmin()) {
      const sel = $("walletFilter").value;
      $("walletTitle").textContent = sel ? `${nameOf(sel)} — ${money(balanceFor(sel))}` : "Club ledger (all members)";
      $("walletTable").innerHTML = txRows(transactions.filter(t => !sel || t.profile_id === sel), !sel);
    } else {
      $("walletTitle").textContent = "Wallet transactions";
      $("walletTable").innerHTML = txRows(transactions.filter(t => t.profile_id === profile.id), false);
    }
  }
  function reqStatus(s) { return `<span class="status ${s === "approved" ? "" : s === "pending" ? "pending" : "inactive"}">${s.toUpperCase()}</span>`; }
  function renderDeposits() {
    const mine = requests.filter(r => r.profile_id === profile.id);
    if (isAdmin()) {
      const pending = requests.filter(r => r.status === "pending");
      $("depositsTitle").textContent = "Deposit requests"; $("depositsHint").textContent = "Members record what they paid you; approve to credit their wallet, or reject with a note.";
      $("pendingPanelCount").textContent = `${pending.length} PENDING`;
      $("pendingTable").innerHTML = pending.length ? `<table><thead><tr><th>WHEN</th><th>MEMBER</th><th>AMOUNT</th><th>VIA</th><th>REFERENCE / NOTE</th><th></th></tr></thead><tbody>${pending.map(r =>
        `<tr><td>${dtFmt(r.created_at)}</td><td><b>${esc(nameOf(r.profile_id))}</b></td><td class="amount-positive">${money(r.amount)}</td><td>${methodLabel(r.method)}</td><td>${esc(r.reference || "—")}${r.note ? `<small class="muted"> · ${esc(r.note)}</small>` : ""}</td><td><button class="btn primary sm" data-review="${r.id}">Review</button></td></tr>`
      ).join("")}</tbody></table>` : '<div class="empty">No pending requests. 🎉</div>';
      const history = requests.filter(r => r.status !== "pending");
      $("historyTitle").textContent = "Reviewed requests";
      $("historyTable").innerHTML = history.length ? `<table><thead><tr><th>WHEN</th><th>MEMBER</th><th>AMOUNT</th><th>VIA</th><th>STATUS</th><th>REVIEWED</th></tr></thead><tbody>${history.map(r =>
        `<tr><td>${dtFmt(r.created_at)}</td><td>${esc(nameOf(r.profile_id))}</td><td>${money(r.amount)}</td><td>${methodLabel(r.method)}</td><td>${reqStatus(r.status)}</td><td>${dtFmt(r.reviewed_at)}${r.review_note ? `<small class="muted"> · ${esc(r.review_note)}</small>` : ""}</td></tr>`
      ).join("")}</tbody></table>` : '<div class="empty">Nothing reviewed yet.</div>';
    } else {
      $("depositsTitle").textContent = "My deposits"; $("depositsHint").textContent = "Paid the admin via UPI or cash? Record it here and it will be credited once the admin confirms.";
      $("historyTitle").textContent = "My deposit requests";
      $("historyTable").innerHTML = mine.length ? `<table><thead><tr><th>WHEN</th><th>AMOUNT</th><th>VIA</th><th>REFERENCE</th><th>STATUS</th><th></th></tr></thead><tbody>${mine.map(r =>
        `<tr><td>${dtFmt(r.created_at)}</td><td>${money(r.amount)}</td><td>${methodLabel(r.method)}</td><td>${esc(r.reference || "—")}</td><td>${reqStatus(r.status)}${r.review_note ? `<small class="muted"> · ${esc(r.review_note)}</small>` : ""}</td><td>${r.status === "pending" ? `<button class="text-btn danger" data-cancel-request="${r.id}">Cancel</button>` : ""}</td></tr>`
      ).join("")}</tbody></table>` : '<div class="empty">You have not submitted any deposit requests yet.</div>';
    }
  }
  function renderMatches() {
    $("matchList").innerHTML = matches.length ? matches.map(m => {
      const att = m.match_attendance || []; const count = att.length;
      const mine = att.find(a => a.profile_id === profile.id);
      if (m.status === "voting") {
        const vi = voteInfo(m);
        const chip = (id, cls) => `<span class="chip ${cls}">${esc(nameOf(id))}</span>`;
        const lists = `<div class="vote-cols"><div><small class="muted">IN (${vi.yes.length})</small><div class="chips">${vi.yes.map(id => chip(id, "yes")).join("") || '<span class="muted">—</span>'}</div></div><div><small class="muted">OUT (${vi.no.length})</small><div class="chips">${vi.no.map(id => chip(id, "no")).join("") || '<span class="muted">—</span>'}</div></div><div><small class="muted">NOT VOTED (${vi.pending.length})</small><div class="chips">${vi.pending.map(id => chip(id, "pending")).join("") || '<span class="muted">—</span>'}</div></div></div>`;
        const myBtns = `<div class="btn-row"><button class="btn ${vi.mine === "yes" ? "primary" : "ghost"} sm" data-vote="${m.id}" data-vote-value="yes">${vi.mine === "yes" ? "✓ I'm in" : "I'm in"}</button><button class="btn ${vi.mine === "no" ? "danger-fill" : "ghost"} sm" data-vote="${m.id}" data-vote-value="no">${vi.mine === "no" ? "✓ Can't make it" : "Can't make it"}</button></div>`;
        const adminBtns = isAdmin() ? `<div class="btn-row"><button class="text-btn" data-edit-match="${m.id}">Edit</button><button class="text-btn" data-remind="${m.id}">Remind ${vi.pending.length}</button><button class="text-btn danger" data-delete-match="${m.id}">Delete</button><button class="btn primary sm" data-close-voting="${m.id}">Close voting →</button></div>` : "";
        return `<article class="match-card voting"><div class="match-card-top"><span class="eyebrow">${dateFmt(m.match_date)}</span><span class="status voting">VOTING OPEN</span></div><h3>${esc(m.venue)}</h3><div class="match-meta">${vi.yes.length} in · ${vi.pending.length} yet to vote${m.notes ? " · " + esc(m.notes) : ""}</div><div class="match-cost">${money(m.total_cost)}<small class="muted"> total</small></div><div class="match-meta">${vi.est ? "~" + money(vi.est) + " per player if " + vi.yes.length + " play" : "Share depends on how many are in"}</div>${lists}<div class="match-foot vote-foot"><span>${vi.mine ? (vi.mine === "yes" ? "You're in ✓" : "You're out") : "<b>Your vote is needed</b>"}</span>${myBtns}</div>${adminBtns ? `<div class="match-admin">${adminBtns}</div>` : ""}</article>`;
      }
      const names = att.map(a => nameOf(a.profile_id)).sort((a, b) => a.localeCompare(b));
      const chips = names.slice(0, 8).map(n => `<span class="chip">${esc(n)}</span>`).join("") + (names.length > 8 ? `<span class="chip more">+${names.length - 8} more</span>` : "");
      const adminBtns = isAdmin() && m.status !== "settled"
        ? `<div class="btn-row"><button class="text-btn" data-edit-match="${m.id}">Edit</button>${m.voting_closed_at ? `<button class="text-btn" data-reopen-voting="${m.id}">Reopen voting</button>` : ""}<button class="text-btn danger" data-delete-match="${m.id}">Delete</button><button class="btn primary sm" data-settle="${m.id}">Settle →</button></div>`
        : `<span>${m.status === "settled" ? "✓ Settled " + dtFmt(m.settled_at) : ""}</span>`;
      return `<article class="match-card"><div class="match-card-top"><span class="eyebrow">${dateFmt(m.match_date)}</span><span class="status ${m.status === "settled" ? "settled" : "unsettled"}">${m.status === "settled" ? "SETTLED" : "TEAM LOCKED"}</span></div><h3>${esc(m.venue)}</h3><div class="match-meta">${count} player${count === 1 ? "" : "s"}${m.voting_closed_at ? " · by vote" : ""}${m.notes ? " · " + esc(m.notes) : ""}</div><div class="match-cost">${money(m.total_cost)}<small class="muted"> total</small></div><div class="match-meta">${count ? money(Number(m.total_cost) / count) + " per player" : "No attendance recorded"}${Number(m.extra_cost) > 0 ? ` · includes ${money(m.extra_cost)} extras` : ""}</div><div class="chips">${chips || '<span class="muted">No players selected</span>'}</div><div class="match-foot"><span>${mine ? `You're playing · <b>${money(mine.share_amount)}</b>` : "You're not in this one"}</span>${adminBtns}</div></article>`;
    }).join("") : '<div class="empty">No matches yet. Admin can create the first match.</div>';
  }
  function renderReports() {
    if (!isAdmin()) return;
    const deposits = transactions.filter(t => ["deposit", "credit"].includes(t.transaction_type) && Number(t.amount) > 0).reduce((a, t) => a + Number(t.amount), 0);
    const settled = matches.filter(m => m.status === "settled");
    $("reportDeposits").textContent = money(deposits); $("reportExpenses").textContent = money(settled.reduce((a, m) => a + Number(m.total_cost), 0)); $("reportMatches").textContent = settled.length;
    $("reportTable").innerHTML = `<table><thead><tr><th>PLAYER</th><th>DEPOSITS / CREDITS</th><th>MATCH CHARGES</th><th>OTHER DEBITS</th><th>BALANCE</th><th>ATTENDED</th><th>LAST ACTIVITY</th></tr></thead><tbody>${members.filter(m => m.approved).map(m => {
      const ts = transactions.filter(t => t.profile_id === m.id);
      const plus = ts.filter(t => Number(t.amount) > 0).reduce((a, t) => a + Number(t.amount), 0);
      const matchCharges = -ts.filter(t => t.transaction_type === "match_deduction").reduce((a, t) => a + Number(t.amount), 0);
      const debits = -ts.filter(t => t.transaction_type === "debit").reduce((a, t) => a + Number(t.amount), 0);
      const att = settled.filter(x => (x.match_attendance || []).some(a => a.profile_id === m.id)).length;
      const bal = balanceFor(m.id);
      return `<tr><td>${esc(m.full_name)}${m.active === false ? ' <span class="status inactive">INACTIVE</span>' : ""}</td><td class="amount-positive">${money(plus)}</td><td class="amount-negative">${money(matchCharges)}</td><td>${money(debits)}</td><td class="${bal < 0 ? "amount-negative" : ""}"><b>${money(bal)}</b></td><td>${att}</td><td>${ts.length ? dtFmt(ts[0].created_at) : "—"}</td></tr>`;
    }).join("")}</tbody></table>`;
  }

  // -------------------------------------------------------------- actions
  async function sendInvite(email, fullName) {
    const { error } = await db.auth.signInWithOtp({ email, options: { emailRedirectTo: APP_URL, shouldCreateUser: true, data: { full_name: fullName } } });
    if (error) throw error;
  }
  async function rpc(name, args, successMsg) {
    const { data, error } = await db.rpc(name, args); if (error) throw error;
    if (successMsg) toast(successMsg); await refreshAll(); return data;
  }
  function openMemberDialog(id) {
    const m = id ? members.find(x => x.id === id) : null;
    $("memberId").value = m?.id || ""; $("memberName").value = m?.full_name || ""; $("memberEmail").value = m?.email || ""; $("memberPhone").value = m?.phone || "";
    $("memberRole").value = m?.role || "member"; $("memberActive").value = m ? String(m.active !== false) : "true";
    $("memberEmail").disabled = !!m?.user_id;
    $("memberDialogTitle").textContent = m ? "Edit member" : "Add a member"; $("memberSubmit").textContent = m ? "Save changes" : "Add member";
    $("memberHint").textContent = m ? (m.user_id ? "This member has signed in, so their email is locked to their login." : "The member can sign up later with this email and will be linked automatically.") : "The member can sign up later with this email and will be linked and approved automatically.";
    document.querySelectorAll("#memberDialog .edit-only").forEach(el => el.classList.toggle("hidden", !m));
    document.querySelectorAll("#memberDialog .add-only").forEach(el => el.classList.toggle("hidden", !!m)); $("memberInvite").checked = true;
    $("memberDialog").showModal(); $("memberName").focus();
  }
  function attendeeCandidates(match) {
    const ids = new Set((match?.match_attendance || []).map(a => a.profile_id));
    return members.filter(m => (m.approved && m.active !== false) || ids.has(m.id));
  }
  function updateShareHint() {
    const n = $("attendanceChoices").querySelectorAll("input:checked").length;
    const total = Number($("matchCost").value || 0) + Number($("extraCost").value || 0);
    $("selectedCount").textContent = `${n} selected`;
    $("shareHint").textContent = n && total ? `${money(total)} split ${n} ways = ${money(total / n)} per player. Absent players pay ₹0.` : "The total turf and additional costs are divided equally among selected players. Absent players pay ₹0.";
  }
  function toggleVotingUi(on) { $("attendanceBlock").classList.toggle("hidden", on); $("votingHint").classList.toggle("hidden", !on); }
  function openMatchDialog(id) {
    const m = id ? matches.find(x => x.id === id) : null;
    const checked = new Set(m ? (m.match_attendance || []).map(a => a.profile_id) : attendeeCandidates(null).map(x => x.id));
    $("matchId").value = m?.id || ""; $("matchDate").value = m?.match_date || todayIso(); $("matchVenue").value = m?.venue || "";
    $("matchCost").value = m ? Number(m.turf_cost) : ""; $("extraCost").value = m ? Number(m.extra_cost) : 0; $("matchNotes").value = m?.notes || "";
    $("matchDialogTitle").textContent = m ? "Edit match" : "Create a turf match"; $("matchSubmit").textContent = m ? "Save changes" : "Create match";
    const votingMatch = m?.status === "voting";
    document.querySelectorAll("#matchDialog .add-only").forEach(el => el.classList.toggle("hidden", !!m));
    $("matchVoting").checked = !m; toggleVotingUi(!m || votingMatch);
    if (votingMatch) $("matchDialogTitle").textContent = "Edit match (voting open)";
    $("attendanceChoices").innerHTML = attendeeCandidates(m).map(x => `<label class="attendee"><input type="checkbox" value="${x.id}" ${checked.has(x.id) ? "checked" : ""}> ${esc(x.full_name)}${x.role === "admin" ? ' <small class="muted">(admin)</small>' : ""}</label>`).join("");
    updateShareHint(); $("matchDialog").showModal();
  }
  function openSettle(id) {
    const m = matches.find(x => x.id === id); if (!m) return;
    const att = m.match_attendance || [];
    $("settleMatchId").value = id;
    $("settleSummary").textContent = `${m.venue} · ${dateFmt(m.match_date)} · ${money(m.total_cost)} split between ${att.length} attending player${att.length === 1 ? "" : "s"}.`;
    const short = att.filter(a => balanceFor(a.profile_id) < Number(a.share_amount));
    $("settleShares").innerHTML = `<table><thead><tr><th>PLAYER</th><th>SHARE</th><th>BALANCE</th></tr></thead><tbody>${att.map(a => { const b = balanceFor(a.profile_id); const ok = b >= Number(a.share_amount); return `<tr><td>${esc(nameOf(a.profile_id))}</td><td>${money(a.share_amount)}</td><td class="${ok ? "amount-positive" : "amount-negative"}">${money(b)}${ok ? "" : " ⚠"}</td></tr>`; }).join("")}</tbody></table>` + (short.length ? `<p class="hint warn">${short.length} player${short.length === 1 ? " has" : "s have"} insufficient balance — settlement will be blocked until they top up.</p>` : "");
    $("settleDialog").showModal();
  }
  function openReview(id) {
    const r = requests.find(x => x.id === id); if (!r) return;
    $("reviewId").value = id; $("reviewNote").value = "";
    $("reviewSummary").innerHTML = `<b>${esc(nameOf(r.profile_id))}</b> says they paid <b class="amount-positive">${money(r.amount)}</b> via ${methodLabel(r.method)}${r.reference ? ` · ref <b>${esc(r.reference)}</b>` : ""}${r.note ? `<br><small class="muted">${esc(r.note)}</small>` : ""}<br><small class="muted">Submitted ${dtFmt(r.created_at)} · current balance ${money(balanceFor(r.profile_id))}</small>`;
    $("reviewDialog").showModal();
  }
  function go(page) {
    if ((page === "members" || page === "reports") && !isAdmin()) page = "overview";
    currentPage = page;
    document.querySelectorAll(".page").forEach(p => p.classList.toggle("active", p.id === `page-${page}`));
    document.querySelectorAll(".nav-link[data-page]").forEach(b => b.classList.toggle("active", b.dataset.page === page));
    const labels = { overview: ["TEAM CONTROL CENTER", "Overview"], members: ["THE SQUAD", "Members"], wallet: ["KIDDY BANK", isAdmin() ? "Wallets" : "My wallet"], deposits: ["TOP-UPS", "Deposits"], matches: ["MATCH CENTER", "Matches"], reports: ["CLUB INSIGHTS", "Reports"] };
    $("pageEyebrow").textContent = labels[page][0]; $("pageTitle").textContent = labels[page][1]; $("sidebar").classList.remove("open");
    window.scrollTo({ top: 0 });
  }
  function downloadCsv(rows, filename) {
    const csv = rows.map(r => r.map(v => `"${String(v ?? "").replace(/"/g, '""')}"`).join(",")).join("\r\n");
    const a = document.createElement("a"); a.href = URL.createObjectURL(new Blob(["﻿" + csv], { type: "text/csv" })); a.download = filename; a.click(); URL.revokeObjectURL(a.href);
  }
  function exportSummaryCsv() {
    const rows = [["Member", "Email", "Status", "Deposits and credits", "Match charges", "Other debits", "Balance", "Matches attended"]];
    members.filter(m => m.approved).forEach(m => { const ts = transactions.filter(t => t.profile_id === m.id); rows.push([m.full_name, m.email || "", m.active === false ? "inactive" : "active", ts.filter(t => Number(t.amount) > 0).reduce((a, t) => a + Number(t.amount), 0).toFixed(2), (-ts.filter(t => t.transaction_type === "match_deduction").reduce((a, t) => a + Number(t.amount), 0)).toFixed(2), (-ts.filter(t => t.transaction_type === "debit").reduce((a, t) => a + Number(t.amount), 0)).toFixed(2), balanceFor(m.id).toFixed(2), matches.filter(x => x.status === "settled" && (x.match_attendance || []).some(a => a.profile_id === m.id)).length]); });
    downloadCsv(rows, `finstack-turf-summary-${todayIso()}.csv`);
  }
  function exportLedgerCsv() {
    const rows = [["Date", "Member", "Type", "Description", "Amount"]];
    [...transactions].reverse().forEach(t => rows.push([new Date(t.created_at).toLocaleString("en-IN"), nameOf(t.profile_id), t.transaction_type, t.description, Number(t.amount).toFixed(2)]));
    downloadCsv(rows, `finstack-turf-ledger-${todayIso()}.csv`);
  }

  // ----------------------------------------------------------------- init
  async function init() {
    if (!configured) {
      $("configNote").textContent = "Setup required: edit js/config.js with your Supabase URL and public anon key (see README, steps 1–2).";
      $("configNote").classList.add("warn");
      document.querySelectorAll("#authView button").forEach(b => { if (!b.dataset.authTab) b.disabled = true; });
      return;
    }
    db = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY);
    $("configNote").textContent = "Secure sign-in powered by Supabase. · v" + APP_VERSION;
    let booted = false, pendingPw = null;
    const boot = async session => {
      if (session?.user) { user = session.user; if (await getProfile()) { showApp(); await refreshAll(); go(currentPage); startRealtime(); if (pendingPw) { const f = pendingPw === "forced"; pendingPw = null; openSetPassword(f); } } }
      else { user = null; profile = null; stopRealtime(); showAuth(); }
    };
    db.auth.onAuthStateChange((event, session) => {
      if (event === "INITIAL_SESSION" || event === "TOKEN_REFRESHED") return;
      if (event === "PASSWORD_RECOVERY" || (event === "SIGNED_IN" && (arrivedVia === "magiclink" || arrivedVia === "invite" || arrivedVia === "signup") && !localStorage.getItem("ft_pw_" + session?.user?.id))) {
        history.replaceState(null, "", APP_URL); pendingPw = event === "PASSWORD_RECOVERY" ? "forced" : "offer";
      }
      booted = true; boot(session).catch(fail);
    });
    if (linkError) { toast(decodeURIComponent(linkError.replace(/\+/g, " ")) + " — ask the admin to send a fresh link.", true); history.replaceState(null, "", APP_URL); }
    const { data: { session }, error } = await db.auth.getSession(); if (error) throw error;
    if (!booted) await boot(session);
  }
  function scheduleRefresh() { clearTimeout(refreshTimer); refreshTimer = setTimeout(() => refreshAll().catch(console.error), 400); }
  function startRealtime() {
    stopRealtime(); if (!db.channel) return;
    realtimeChannel = db.channel("finstack-live")
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "notifications", filter: `profile_id=eq.${profile.id}` }, payload => {
        const n = payload.new; notifications.unshift(n); renderBell(); toast(`🔔 ${n.title}`);
        if ("Notification" in window && Notification.permission === "granted") { try { new Notification(n.title, { body: n.body || "", icon: "icons/icon-192.png", tag: n.id }); } catch (_) {} }
        scheduleRefresh();
      })
      .on("postgres_changes", { event: "*", schema: "public", table: "match_votes" }, scheduleRefresh)
      .on("postgres_changes", { event: "*", schema: "public", table: "matches" }, scheduleRefresh)
      .subscribe();
  }
  function stopRealtime() { if (realtimeChannel) { try { db.removeChannel(realtimeChannel); } catch (_) {} realtimeChannel = null; } }
  function openSetPassword(forced) {
    $("pwTitle").textContent = forced ? "Choose a new password" : "Welcome! Set a password";
    $("pwHint").textContent = forced ? "Enter the new password you want to use from now on." : "You're signed in via your email link. Set a password so you can also sign in with email + password next time (or skip and keep using email links).";
    $("pwSkip").classList.toggle("hidden", forced); $("pwNew").value = ""; $("pwNew2").value = "";
    $("pwDialog").showModal();
  }

  // --------------------------------------------------------------- events
  document.addEventListener("click", async e => {
    if ($("sidebar").classList.contains("open") && !e.target.closest("#sidebar,#menuToggle")) $("sidebar").classList.remove("open");
    if (!$("notifPanel").classList.contains("hidden") && !e.target.closest("#notifPanel,#bellBtn")) $("notifPanel").classList.add("hidden");
    const tab = e.target.closest("[data-auth-tab]"); if (tab) { const signup = tab.dataset.authTab === "signup"; document.querySelectorAll(".tab").forEach(x => x.classList.toggle("active", x === tab)); $("loginForm").classList.toggle("hidden", signup); $("signupForm").classList.toggle("hidden", !signup); }
    const nav = e.target.closest("[data-page]"); if (nav) go(nav.dataset.page);
    const goto = e.target.closest("[data-goto]"); if (goto) go(goto.dataset.goto);
    const close = e.target.closest("[data-close]"); if (close) closeDialog(close.dataset.close);
    try {
      const approve = e.target.closest("[data-approve]"); if (approve) await rpc("admin_approve_member", { p_profile_id: approve.dataset.approve }, "Member approved.");
      const editM = e.target.closest("[data-edit-member]"); if (editM) openMemberDialog(editM.dataset.editMember);
      const delM = e.target.closest("[data-delete-member]"); if (delM && await confirmDialog("Delete member?", `Remove ${nameOf(delM.dataset.deleteMember)} from the club. Only possible if they have no wallet or match history — otherwise mark them inactive instead.`, "Delete member")) await rpc("admin_delete_member", { p_profile_id: delM.dataset.deleteMember }, "Member removed.");
      const adjust = e.target.closest("[data-adjust]"); if (adjust) { $("adjustMemberId").value = adjust.dataset.adjust; $("adjustTitle").textContent = `Wallet · ${nameOf(adjust.dataset.adjust)} (${money(balanceFor(adjust.dataset.adjust))})`; $("adjustAmount").value = ""; $("adjustReason").value = ""; $("adjustDialog").showModal(); }
      const settleBtn = e.target.closest("[data-settle]"); if (settleBtn) openSettle(settleBtn.dataset.settle);
      const editMatch = e.target.closest("[data-edit-match]"); if (editMatch) openMatchDialog(editMatch.dataset.editMatch);
      const delMatch = e.target.closest("[data-delete-match]"); if (delMatch) { const m = matches.find(x => x.id === delMatch.dataset.deleteMatch); if (m && await confirmDialog("Delete this match?", `${m.venue} on ${dateFmt(m.match_date)} (${money(m.total_cost)}) will be removed. No wallets are affected because it is unsettled.`, "Delete match")) await rpc("admin_delete_match", { p_match_id: m.id }, "Match deleted."); }
      const inv = e.target.closest("[data-invite]"); if (inv) { const m = members.find(x => x.id === inv.dataset.invite); if (m && await confirmDialog("Send email?", `Email a one-tap login link to ${m.full_name} at ${m.email}?`, "Send link")) { await sendInvite(m.email, m.full_name); toast(`Login link sent to ${m.email}.`); } }
      const vote = e.target.closest("[data-vote]"); if (vote) { const r = await rpc("member_vote", { p_match_id: vote.dataset.vote, p_vote: vote.dataset.voteValue }); toast(r === "closed" ? "Vote recorded — everyone has voted, team sheet is locked." : (vote.dataset.voteValue === "yes" ? "You're in! 🏏" : "Noted — you're out for this one.")); }
      const closeV = e.target.closest("[data-close-voting]"); if (closeV) { const m = matches.find(x => x.id === closeV.dataset.closeVoting); const vi = m ? voteInfo(m) : null; if (m && await confirmDialog("Close voting?", `${vi.yes.length} player${vi.yes.length === 1 ? "" : "s"} said they're in${vi.pending.length ? `, ${vi.pending.length} haven't voted` : ""}. The cost of ${money(m.total_cost)} will be split ${vi.yes.length ? "as " + money(Number(m.total_cost) / vi.yes.length) + " each" : "among those in"}. You can still edit attendance before settling.`, "Close voting")) await rpc("admin_close_voting", { p_match_id: m.id }, "Voting closed. Team sheet locked and players notified."); }
      const reopen = e.target.closest("[data-reopen-voting]"); if (reopen && await confirmDialog("Reopen voting?", "Attendance will be unlocked and everyone is notified to confirm again. Existing votes are kept.", "Reopen voting")) await rpc("admin_reopen_voting", { p_match_id: reopen.dataset.reopenVoting }, "Voting reopened.");
      const remind = e.target.closest("[data-remind]"); if (remind) { const n = await rpc("admin_remind_voters", { p_match_id: remind.dataset.remind }); toast(n ? `Reminder sent to ${n} member${n === 1 ? "" : "s"}.` : "Everyone has already voted."); }
      const notif = e.target.closest("[data-notif]"); if (notif) { const n = notifications.find(x => x.id === notif.dataset.notif); if (n && !n.read) { n.read = true; renderBell(); db.rpc("mark_notifications_read", { p_ids: [n.id] }).then(() => {}, console.error); } $("notifPanel").classList.add("hidden"); go(n?.match_id ? "matches" : (n?.kind === "deposit" || n?.kind === "wallet") ? (n.kind === "deposit" ? "deposits" : "wallet") : "overview"); }
      const review = e.target.closest("[data-review]"); if (review) openReview(review.dataset.review);
      const cancelReq = e.target.closest("[data-cancel-request]"); if (cancelReq && await confirmDialog("Cancel request?", "Your deposit request will be withdrawn.", "Cancel request")) await rpc("member_cancel_deposit_request", { p_request_id: cancelReq.dataset.cancelRequest }, "Request cancelled.");
    } catch (err) { fail(err); }
  });

  const notReady = () => { if (!db) { toast("Not connected yet: add your Supabase URL and anon key to js/config.js first (README step 1–2).", true); return true; } return false; };
  $("signInForm").addEventListener("submit", async e => { e.preventDefault(); if (notReady()) return; busy(e.target, true); try { const { error } = await db.auth.signInWithPassword({ email: $("loginEmail").value.trim(), password: $("loginPassword").value }); if (error) throw error; } catch (err) { fail(err); } finally { busy(e.target, false); } });
  $("registerForm").addEventListener("submit", async e => {
    e.preventDefault(); if (notReady()) return; busy(e.target, true);
    try {
      const { data, error } = await db.auth.signUp({ email: $("registerEmail").value.trim(), password: $("registerPassword").value, options: { data: { full_name: $("registerName").value.trim() } } });
      if (error) throw error;
      if (data.user && Array.isArray(data.user.identities) && data.user.identities.length === 0) {
        throw new Error("An account with this email already exists (you were invited). Go to Sign in and use “Email me a login link” or “Forgot password?” to set your password.");
      }
      toast(data.session ? "Account created." : "Check your email to confirm signup, then sign in.");
      document.querySelector('[data-auth-tab="login"]').click(); $("loginEmail").value = $("registerEmail").value.trim();
    } catch (err) { fail(err); } finally { busy(e.target, false); }
  });
  $("forgotBtn").addEventListener("click", async () => {
    if (notReady()) return;
    const email = $("loginEmail").value.trim(); if (!email) return toast("Enter your email address first, then click Forgot password.", true);
    try { const { error } = await db.auth.resetPasswordForEmail(email, { redirectTo: location.href.split("#")[0] }); if (error) throw error; toast("Password reset email sent."); } catch (err) { fail(err); }
  });
  $("magicBtn").addEventListener("click", async () => {
    if (notReady()) return;
    const email = $("loginEmail").value.trim(); if (!email) return toast("Enter your email address first, then click “Email me a login link”.", true);
    try { const { error } = await db.auth.signInWithOtp({ email, options: { emailRedirectTo: APP_URL, shouldCreateUser: false } }); if (error) throw error; toast(`Login link sent to ${email}. Check your inbox (and spam).`); } catch (err) { fail(/Signups not allowed/i.test(err.message) ? new Error("This email is not registered. Ask the admin to add you first.") : err); }
  });
  const pwError = msg => { $("pwError").textContent = msg || ""; $("pwError").classList.toggle("hidden", !msg); };
  $("pwForm").addEventListener("submit", async e => {
    e.preventDefault(); const a = $("pwNew").value, b = $("pwNew2").value; pwError("");
    if (a.length < 8) return pwError("Password must be at least 8 characters."); if (a !== b) return pwError("Passwords do not match.");
    busy(e.target, true);
    try {
      const { data: { session } } = await db.auth.getSession();
      if (!session) throw new Error("Your sign-in link has expired. Ask the admin for a new link, or use “Email me a login link” on the sign-in page.");
      const { error } = await db.auth.updateUser({ password: a }); if (error) throw error;
      try { localStorage.setItem("ft_pw_" + user?.id, "1"); } catch (_) {}
      toast("Password saved. You can now sign in with email + password."); closeDialog("pwDialog");
    } catch (err) { console.error(err); pwError(err.message || "Could not save the password. Please try again."); } finally { busy(e.target, false); }
  });
  $("pwSkip").addEventListener("click", () => { localStorage.setItem("ft_pw_" + user?.id, "1"); closeDialog("pwDialog"); });
  $("signOutBtn").addEventListener("click", async () => { const { error } = await db.auth.signOut(); if (error) fail(error); });
  ["refreshMembers", "refreshWallet", "refreshDeposits"].forEach(id => $(id).addEventListener("click", () => refreshAll().then(() => toast("Refreshed.")).catch(fail)));
  $("showInactive").addEventListener("change", renderMembers);
  $("walletFilter").addEventListener("change", renderWallet);
  $("addMemberBtn").addEventListener("click", () => openMemberDialog(null));
  $("recordDepositBtn").addEventListener("click", () => { $("depositAmount").value = 500; $("depositNote").value = ""; $("depositDialog").showModal(); });
  $("newMatchBtn").addEventListener("click", () => openMatchDialog(null));
  $("attendanceChoices").addEventListener("change", updateShareHint);
  $("matchCost").addEventListener("input", updateShareHint); $("extraCost").addEventListener("input", updateShareHint);
  $("selectAll").addEventListener("click", () => { $("attendanceChoices").querySelectorAll("input").forEach(i => i.checked = true); updateShareHint(); });
  $("selectNone").addEventListener("click", () => { $("attendanceChoices").querySelectorAll("input").forEach(i => i.checked = false); updateShareHint(); });

  $("memberForm").addEventListener("submit", async e => {
    e.preventDefault(); busy(e.target, true);
    try {
      const id = $("memberId").value;
      if (id) await rpc("admin_update_member", { p_profile_id: id, p_full_name: $("memberName").value.trim(), p_email: $("memberEmail").value.trim(), p_phone: $("memberPhone").value.trim(), p_role: $("memberRole").value, p_active: $("memberActive").value === "true" }, "Member updated.");
      else {
        const email = $("memberEmail").value.trim(), name = $("memberName").value.trim();
        await rpc("admin_add_member", { p_full_name: name, p_email: email, p_phone: $("memberPhone").value.trim() }, "Member added.");
        if (email && $("memberInvite").checked) { try { await sendInvite(email, name); toast(`Member added and invite emailed to ${email}.`); } catch (err) { toast(`Member added, but the invite email failed: ${err.message}. Use “Resend invite” later.`, true); } }
      }
      closeDialog("memberDialog");
    } catch (err) { fail(err); } finally { busy(e.target, false); }
  });
  $("depositForm").addEventListener("submit", async e => { e.preventDefault(); busy(e.target, true); try { await rpc("admin_wallet_adjustment", { p_profile_id: $("depositMember").value, p_type: "deposit", p_amount: Number($("depositAmount").value), p_description: $("depositNote").value.trim() || "Member deposit" }, "Deposit recorded."); closeDialog("depositDialog"); } catch (err) { fail(err); } finally { busy(e.target, false); } });
  $("adjustForm").addEventListener("submit", async e => { e.preventDefault(); busy(e.target, true); try { await rpc("admin_wallet_adjustment", { p_profile_id: $("adjustMemberId").value, p_type: $("adjustType").value, p_amount: Number($("adjustAmount").value), p_description: $("adjustReason").value.trim() }, "Wallet updated."); closeDialog("adjustDialog"); } catch (err) { fail(err); } finally { busy(e.target, false); } });
  $("requestForm").addEventListener("submit", async e => { e.preventDefault(); busy(e.target, true); try { await rpc("member_request_deposit", { p_amount: Number($("reqAmount").value), p_method: $("reqMethod").value, p_reference: $("reqReference").value.trim(), p_note: $("reqNote").value.trim() }, "Request submitted. The admin will confirm it soon."); $("reqReference").value = ""; $("reqNote").value = ""; } catch (err) { fail(err); } finally { busy(e.target, false); } });
  $("matchForm").addEventListener("submit", async e => {
    e.preventDefault(); busy(e.target, true);
    try {
      const id = $("matchId").value;
      const editing = id ? matches.find(x => x.id === id) : null;
      const voting = editing ? editing.status === "voting" : $("matchVoting").checked;
      const ids = voting ? [] : [...$("attendanceChoices").querySelectorAll("input:checked")].map(x => x.value);
      if (!voting && !ids.length) throw new Error("Select at least one attending player.");
      const args = { p_match_date: $("matchDate").value, p_venue: $("matchVenue").value.trim(), p_turf_cost: Number($("matchCost").value), p_extra_cost: Number($("extraCost").value || 0), p_notes: $("matchNotes").value.trim(), p_attendee_ids: ids };
      if (id) await rpc("admin_update_match", { p_match_id: id, ...args }, "Match updated.");
      else await rpc("admin_create_match", { ...args, p_open_voting: voting }, voting ? "Match proposed. Every member has been notified to vote." : "Match created. Review it and settle when ready.");
      closeDialog("matchDialog");
    } catch (err) { fail(err); } finally { busy(e.target, false); }
  });
  $("settleForm").addEventListener("submit", async e => { e.preventDefault(); busy(e.target, true); try { await rpc("admin_settle_match", { p_match_id: $("settleMatchId").value }, "Match settled. Wallets have been updated."); closeDialog("settleDialog"); } catch (err) { fail(err); } finally { busy(e.target, false); } });
  $("reviewForm").addEventListener("submit", async e => { e.preventDefault(); busy(e.target, true); try { await rpc("admin_review_deposit", { p_request_id: $("reviewId").value, p_approve: true, p_note: $("reviewNote").value.trim() }, "Deposit approved and wallet credited."); closeDialog("reviewDialog"); } catch (err) { fail(err); } finally { busy(e.target, false); } });
  $("rejectBtn").addEventListener("click", async () => { try { await rpc("admin_review_deposit", { p_request_id: $("reviewId").value, p_approve: false, p_note: $("reviewNote").value.trim() }, "Request rejected."); closeDialog("reviewDialog"); } catch (err) { fail(err); } });
  $("exportCsv").addEventListener("click", exportSummaryCsv); $("exportLedgerCsv").addEventListener("click", exportLedgerCsv);
  $("menuToggle").addEventListener("click", () => $("sidebar").classList.toggle("open"));
  $("bellBtn").addEventListener("click", () => $("notifPanel").classList.toggle("hidden"));
  $("markAllRead").addEventListener("click", async () => { notifications.forEach(n => n.read = true); renderBell(); try { const { error } = await db.rpc("mark_notifications_read", { p_ids: null }); if (error) throw error; } catch (err) { fail(err); } });
  $("enableAlertsBtn").addEventListener("click", async () => { try { const r = await Notification.requestPermission(); toast(r === "granted" ? "Alerts enabled for this device while the app is open." : "Alerts not enabled.", r !== "granted"); renderBell(); } catch (err) { fail(err); } });
  $("matchVoting").addEventListener("change", () => toggleVotingUi($("matchVoting").checked));
  window.addEventListener("beforeinstallprompt", e => { e.preventDefault(); installPrompt = e; $("installBtn").classList.remove("hidden"); });
  $("installBtn").addEventListener("click", async () => { if (!installPrompt) return; installPrompt.prompt(); await installPrompt.userChoice; installPrompt = null; $("installBtn").classList.add("hidden"); });
  if ("serviceWorker" in navigator && location.protocol === "https:") navigator.serviceWorker.register("sw.js").catch(console.warn);
  init().catch(fail);
})();
