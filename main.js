import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const config = window.TRIP_APP_CONFIG || {};
const app = document.querySelector('#app');
const account = document.querySelector('#account');
const toast = document.querySelector('#toast');
const inviteToken = new URLSearchParams(location.search).get('invite');
let db;
let user;
let profile;
let visibleEvents = [];
let activeEvent;
let bootstrapping = false;
let passwordRecovery = false;

const escapeHtml = (value = '') => String(value).replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char]);
const dateText = value => value ? new Date(`${value}T00:00:00`).toLocaleDateString('zh-TW', { month: '2-digit', day: '2-digit' }) : '';
const showToast = message => { toast.textContent = message; toast.classList.add('visible'); setTimeout(() => toast.classList.remove('visible'), 3000); };
const fail = error => { console.error(error); showToast(error.message || '操作失敗，請稍後再試'); };

if (!config.supabaseUrl || !config.supabaseAnonKey) {
  app.innerHTML = `<section class="auth"><div class="panel"><div class="eyebrow">部署設定</div><h1>連接 Supabase</h1><p class="sub">先建立 Supabase 專案、執行資料庫 migration，再將 Project URL 與 anon key 填入 <code>config.js</code>。</p><div class="notice">此應用不會把 service role key 放在前端。部署與資料庫設定步驟請見 <code>README.md</code>。</div></div></section>`;
} else {
  db = createClient(config.supabaseUrl, config.supabaseAnonKey);
  start();
}

async function start() {
  db.auth.onAuthStateChange((event, nextSession) => {
    user = nextSession?.user || null;
    if (event === 'PASSWORD_RECOVERY') { passwordRecovery = true; setTimeout(() => renderPasswordRecovery(), 0); }
    else if (user) { if (!passwordRecovery) setTimeout(loadAuthenticatedApp, 0); }
    else { profile = null; account.innerHTML = ''; renderAuth(); }
  });
  const { data: { session } } = await db.auth.getSession();
  user = session?.user || null;
  if (passwordRecovery) renderPasswordRecovery();
  else if (user) await loadAuthenticatedApp();
  else renderAuth();
}

async function loadAuthenticatedApp() {
  if (bootstrapping) return;
  bootstrapping = true;
  try {
    await redeemInvite();
    await loadApp();
  } catch (error) {
    fail(error);
    await loadApp();
  } finally {
    bootstrapping = false;
  }
}

function renderAuth(register = false, message = '') {
  account.innerHTML = '';
  app.innerHTML = `<section class="auth"><div class="panel"><div class="eyebrow">好友旅行</div><h1>${register ? '建立你的帳號' : '登入行程系統'}</h1><p class="sub">建立一次帳號，之後受邀活動都能使用同一份個人資料。</p>${message ? `<p class="notice">${escapeHtml(message)}</p>` : ''}<form id="auth-form">${register ? `<div class="field"><label for="full-name">中文全名</label><input id="full-name" name="fullName" autocomplete="name" required maxlength="100"></div>` : ''}<div class="field"><label for="email">電子郵件</label><input id="email" name="email" type="email" autocomplete="email" required></div><div class="field"><label for="password">密碼</label><input id="password" name="password" type="password" autocomplete="${register ? 'new-password' : 'current-password'}" minlength="8" required></div><button class="button" type="submit">${register ? '註冊' : '登入'}</button></form>${!register ? '<button class="link-button" id="forgot-password" type="button">忘記密碼？寄送重設連結</button>' : ''}<button class="link-button switch-auth" id="switch-auth">${register ? '已有帳號？登入' : '第一次使用？建立帳號'}</button></div></section>`;
  document.querySelector('#switch-auth').addEventListener('click', () => renderAuth(!register));
  document.querySelector('#forgot-password')?.addEventListener('click', async () => {
    const email = document.querySelector('#email').value.trim().toLowerCase();
    if (!email) { renderAuth(false, '請先輸入註冊時使用的電子郵件，再點選忘記密碼。'); return; }
    try {
      const { error } = await db.auth.resetPasswordForEmail(email, { redirectTo: `${location.origin}${location.pathname}` });
      if (error) throw error;
      renderAuth(false, '若此信箱已註冊，系統已寄出密碼重設信，請依信件指示設定新密碼。');
    } catch (error) { fail(error); }
  });
  document.querySelector('#auth-form').addEventListener('submit', async event => {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    const email = String(form.get('email')).trim().toLowerCase();
    const password = String(form.get('password'));
    try {
      if (register) {
        const { data, error } = await db.auth.signUp({ email, password, options: { data: { full_name: String(form.get('fullName')).trim() }, emailRedirectTo: location.href } });
        if (error) throw error;
        if (data.session) { user = data.user; await loadAuthenticatedApp(); }
        else renderAuth(false, '註冊請求已送出。若是第一次註冊，請到信箱收取驗證信；若此信箱曾註冊，請改為登入或使用忘記密碼。未收到信時請檢查垃圾郵件，或聯絡管理者確認郵件寄送設定。');
      } else {
        const { data, error } = await db.auth.signInWithPassword({ email, password });
        if (error) throw error;
        user = data.user;
        await loadAuthenticatedApp();
      }
    } catch (error) {
      if (!register && error.message === 'Invalid login credentials') {
        renderAuth(false, '帳號或密碼不正確。請確認註冊信箱與密碼；若仍無法登入，請使用「忘記密碼」寄送重設連結。');
      } else if (register && /email|mail|smtp|rate limit/i.test(error.message || '')) {
        renderAuth(true, '帳號註冊或驗證信寄送失敗，請稍後再試；若持續發生，請聯絡管理者檢查 Supabase Auth 郵件服務。');
      } else fail(error);
    }
  });
}

function renderPasswordRecovery(message = '') {
  account.innerHTML = '';
  app.innerHTML = `<section class="auth"><div class="panel"><div class="eyebrow">帳號安全</div><h1>設定新密碼</h1><p class="sub">請輸入至少 8 個字元的新密碼。</p>${message ? `<p class="error">${escapeHtml(message)}</p>` : ''}<form id="recovery-form"><div class="field"><label for="new-password">新密碼</label><input id="new-password" type="password" autocomplete="new-password" minlength="8" required></div><div class="field"><label for="confirm-password">再次輸入新密碼</label><input id="confirm-password" type="password" autocomplete="new-password" minlength="8" required></div><button class="button" type="submit">更新密碼</button></form></div></section>`;
  document.querySelector('#recovery-form').addEventListener('submit', async event => {
    event.preventDefault();
    const password = document.querySelector('#new-password').value;
    if (password !== document.querySelector('#confirm-password').value) { renderPasswordRecovery('兩次輸入的密碼不一致，請重新輸入。'); return; }
    try {
      const { error } = await db.auth.updateUser({ password });
      if (error) throw error;
      await db.auth.signOut();
      passwordRecovery = false;
      history.replaceState({}, '', `${location.pathname}${location.search}`);
      renderAuth(false, '密碼已更新，請使用新密碼登入。');
    } catch (error) { renderPasswordRecovery(error.message || '更新密碼失敗，請重新寄送重設信。'); }
  });
}

async function loadApp() {
  app.innerHTML = '<div class="loading">載入活動資料…</div>';
  try {
    const [{ data: profileData, error: profileError }, { data: events, error: eventsError }, { data: memberships, error: membersError }] = await Promise.all([
      db.from('profiles').select('*').eq('id', user.id).single(),
      db.from('events').select('*').eq('published', true).order('starts_on'),
      db.from('event_members').select('event_id,status').eq('user_id', user.id)
    ]);
    if (profileError) throw profileError;
    if (eventsError) throw eventsError;
    if (membersError) throw membersError;
    profile = profileData;
    visibleEvents = events || [];
    account.innerHTML = `<div class="right"><span class="user-email">${escapeHtml(profile.full_name || user.email)}${profile.role !== 'member' ? ` · ${profile.role === 'owner' ? '擁有人' : '管理者'}` : ''}</span><button class="button secondary" id="sign-out">登出</button></div>`;
    document.querySelector('#sign-out').addEventListener('click', () => db.auth.signOut());
    const memberEventIds = new Set((memberships || []).map(item => item.event_id));
    renderOverview(memberEventIds);
  } catch (error) { app.innerHTML = `<div class="error">${escapeHtml(error.message)}</div>`; }
}

async function redeemInvite() {
  const token = new URLSearchParams(location.search).get('invite');
  if (!token || !user) return;
  const { error } = await db.rpc('accept_invitation', { p_token: token });
  if (error) throw error;
  history.replaceState({}, '', location.pathname);
  showToast('邀請已確認，活動已加入你的總覽');
}

function renderOverview(memberEventIds) {
  const manager = ['owner', 'admin'].includes(profile.role);
  const cards = visibleEvents.map(event => {
    const invited = memberEventIds.has(event.id);
    const canOpen = invited || manager;
    return `<article class="event-card"><div class="cover ${event.event_type === 'international' ? 'foreign' : ''}"><span class="pill">${event.event_type === 'international' ? '國外旅行' : '國內旅行'}</span></div><div class="event-info"><h3>${escapeHtml(event.title)}</h3><p>${dateText(event.starts_on)}－${dateText(event.ends_on)}　・　${escapeHtml(event.destination || '')}</p><div class="event-foot"><span class="pill ${invited ? '' : 'locked'}">${invited ? '✓ 已受邀' : manager ? '管理者檢視' : '尚未受邀'}</span><button class="link-button open-event" data-id="${event.id}" ${canOpen ? '' : 'disabled'}>${canOpen ? '查看活動 →' : '未收到邀請'}</button></div></div></article>`;
  }).join('');
  app.innerHTML = `<div class="page-head"><div><div class="eyebrow">好友旅行　/　活動總覽</div><h1>看看最近有哪些行程</h1><div class="sub">你可以瀏覽所有活動；收到邀請後才能報名參加。</div></div></div><div class="count-banner"><strong>${visibleEvents.length}</strong><span>目前共有 ${visibleEvents.length} 個活動<br>活動採邀請制，只有收到邀請的成員可以進入報名。</span></div>${cards ? `<div class="event-grid">${cards}</div>` : '<div class="empty">目前沒有開放檢視的活動。</div>'}`;
  document.querySelectorAll('.open-event').forEach(button => button.addEventListener('click', () => openEvent(button.dataset.id)));
  if (profile.role === 'owner' || profile.role === 'admin') addAdminLink();
}

function addAdminLink() {
  const tabs = document.createElement('div');
  tabs.className = 'tabs';
  tabs.innerHTML = '<button class="tab" id="admin-open">管理後台</button>';
  app.querySelector('.page-head').after(tabs);
  document.querySelector('#admin-open').addEventListener('click', renderAdmin);
}

async function openEvent(eventId) {
  try {
    const event = visibleEvents.find(item => item.id === eventId);
    const manager = ['owner', 'admin'].includes(profile.role);
    const [{ data: membership, error: membershipError }, { data: rooms, error: roomError }, { data: vehicles, error: vehicleError }] = await Promise.all([
      db.from('event_members').select('*').eq('event_id', eventId).eq('user_id', user.id).eq('status', 'registered').maybeSingle(),
      db.from('rooms').select('*').eq('event_id', eventId).order('created_at'),
      db.from('vehicles').select('*').eq('event_id', eventId).order('created_at')
    ]);
    if (membershipError) throw membershipError;
    if (roomError) throw roomError;
    if (vehicleError) throw vehicleError;
    if (!membership && !manager) return showToast('只有收到此活動邀請的成員可以進入。');
    const showResources = event.resource_selection_open && (manager || membership?.attendance_status === 'attending');
    let roster = [];
    if (showResources) {
      const { data, error } = await db.rpc('resource_roster', { p_event_id: eventId });
      if (error) throw error;
      roster = data || [];
    }
    activeEvent = event;
    renderEvent(event, membership, rooms || [], vehicles || [], roster, manager);
  } catch (error) { fail(error); }
}

function renderEvent(event, membership, rooms, vehicles, roster, manager) {
  const attending = membership?.attendance_status === 'attending';
  const canSelectResources = attending && event.resource_selection_open;
  const roomMap = new Map();
  const vehicleMap = new Map();
  roster.forEach(item => (item.resource_type === 'room' ? roomMap : vehicleMap).set(item.resource_id, [...((item.resource_type === 'room' ? roomMap : vehicleMap).get(item.resource_id) || []), item.full_name]));
  const roomCards = rooms.map(room => {
    const names = roomMap.get(room.id) || [];
    const remaining = Math.max(0, room.capacity - names.length);
    return `<div class="resource"><div class="row"><span class="resource-name">${escapeHtml(room.name)}</span><span class="meta">${remaining ? `還有 ${remaining} 位` : '已滿房'}</span></div><div class="bar"><span style="width:${Math.min(100, names.length / room.capacity * 100)}%"></span></div><div class="row"><span class="member-list">${names.length ? `已選：${names.map(escapeHtml).join('、')}` : '目前尚無團員'}</span>${canSelectResources ? `<button class="select-button reserve" data-type="room" data-id="${room.id}" ${remaining ? '' : 'disabled'}>${remaining ? '選這間' : '已滿房'}</button>` : ''}</div></div>`;
  }).join('') || '<p class="small">管理者尚未設定房間。</p>';
  const carCards = vehicles.map(vehicle => {
    const names = vehicleMap.get(vehicle.id) || [];
    const remaining = Math.max(0, vehicle.seats - names.length);
    return `<div class="resource"><div class="row"><span class="resource-name">${escapeHtml(vehicle.name)}</span><span class="meta">${remaining ? `還有 ${remaining} 位` : '座位已滿'}</span></div><div class="meta">駕駛・${escapeHtml(vehicle.driver_name || '')}　${escapeHtml(vehicle.departure || '')}</div><div class="bar"><span style="width:${vehicle.seats ? Math.min(100, names.length / vehicle.seats * 100) : 100}%"></span></div><div class="row"><span class="member-list">${names.length ? `已選：${names.map(escapeHtml).join('、')}` : '目前尚無乘客'}</span>${canSelectResources ? `<button class="select-button reserve" data-type="vehicle" data-id="${vehicle.id}" ${remaining ? '' : 'disabled'}>${remaining ? '選這台' : '座位已滿'}</button>` : ''}</div></div>`;
  }).join('') || '<p class="small">管理者尚未設定共乘車輛。</p>';
  const foreign = event.event_type === 'international';
  const responsePanel = membership ? `<section class="panel"><strong>第一階段｜基本資料與報名意願</strong><p class="small">${membership.attendance_status === 'attending' ? '目前回覆：確定參加' : membership.attendance_status === 'not_attending' ? '目前回覆：不參加' : '請填寫基本資料並選擇是否參加。'}</p></section>` : '';
  const resourceStage = event.resource_selection_open && (manager || attending)
    ? `<div class="section-title"><h2>第二階段｜選擇房間與共乘</h2><span class="small">名額由管理者設定・先選先得</span></div><div class="stat-grid"><div class="stat"><span>已選房或共乘</span><strong>${new Set(roster.map(r => r.user_id)).size}</strong></div><div class="stat"><span>房間名額</span><strong>${rooms.reduce((sum, item) => sum + item.capacity, 0)}</strong></div><div class="stat"><span>共乘座位</span><strong>${vehicles.reduce((sum, item) => sum + item.seats, 0)}</strong></div></div><div class="resource-grid"><section class="panel"><div class="resource-head"><h3>⌂　房間選擇</h3></div>${roomCards}</section><section class="panel"><div class="resource-head"><h3>▱　共乘安排</h3></div>${carCards}</section></div>`
    : `<section class="panel"><strong>第二階段｜房間與共乘</strong><p class="small">${manager ? '尚未開放。請先收集報名意願，再於管理後台設定房間／車輛並開放選擇。' : attending ? '管理者確認參加名單與車輛後，會另行通知開放選擇。' : '請先回覆參加意願；房間與共乘將於第二階段開放。'}</p></section>`;
  const attendance = membership?.attendance_status || '';
  const profilePanel = membership ? `<div class="section-title"><h2>個人資料</h2><span class="small">本次活動資料僅本人與管理者可查看</span></div><section class="panel"><form id="profile-form"><div class="field-grid"><div class="field"><label>中文全名</label><input name="full_name" required value="${escapeHtml(profile.full_name || '')}"></div><div class="field"><label>護照英文姓名 ${foreign ? '（必填）' : '（選填）'}</label><input name="passport_english_name" ${foreign ? 'required' : ''} value="${escapeHtml(membership.passport_english_name || profile.passport_english_name || '')}"></div><div class="field"><label>電話</label><input name="phone" required value="${escapeHtml(membership.phone || profile.phone || '')}"></div><div class="field"><label>年齡</label><input name="age" type="number" min="0" max="120" required value="${escapeHtml(membership.age ?? profile.age ?? '')}"></div><div class="field"><label>是否參加</label><select name="attendance" required ${event.registration_open ? '' : 'disabled'}><option value="">請選擇</option><option value="attending" ${attendance === 'attending' ? 'selected' : ''}>我要參加</option><option value="not_attending" ${attendance === 'not_attending' ? 'selected' : ''}>暫不參加</option></select></div></div>${foreign ? insuranceForm(event, membership) : ''}<button class="button" type="submit">${event.registration_open ? '儲存資料與報名意願' : '儲存資料'}</button></form></section>` : `<section class="panel"><p class="small">管理者檢視模式。你可以查看活動內容與報名概況，不會以團員身分提交資料或選位。</p></section>`;
  app.innerHTML = `<button class="link-button" id="back">← 返回活動總覽</button><div class="page-head"><div><div class="eyebrow">${foreign ? '國外旅行' : '國內旅行'}　/　${membership ? '已受邀' : '管理者檢視'}</div><h1>${escapeHtml(event.title)}</h1><div class="sub">${dateText(event.starts_on)}－${dateText(event.ends_on)}　・　${escapeHtml(event.destination || '')}</div></div><span class="pill">${event.registration_open ? '第一階段報名中' : '報名已截止'}</span></div>${responsePanel}${resourceStage}<div class="section-title"><h2>活動說明</h2></div><section class="panel"><p>${escapeHtml(event.description || '尚無活動說明。')}</p></section>${profilePanel}`;
  document.querySelector('#back').addEventListener('click', loadApp);
  document.querySelectorAll('.reserve').forEach(button => button.addEventListener('click', async () => {
    try {
      const rpc = button.dataset.type === 'room' ? 'choose_room' : 'choose_vehicle';
      const args = button.dataset.type === 'room' ? { p_event_id: event.id, p_room_id: button.dataset.id } : { p_event_id: event.id, p_vehicle_id: button.dataset.id };
      const { error } = await db.rpc(rpc, args);
      if (error) throw error;
      showToast('已完成選擇');
      await openEvent(event.id);
    } catch (error) { fail(error); }
  }));
  document.querySelector('#profile-form')?.addEventListener('submit', async formEvent => {
    formEvent.preventDefault();
    const values = Object.fromEntries(new FormData(formEvent.currentTarget));
    try {
      const { error: profileError } = await db.from('profiles').update({ full_name: values.full_name, passport_english_name: values.passport_english_name, phone: values.phone, age: Number(values.age) }).eq('id', user.id);
      if (profileError) throw profileError;
      const { error: memberError } = await db.rpc('update_my_event_details', { p_event_id: event.id, p_passport_english_name: values.passport_english_name, p_phone: values.phone, p_age: Number(values.age), p_insurance_opt_in: document.querySelector('input[name="insurance"]:checked')?.value === 'yes' });
      if (memberError) throw memberError;
      if (event.registration_open && ['attending', 'not_attending'].includes(values.attendance)) {
        const { error: attendanceError } = await db.rpc('respond_to_event', { p_event_id: event.id, p_attending: values.attendance === 'attending' });
        if (attendanceError) throw attendanceError;
      }
      profile = { ...profile, ...values, age: Number(values.age) };
      showToast(event.registration_open ? '基本資料與報名意願已儲存' : '個人資料已儲存');
      await openEvent(event.id);
    } catch (error) { fail(error); }
  });
  wireInsurance();
}

function insuranceForm(event, membership) {
  if (!event.insurance_enabled) return '<section class="panel"><h3>旅平險</h3><p class="small">本活動未提供團體旅平險，請自行向保險公司投保。</p></section>';
  const checked = membership.insurance_opt_in === false ? 'no' : 'yes';
  return `<div class="section-title"><h2>旅平險方案</h2></div><section class="panel"><p class="small">若選擇不加保，請自行向保險公司投保。</p><div class="insurance-options"><label class="insurance-option ${checked === 'yes' ? 'selected' : ''}"><input type="radio" name="insurance" value="yes" ${checked === 'yes' ? 'checked' : ''}><strong>我要加保</strong><span>保額 NT$ ${Number(event.insurance_coverage).toLocaleString()} 萬</span></label><label class="insurance-option ${checked === 'no' ? 'selected' : ''}"><input type="radio" name="insurance" value="no" ${checked === 'no' ? 'checked' : ''}><strong>不需要</strong><span>我會自行安排旅平險</span></label></div><div id="premium" class="premium ${checked === 'yes' ? 'visible' : ''}">本次旅平險保費：<strong>NT$ ${Number(event.insurance_premium).toLocaleString()} / 人</strong></div></section>`;
}

function wireInsurance() {
  document.querySelectorAll('input[name="insurance"]').forEach(input => input.addEventListener('change', () => {
    document.querySelectorAll('.insurance-option').forEach(option => option.classList.toggle('selected', option.contains(input) && input.checked));
    document.querySelector('#premium')?.classList.toggle('visible', input.value === 'yes' && input.checked);
  }));
}

async function renderAdmin() {
  if (!['owner', 'admin'].includes(profile.role)) return showToast('沒有管理權限');
  const roleControl = profile.role === 'owner' ? `<select name="role"><option value="member">團員</option><option value="admin">管理者</option></select>` : '<span class="small">只有擁有人可變更管理者</span>';
  const profilesQuery = profile.role === 'owner' ? db.from('profiles').select('id,full_name,role').order('full_name') : Promise.resolve({ data: [] });
  const [{ error: memberError }, roleResult] = await Promise.all([db.from('profiles').select('id').limit(1), profilesQuery]);
  if (memberError) return fail(memberError);
  const people = (roleResult.data || []).filter(item => item.id !== user.id).map(item => `<div class="member-row"><span>${escapeHtml(item.full_name || '未填姓名')}　<span class="small">${escapeHtml(item.role)}</span></span><span class="right">${profile.role === 'owner' ? `<select class="role-select" data-user="${item.id}"><option value="member" ${item.role === 'member' ? 'selected' : ''}>團員</option><option value="admin" ${item.role === 'admin' ? 'selected' : ''}>管理者</option></select><button class="link-button save-role" data-user="${item.id}">儲存</button>` : ''}</span></div>`).join('');
  app.innerHTML = `<div class="page-head"><div><div class="eyebrow">系統管理　/　管理者專區</div><h1>管理後台</h1><div class="sub">先收集參加意願，再設定房間、車輛並開放第二階段。</div></div><button class="button secondary" id="admin-back">返回活動總覽</button></div><div class="tabs"><button class="tab active">活動管理</button></div><section class="panel"><h2 style="font-size:17px;margin-top:0">新增活動｜第一階段</h2><form id="event-form"><div class="field-grid"><div class="field"><label>活動名稱</label><input name="title" required></div><div class="field"><label>國內／國外</label><select name="event_type"><option value="domestic">國內</option><option value="international">國外</option></select></div><div class="field"><label>目的地</label><input name="destination" required></div><div class="field"><label>報名階段</label><select name="registration_open"><option value="true">開放基本資料與參加意願</option><option value="false">暫不開放報名</option></select></div><div class="field"><label>開始日期</label><input name="starts_on" type="date" required></div><div class="field"><label>結束日期</label><input name="ends_on" type="date" required></div></div><div class="field"><label>活動說明</label><textarea name="description"></textarea></div><label class="field"><span><input type="checkbox" name="insurance_enabled"> 提供國外團體旅平險方案</span></label><div class="field-grid" id="insurance-settings"><div class="field"><label>保額（萬元）</label><input name="insurance_coverage" type="number" value="500" min="1"></div><div class="field"><label>保費（元／人）</label><input name="insurance_premium" type="number" value="380" min="0"></div></div><p class="small">此階段不設定車輛與房間；待團員回覆後再進入「名額設定」安排第二階段。</p><button class="button" type="submit">建立活動</button></form></section><div class="section-title"><h2>現有活動</h2></div><section class="panel">${visibleEvents.map(event => `<div class="member-row"><span>${escapeHtml(event.title)}　<span class="small">${event.event_type === 'international' ? '國外' : '國內'}・${event.resource_selection_open ? '房間／共乘開放中' : '等待第二階段'}・${event.published ? '公開顯示' : '草稿'}</span></span><button class="link-button manage-event" data-id="${event.id}">名額設定</button></div>`).join('') || '<p class="small">尚未建立活動。</p>'}</section>${profile.role === 'owner' ? `<div class="section-title"><h2>管理者權限</h2></div><section class="panel"><p class="small">只有系統擁有人可以指派或移除管理者；管理者不能再指派其他管理者。</p>${people || '<p class="small">尚無其他使用者。</p>'}</section>` : ''}`;
  document.querySelector('#admin-back').addEventListener('click', loadApp);
  document.querySelector('#event-form').addEventListener('submit', createEvent);
  document.querySelectorAll('.save-role').forEach(button => button.addEventListener('click', async () => {
    const selectedRole = document.querySelector(`.role-select[data-user="${button.dataset.user}"]`).value;
    const { error } = await db.rpc('set_user_role', { p_user_id: button.dataset.user, p_role: selectedRole });
    if (error) return fail(error);
    showToast('管理者權限已更新');
  }));
  document.querySelectorAll('.manage-event').forEach(button => button.addEventListener('click', () => renderEventSettings(button.dataset.id)));
}

async function createEvent(event) {
  event.preventDefault();
  const values = Object.fromEntries(new FormData(event.currentTarget));
  const insurance = event.currentTarget.elements.insurance_enabled.checked;
  try {
    const { data: created, error } = await db.from('events').insert({ title: values.title, event_type: values.event_type, destination: values.destination, starts_on: values.starts_on, ends_on: values.ends_on, description: values.description, registration_open: values.registration_open === 'true', insurance_enabled: values.event_type === 'international' && insurance, insurance_coverage: Number(values.insurance_coverage || 0), insurance_premium: Number(values.insurance_premium || 0), owner_user_id: user.id }).select().single();
    if (error) throw error;
    showToast('活動已建立');
    await loadApp();
  } catch (error) { fail(error); }
}

async function renderEventSettings(eventId) {
  const event = visibleEvents.find(item => item.id === eventId);
  const [{ data: rooms, error: roomError }, { data: vehicles, error: vehicleError }, { data: members, error: membersError }] = await Promise.all([
    db.from('rooms').select('*').eq('event_id', eventId).order('created_at'),
    db.from('vehicles').select('*').eq('event_id', eventId).order('created_at'),
    db.from('event_members').select('user_id,attendance_status').eq('event_id', eventId).eq('status', 'registered')
  ]);
  if (roomError) return fail(roomError);
  if (vehicleError) return fail(vehicleError);
  if (membersError) return fail(membersError);
  const memberIds = (members || []).map(item => item.user_id);
  let profiles = [];
  if (memberIds.length) {
    const { data, error } = await db.from('profiles').select('id,full_name').in('id', memberIds);
    if (error) return fail(error);
    profiles = data || [];
  }
  const profileNames = new Map(profiles.map(item => [item.id, item.full_name]));
  const attendanceNames = (members || []).map(item => `<div class="member-row"><span>${escapeHtml(profileNames.get(item.user_id) || '未填姓名')}</span><span class="small">${item.attendance_status === 'attending' ? '確定參加' : item.attendance_status === 'not_attending' ? '不參加' : '尚未回覆'}</span></div>`).join('') || '<p class="small">尚無受邀者回覆。</p>';
  app.innerHTML = `<button class="link-button" id="settings-back">← 返回管理後台</button><div class="page-head"><div><div class="eyebrow">名額管理</div><h1>${escapeHtml(event.title)}</h1><div class="sub">先確認參加名單，再設定房間與車輛並開放第二階段。</div></div></div><section class="panel"><div class="row"><div><strong>建立邀請連結</strong><p class="small">可設定此連結允許幾位朋友使用。</p></div><span class="right"><input id="invite-uses" aria-label="邀請連結可使用人數" type="number" min="1" max="100" value="1"><button class="button" id="new-invite">建立連結</button></span></div></section><div class="section-title"><h2>第一階段｜報名意願</h2><span class="small">${members?.filter(item => item.attendance_status === 'attending').length || 0} 人確定參加</span></div><section class="panel">${attendanceNames}</section><div class="section-title"><h2>第二階段｜房間與共乘設定</h2></div><section class="panel"><p class="small">確認報名名單及車輛後，先新增房間／車輛，接著開放選位。開放後可另行通知團員。</p><button class="button ${event.resource_selection_open ? 'secondary' : ''}" id="toggle-resources">${event.resource_selection_open ? '關閉房間與共乘選擇' : '開放房間與共乘選擇'}</button></section><div class="resource-grid" style="margin-top:14px"><section class="panel"><div class="resource-head"><h3>房間名額</h3></div>${rooms.map(room => `<div class="resource row"><label>${escapeHtml(room.name)}</label><span class="right"><input class="capacity-input" type="number" min="1" value="${room.capacity}" data-table="rooms" data-id="${room.id}"><button class="link-button save-capacity">儲存</button></span></div>`).join('') || '<p class="small">尚無房間。</p>'}<form id="add-room-form"><div class="field"><label>新增房間（房名｜床位數）</label><div class="row"><input name="name" required placeholder="山景四人房"><input name="capacity" type="number" min="1" required placeholder="4"><button class="button" type="submit">新增</button></div></div></form></section><section class="panel"><div class="resource-head"><h3>共乘車輛</h3></div>${vehicles.map(vehicle => `<div class="resource row"><label>${escapeHtml(vehicle.name)}・${escapeHtml(vehicle.driver_name || '')}</label><span class="right"><input class="capacity-input" type="number" min="0" value="${vehicle.seats}" data-table="vehicles" data-id="${vehicle.id}"><button class="link-button save-capacity">儲存</button></span></div>`).join('') || '<p class="small">尚無車輛。</p>'}<form id="add-vehicle-form"><div class="field"><label>新增車輛</label><input name="name" required placeholder="小美的車"><input name="driver_name" required placeholder="駕駛姓名"><div class="row"><input name="seats" type="number" min="0" required placeholder="乘客座位"><input name="departure" placeholder="出發地"><button class="button" type="submit">新增</button></div></div></form></section></div><div id="invite-result"></div>`;
  document.querySelector('#settings-back').addEventListener('click', renderAdmin);
  document.querySelector('#toggle-resources').addEventListener('click', async () => {
    const { error } = await db.from('events').update({ resource_selection_open: !event.resource_selection_open }).eq('id', eventId);
    if (error) return fail(error);
    visibleEvents = visibleEvents.map(item => item.id === eventId ? { ...item, resource_selection_open: !event.resource_selection_open } : item);
    showToast(event.resource_selection_open ? '已關閉第二階段選位' : '第二階段選位已開放，請另行通知團員');
    await renderEventSettings(eventId);
  });
  document.querySelector('#add-room-form').addEventListener('submit', async formEvent => {
    formEvent.preventDefault();
    const values = Object.fromEntries(new FormData(formEvent.currentTarget));
    const { error } = await db.from('rooms').insert({ event_id: eventId, name: values.name.trim(), capacity: Number(values.capacity) });
    if (error) return fail(error);
    showToast('房間已新增');
    await renderEventSettings(eventId);
  });
  document.querySelector('#add-vehicle-form').addEventListener('submit', async formEvent => {
    formEvent.preventDefault();
    const values = Object.fromEntries(new FormData(formEvent.currentTarget));
    const { error } = await db.from('vehicles').insert({ event_id: eventId, name: values.name.trim(), driver_name: values.driver_name.trim(), seats: Number(values.seats), departure: values.departure.trim() });
    if (error) return fail(error);
    showToast('車輛已新增');
    await renderEventSettings(eventId);
  });
  document.querySelectorAll('.save-capacity').forEach(button => button.addEventListener('click', async () => {
    const input = button.previousElementSibling;
    const field = input.dataset.table === 'rooms' ? 'capacity' : 'seats';
    const { error } = await db.from(input.dataset.table).update({ [field]: Number(input.value) }).eq('id', input.dataset.id);
    if (error) return fail(error);
    showToast('名額已更新');
  }));
  document.querySelector('#new-invite').addEventListener('click', async () => {
    const { data: token, error } = await db.rpc('create_invitation', { p_event_id: eventId, p_max_uses: Math.max(1, Math.min(100, Number(document.querySelector('#invite-uses').value))) });
    if (error) return fail(error);
    const link = `${location.origin}${location.pathname}?invite=${encodeURIComponent(token)}`;
    document.querySelector('#invite-result').innerHTML = `<section class="panel" style="margin-top:14px"><strong>邀請連結已建立</strong><p class="small">連結可供 ${escapeHtml(document.querySelector('#invite-uses').value)} 位朋友使用；每位受邀者完成註冊後會加入此活動。</p><div class="row"><input id="invite-link" readonly value="${escapeHtml(link)}"><button class="button" id="copy-invite">複製連結</button></div></section>`;
    document.querySelector('#copy-invite').addEventListener('click', async () => { await navigator.clipboard.writeText(link); showToast('邀請連結已複製'); });
  });
}
