/**
 * Tailscale Native KernelSU WebUI Frontend Controller
 */

// 1. 全局配置与状态
let modDir = '/data/adb/modules/tailscale_native';
let isRunning = false;
let currentStatus = null;
let pollTimer = null;
let logTimer = null;

// 初始化检测 Module Dir
try {
  if (typeof ksu !== 'undefined' && ksu.moduleInfo) {
    const info = JSON.parse(ksu.moduleInfo());
    if (info && info.moduleDir) {
      modDir = info.moduleDir;
    }
  }
} catch (e) {
  console.warn('Failed to get module dir from ksu.moduleInfo, using fallback:', modDir);
}

// 2. KernelSU Shell Bridge
function ksuExec(cmd, timeoutMs = 8000) {
  return new Promise((resolve) => {
    if (typeof ksu === 'undefined') {
      // 浏览器预览模式下的 Mock 数据
      handleMockExec(cmd, resolve);
      return;
    }

    let finished = false;
    const timer = setTimeout(() => {
      if (!finished) {
        finished = true;
        console.warn('ksuExec timeout for cmd:', cmd);
        resolve({ code: -1, stdout: '', stderr: 'Timeout' });
      }
    }, timeoutMs);

    const cbName = '__ksu_cb_' + Math.random().toString(36).substring(2) + '_' + Date.now();
    window[cbName] = (code, stdout, stderr) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      delete window[cbName];
      resolve({ code: code, stdout: stdout || '', stderr: stderr || '' });
    };

    try {
      ksu.exec(cmd, cbName);
    } catch (err) {
      try {
        const res = ksu.exec(cmd);
        if (finished) return;
        finished = true;
        clearTimeout(timer);
        delete window[cbName];
        resolve({ code: 0, stdout: res || '', stderr: '' });
      } catch (e2) {
        if (finished) return;
        finished = true;
        clearTimeout(timer);
        delete window[cbName];
        resolve({ code: -1, stdout: '', stderr: String(err) });
      }
    }
  });
}

function ksuToast(msg) {
  if (typeof ksu !== 'undefined' && ksu.toast) {
    ksu.toast(msg);
  }
  showWebToast(msg);
}

function showWebToast(msg) {
  const toast = document.getElementById('web-toast');
  if (!toast) return;
  toast.textContent = msg;
  toast.classList.remove('hidden');
  toast.style.opacity = '1';
  setTimeout(() => {
    toast.style.opacity = '0';
    setTimeout(() => toast.classList.add('hidden'), 300);
  }, 2200);
}

// 辅助方法：调用 control.sh
async function runControl(action, ...args) {
  const argStr = args.map(a => `"${String(a).replace(/"/g, '\\"')}"`).join(' ');
  const cmd = `sh "${modDir}/scripts/control.sh" ${action} ${argStr}`;
  const res = await ksuExec(cmd);
  return res.stdout.trim();
}

// 3. UI 元素引用
const el = {
  globalRefresh: document.getElementById('btn-global-refresh'),
  globalStatus: document.getElementById('badge-global-status'),
  coreVersionTag: document.getElementById('label-core-version-tag'),
  
  // Card 1
  pids: document.getElementById('val-pids'),
  tun: document.getElementById('val-tun'),
  backendState: document.getElementById('val-backend-state'),
  ipv4: document.getElementById('val-ipv4'),
  ipv6: document.getElementById('val-ipv6'),
  hostname: document.getElementById('val-hostname'),
  btnRenameHost: document.getElementById('btn-rename-host'),
  serverInfo: document.getElementById('val-server-info'),
  btnConfigServer: document.getElementById('btn-config-server'),

  // Service Management
  btnStart: document.getElementById('btn-start-service'),
  btnRestart: document.getElementById('btn-restart-service'),
  btnStop: document.getElementById('btn-stop-service'),

  // Auth
  authAlert: document.getElementById('auth-alert-banner'),
  inputAuthKey: document.getElementById('input-authkey'),
  btnLoginKey: document.getElementById('btn-login-key'),
  btnLoginUrl: document.getElementById('btn-login-url'),
  loginUrlBox: document.getElementById('login-url-container'),
  inputDisplayUrl: document.getElementById('input-display-url'),
  btnOpenLoginUrl: document.getElementById('btn-open-login-url'),
  btnCopyLoginUrl: document.getElementById('btn-copy-login-url'),
  btnLogout: document.getElementById('btn-logout'),

  // Peers
  btnRefreshPeers: document.getElementById('btn-refresh-peers'),
  peersEmptyNotice: document.getElementById('peers-empty-notice'),
  peersList: document.getElementById('peers-list'),

  // Routes & DNS
  switchAcceptRoutes: document.getElementById('switch-accept-routes'),
  switchAcceptDns: document.getElementById('switch-accept-dns'),

  // Exit Node
  selectExitNode: document.getElementById('select-exit-node'),
  inputManualExitNode: document.getElementById('input-manual-exit-node'),
  btnApplyExitNode: document.getElementById('btn-apply-exit-node'),
  btnClearExitNode: document.getElementById('btn-clear-exit-node'),
  switchAllowLan: document.getElementById('switch-allow-lan'),
  switchAdvExitNode: document.getElementById('switch-adv-exit-node'),
  switchAdvRoutes: document.getElementById('switch-adv-routes'),
  inputSubnetCidr: document.getElementById('input-subnet-cidr'),
  btnBroadcastSubnet: document.getElementById('btn-broadcast-subnet'),

  // Update
  btnCheckUpdate: document.getElementById('btn-check-update'),
  valCoreVer: document.getElementById('val-update-core-ver'),
  valLatestVer: document.getElementById('val-update-latest-ver'),
  switchAutoUpdate: document.getElementById('switch-auto-update'),
  selectUpdateInterval: document.getElementById('select-update-interval'),

  // Logs
  btnClearLogs: document.getElementById('btn-clear-logs'),
  btnCopyLogs: document.getElementById('btn-copy-logs'),
  logView: document.getElementById('daemon-log-view'),

  // Modal
  modalRename: document.getElementById('modal-rename'),
  inputModalHostname: document.getElementById('input-modal-hostname'),
  btnModalCancel: document.getElementById('btn-modal-cancel'),
  btnModalSave: document.getElementById('btn-modal-save'),

  // Net Config Modal
  modalNetConfig: document.getElementById('modal-network-config'),
  inputModalServer: document.getElementById('input-modal-server'),
  inputModalProxy: document.getElementById('input-modal-proxy'),
  btnModalNetCancel: document.getElementById('btn-modal-net-cancel'),
  btnModalNetSave: document.getElementById('btn-modal-net-save')
};

// 4. 状态刷新与渲染
let isRefreshingStatus = false;
async function refreshStatus() {
  if (isRefreshingStatus) return;
  isRefreshingStatus = true;
  try {
    const raw = await runControl('status');
    let data;
    try {
      data = JSON.parse(raw);
    } catch (err) {
      console.error('Failed to parse status json:', raw);
      return;
    }

    currentStatus = data;
    renderStatus(data);
  } catch (e) {
    console.error('refreshStatus error:', e);
  } finally {
    isRefreshingStatus = false;
  }
}

function renderStatus(data) {
  const running = !!data.running;
  isRunning = running;
  const ts = data.status_json || {};
  const selfNode = ts.Self || {};
  const backendState = ts.BackendState || (running ? 'Starting' : 'Stopped');

  // 1. 全局状态指示
  if (!running) {
    el.globalStatus.className = 'status-badge status-red';
    el.globalStatus.innerHTML = '<span class="status-dot"></span> 服务已停止';
  } else if (backendState === 'NeedsLogin') {
    el.globalStatus.className = 'status-badge status-warning';
    el.globalStatus.innerHTML = '<span class="status-dot"></span> 需要认证 (未登录)';
  } else if (backendState === 'Running') {
    el.globalStatus.className = 'status-badge status-green';
    el.globalStatus.innerHTML = '<span class="status-dot"></span> 运行中 (已连接)';
  } else {
    el.globalStatus.className = 'status-badge status-warning';
    el.globalStatus.innerHTML = `<span class="status-dot"></span> ${backendState}`;
  }

  // 2. 本机网络与系统状态卡片
  if (running && data.pids) {
    const pidsList = data.pids.split(/\s+/).filter(Boolean);
    el.pids.textContent = pidsList.slice(0, 2).join('  /  ') || data.pids;
  } else {
    el.pids.textContent = '-- / --';
  }

  if (running) {
    if (data.tun_ip) {
      el.tun.textContent = `tailscale0 (${data.tun_ip})`;
    } else {
      el.tun.textContent = 'tailscale0 (等待分配 IP)';
    }
  } else {
    el.tun.textContent = 'tailscale0 (未创建)';
  }

  // 连接状态
  if (backendState === 'Running') {
    el.backendState.className = 'status-value text-green';
    el.backendState.innerHTML = '✅ 正常连接运行 (Running)';
  } else if (backendState === 'NeedsLogin') {
    el.backendState.className = 'status-value text-warning';
    el.backendState.innerHTML = '<span class="icon-warning">⚠️</span> 身份登录认证 (NeedsLogin)';
  } else {
    el.backendState.className = 'status-value text-muted';
    el.backendState.innerHTML = `⚠️ ${backendState}`;
  }

  // IP 展现
  const ips = selfNode.TailscaleIPs || [];
  const ipv4 = ips.find(ip => ip.includes('.')) || data.tun_ip;
  const ipv6 = ips.find(ip => ip.includes(':'));

  el.ipv4.textContent = ipv4 || '- (未接入网络)';
  el.ipv4.className = ipv4 ? 'status-value text-primary font-mono' : 'status-value text-muted font-mono';

  el.ipv6.textContent = ipv6 || '- (未接入网络)';
  el.ipv6.className = ipv6 ? 'status-value text-primary font-mono' : 'status-value text-muted font-mono';

  // 主机名
  const host = selfNode.HostName || selfNode.DNSName?.replace(/\..*$/, '') || 'localhost';
  el.hostname.textContent = host + (host === 'localhost' ? ' (未重命名)' : '');

  // 后台与代理状态
  if (data.login_server) {
    let serverText = '自定义: ' + data.login_server.replace(/^https?:\/\//, '');
    if (data.proxy) serverText += ' (代理: ' + data.proxy.replace(/^https?:\/\//, '') + ')';
    el.serverInfo.textContent = serverText;
  } else if (data.proxy) {
    el.serverInfo.textContent = '官方后台 (代理: ' + data.proxy.replace(/^https?:\/\//, '') + ')';
  } else {
    el.serverInfo.textContent = '官方接口 · 极简通信串 · 登录网址: 见下';
  }

  // 3. 账号认证区块
  if (backendState === 'NeedsLogin') {
    el.authAlert.textContent = '⚠️ 设备未登录对应控制台网络，请登录绑定 (NeedsLogin)';
    el.authAlert.style.display = 'block';
    if (ts.AuthURL) {
      el.inputDisplayUrl.value = ts.AuthURL;
      el.loginUrlBox.classList.remove('hidden');
    }
  } else if (backendState === 'Running') {
    el.authAlert.textContent = '✅ 设备已成功绑定对应 Tailnet 控制台';
    el.authAlert.style.color = 'var(--color-green)';
    el.loginUrlBox.classList.add('hidden');
  } else {
    el.authAlert.style.display = 'none';
  }

  // 4. 路由与 DNS 开关
  if (selfNode) {
    if (typeof selfNode.AcceptRoutes !== 'undefined') {
      el.switchAcceptRoutes.checked = !!selfNode.AcceptRoutes;
    }
    if (typeof selfNode.AcceptDNS !== 'undefined') {
      el.switchAcceptDns.checked = !!selfNode.AcceptDNS;
    }
  }

  // 5. Exit Node 与 Peers 列表
  renderPeers(ts);
}

function renderPeers(ts) {
  const peers = ts.Peer || {};
  const peerKeys = Object.keys(peers);

  // 清空并重新构建 Exit Node 选项
  el.selectExitNode.innerHTML = '<option value="">-- 暂未发现可用 Exit Node --</option>';

  if (!isRunning || peerKeys.length === 0) {
    el.peersEmptyNotice.classList.remove('hidden');
    el.peersList.classList.add('hidden');
    return;
  }

  el.peersEmptyNotice.classList.add('hidden');
  el.peersList.classList.remove('hidden');
  el.peersList.innerHTML = '';

  peerKeys.forEach(k => {
    const p = peers[k];
    const name = p.HostName || p.DNSName?.replace(/\..*$/, '') || 'Peer';
    const os = p.OS || 'Linux';
    const ips = p.TailscaleIPs || [];
    const ipv4 = ips.find(ip => ip.includes('.')) || '';
    const ipv6 = ips.find(ip => ip.includes(':')) || '';
    const online = !!p.Online;
    const isExitNode = !!p.ExitNodeOption;
    const targetAddr = ipv4 || ipv6 || name;

    if (isExitNode) {
      const opt = document.createElement('option');
      opt.value = ipv4 || name;
      opt.textContent = `${name} (${ipv4}) ★ Exit Node`;
      el.selectExitNode.appendChild(opt);
    }

    const card = document.createElement('div');
    card.className = 'peer-card';
    card.innerHTML = `
      <div class="peer-header-row">
        <div class="peer-name-row">
          <span class="peer-name">${escapeHtml(name)}</span>
          <span class="peer-os-badge">${escapeHtml(os)}</span>
          ${isExitNode ? '<span class="badge-tag-mini">Exit Node</span>' : ''}
        </div>
        <div class="peer-status-wrap">
          <span class="peer-status-dot ${online ? '' : 'offline'}" title="${online ? '在线' : '离线'}"></span>
          <span class="font-small text-muted">${online ? '在线' : '离线'}</span>
        </div>
      </div>

      <div class="peer-ip-list">
        ${ipv4 ? `
        <div class="peer-ip-row">
          <span class="peer-ip-label">IPv4</span>
          <span class="peer-ip-val">${escapeHtml(ipv4)}</span>
          <button class="btn btn-outline-xs copy-peer-ip" data-ip="${escapeHtml(ipv4)}" data-type="IPv4">复制</button>
        </div>` : ''}
        ${ipv6 ? `
        <div class="peer-ip-row">
          <span class="peer-ip-label">IPv6</span>
          <span class="peer-ip-val">${escapeHtml(ipv6)}</span>
          <button class="btn btn-outline-xs copy-peer-ip" data-ip="${escapeHtml(ipv6)}" data-type="IPv6">复制</button>
        </div>` : ''}
        ${!ipv4 && !ipv6 ? '<div class="peer-ip-row text-muted font-small">未分配 IP 地址</div>' : ''}
      </div>

      <div class="peer-actions-row">
        <div class="ping-result-container">
          <span class="ping-result-badge" id="ping-res-${escapeHtml(k)}">未测速</span>
        </div>
        <button class="btn btn-outline-sm btn-ping-peer" data-target="${escapeHtml(targetAddr)}" data-name="${escapeHtml(name)}" data-key="${escapeHtml(k)}">
          ⚡ 测试延迟 (Ping)
        </button>
      </div>
    `;
    el.peersList.appendChild(card);
  });

  // 绑定复制按钮 (区分 IPv4 与 IPv6)
  el.peersList.querySelectorAll('.copy-peer-ip').forEach(btn => {
    btn.onclick = () => {
      const ip = btn.dataset.ip;
      const type = btn.dataset.type || 'IP';
      copyToClipboard(ip);
      ksuToast(`已复制 ${type}: ${ip}`);
    };
  });

  // 绑定 Ping 测速按钮
  el.peersList.querySelectorAll('.btn-ping-peer').forEach(btn => {
    btn.onclick = async () => {
      const target = btn.dataset.target;
      const name = btn.dataset.name || target;
      const key = btn.dataset.key;
      const badge = document.getElementById(`ping-res-${key}`);
      if (!target || !badge) return;

      btn.disabled = true;
      btn.textContent = '测速中...';
      badge.className = 'ping-result-badge testing';
      badge.innerHTML = '<span class="refresh-icon spinning">⟳</span> 测速中...';

      try {
        const raw = await runControl('ping_peer', target);
        let res = {};
        try { res = JSON.parse(raw); } catch (e) {}

        if (res.success && res.latency) {
          const isRelay = (res.type && res.type.includes('中继'));
          badge.className = `ping-result-badge ${isRelay ? 'relay' : 'success'}`;
          badge.textContent = `${res.latency} · ${res.type || '直连'}`;
          ksuToast(`[${name}] 延迟: ${res.latency} (${res.type || '直连'})`);
        } else {
          badge.className = 'ping-result-badge error';
          badge.textContent = res.latency || '不可达 / 超时';
          ksuToast(`[${name}] Ping 测试未响应: ${res.error || '超时'}`);
        }
      } catch (err) {
        badge.className = 'ping-result-badge error';
        badge.textContent = '测试失败';
      } finally {
        btn.disabled = false;
        btn.textContent = '⚡ 重新测速';
      }
    };
  });
}

// 5. 日志读取与刷新
let isRefreshingLogs = false;
async function refreshLogs() {
  if (isRefreshingLogs) return;
  isRefreshingLogs = true;
  try {
    const logs = await runControl('get_logs', 50);
    if (logs && el.logView) {
      el.logView.textContent = logs;
      el.logView.scrollTop = el.logView.scrollHeight;
    }
  } catch (e) {
    console.error('refreshLogs error:', e);
  } finally {
    isRefreshingLogs = false;
  }
}

// 6. 交互事件绑定
function bindEvents() {
  // 全局刷新
  el.globalRefresh.addEventListener('click', async () => {
    const icon = el.globalRefresh.querySelector('.refresh-icon');
    if (icon) icon.classList.add('spinning');
    await Promise.all([refreshStatus(), refreshLogs()]);
    setTimeout(() => {
      if (icon) icon.classList.remove('spinning');
      ksuToast('刷新完成');
    }, 400);
  });

  // 服务启停
  el.btnStart.addEventListener('click', async () => {
    ksuToast('正在启动 Tailscale 服务...');
    await runControl('start');
    await refreshStatus();
    await refreshLogs();
  });

  el.btnRestart.addEventListener('click', async () => {
    ksuToast('正在重启 Tailscale 服务...');
    await runControl('restart');
    await refreshStatus();
    await refreshLogs();
  });

  el.btnStop.addEventListener('click', async () => {
    ksuToast('正在停止 Tailscale 服务...');
    await runControl('stop');
    await refreshStatus();
    await refreshLogs();
  });

  // 认证
  el.btnLoginKey.addEventListener('click', async () => {
    const key = el.inputAuthKey.value.trim();
    if (!key) {
      ksuToast('请输入 Auth Key 密钥');
      return;
    }
    ksuToast('正在使用密钥一键绑定...');
    const out = await runControl('login_key', key);
    el.inputAuthKey.value = '';
    await refreshStatus();
    ksuToast('绑定指令已下发，请稍候查看状态');
  });

  el.btnLoginUrl.addEventListener('click', async () => {
    el.btnLoginUrl.disabled = true;
    el.btnLoginUrl.textContent = '正在获取链接...';
    ksuToast('正在请求网页登录地址...');
    try {
      const raw = await runControl('login_url');
      let data = {};
      try { data = JSON.parse(raw); } catch (e) {}

      if (data.login_url) {
        el.inputDisplayUrl.value = data.login_url;
        el.loginUrlBox.classList.remove('hidden');
        ksuToast('已获取登录链接，正在唤起浏览器...');
      } else {
        await refreshStatus();
        if (el.inputDisplayUrl.value) {
          el.loginUrlBox.classList.remove('hidden');
          ksuToast('已获取登录地址！');
        } else {
          ksuToast('已触发登录，请查看下方日志或等待控制台返回');
        }
      }
    } catch (e) {
      console.error('login_url error:', e);
      ksuToast('请求超时或失败，正在重新刷新状态');
    } finally {
      el.btnLoginUrl.disabled = false;
      el.btnLoginUrl.textContent = '获取网页登录链接';
    }
    await refreshStatus();
    await refreshLogs();
  });

  el.btnOpenLoginUrl.addEventListener('click', async () => {
    const url = el.inputDisplayUrl.value.trim();
    if (url) {
      window.open(url, '_blank');
      await runControl('open_url', url);
    }
  });

  el.btnCopyLoginUrl.addEventListener('click', () => {
    const url = el.inputDisplayUrl.value.trim();
    if (url) {
      copyToClipboard(url);
      ksuToast('登录链接已复制到剪贴板');
    }
  });

  el.btnLogout.addEventListener('click', async () => {
    if (confirm('确定要注销当前 Tailscale 账号绑定吗?')) {
      ksuToast('正在注销登录...');
      await runControl('logout');
      await refreshStatus();
    }
  });

  // 重命名主机
  el.btnRenameHost.addEventListener('click', () => {
    el.inputModalHostname.value = el.hostname.textContent.replace(/\s*\(未重命名\)/, '');
    el.modalRename.classList.remove('hidden');
  });
  el.btnModalCancel.addEventListener('click', () => el.modalRename.classList.add('hidden'));
  el.btnModalSave.addEventListener('click', async () => {
    const name = el.inputModalHostname.value.trim();
    if (!name) return;
    el.modalRename.classList.add('hidden');
    ksuToast(`正在修改主机名为: ${name}...`);
    await runControl('set_hostname', name);
    await refreshStatus();
    ksuToast('主机名已更新');
  });

  // 核心路由与 DNS 开关
  el.switchAcceptRoutes.addEventListener('change', async (e) => {
    const val = e.target.checked ? 1 : 0;
    await runControl('set_routes', val);
    ksuToast(`已${val ? '开启' : '关闭'}子网路由接收`);
  });

  el.switchAcceptDns.addEventListener('change', async (e) => {
    const val = e.target.checked ? 1 : 0;
    await runControl('set_dns', val);
    ksuToast(`已${val ? '开启' : '关闭'} Tailnet DNS 接收`);
  });

  // Exit Node 绑定与清除
  el.btnApplyExitNode.addEventListener('click', async () => {
    const selectVal = el.selectExitNode.value;
    const manualVal = el.inputManualExitNode.value.trim();
    const target = manualVal || selectVal;
    if (!target) {
      ksuToast('请选择或输入出口节点地址');
      return;
    }
    const allowLan = el.switchAllowLan.checked ? 1 : 0;
    ksuToast(`正在应用 Exit Node: ${target}...`);
    await runControl('set_exit_node', target, allowLan);
    await refreshStatus();
    ksuToast('Exit Node 设置已生效');
  });

  el.btnClearExitNode.addEventListener('click', async () => {
    ksuToast('正在停用并清除 Exit Node...');
    await runControl('set_exit_node', '', 0);
    el.inputManualExitNode.value = '';
    await refreshStatus();
    ksuToast('Exit Node 已清除');
  });

  // 自身广播 Exit Node
  el.switchAdvExitNode.addEventListener('change', async (e) => {
    const val = e.target.checked ? 1 : 0;
    ksuToast(val ? '正在广播本机作为 Exit Node...' : '正在取消 Exit Node 广播...');
    await runControl('adv_exit_node', val);
    await refreshStatus();
  });

  // 广播子网路由
  el.switchAdvRoutes.addEventListener('change', async (e) => {
    const val = e.target.checked;
    const cidr = el.inputSubnetCidr.value.trim();
    if (val && !cidr) {
      ksuToast('请输入要广播的子网 CIDR');
      e.target.checked = false;
      return;
    }
    await runControl('adv_routes', val ? cidr : '');
    ksuToast(val ? `已广播子网: ${cidr}` : '已停止广播子网路由');
    await refreshStatus();
  });

  el.btnBroadcastSubnet.addEventListener('click', async () => {
    const cidr = el.inputSubnetCidr.value.trim();
    if (!cidr) {
      ksuToast('请输入子网 CIDR (如 192.168.2.0/24)');
      return;
    }
    el.switchAdvRoutes.checked = true;
    ksuToast(`正在广播子网: ${cidr}...`);
    await runControl('adv_routes', cidr);
    await refreshStatus();
  });

  // 自动探测 Wi-Fi 子网
  autoDetectSubnet();

  // 检查更新
  el.btnCheckUpdate.addEventListener('click', async () => {
    ksuToast('正在检查 Tailscale 核心更新...');
    const raw = await runControl('check_update');
    try {
      const data = JSON.parse(raw);
      if (data.latest) {
        el.valLatestVer.textContent = `v${data.latest}`;
        if (data.latest === data.current) {
          ksuToast('当前核心已是最新版本！');
        } else {
          ksuToast(`发现新版本 v${data.latest}！`);
        }
      }
    } catch (e) {
      el.valLatestVer.textContent = '检测失败';
    }
  });

  // 清空与复制日志
  el.btnClearLogs.addEventListener('click', async () => {
    await runControl('clear_logs');
    if (el.logView) el.logView.textContent = '';
    ksuToast('已清除当前全部日志');
  });

  el.btnCopyLogs.addEventListener('click', () => {
    if (el.logView) {
      copyToClipboard(el.logView.textContent);
      ksuToast('已复制当前全部日志到剪切板');
    }
  });

  el.btnRefreshPeers.addEventListener('click', () => {
    refreshStatus();
    ksuToast('节点列表已刷新');
  });
}

async function autoDetectSubnet() {
  try {
    const raw = await runControl('detect_subnet');
    const data = JSON.parse(raw);
    if (data.subnet && (!el.inputSubnetCidr.value || el.inputSubnetCidr.value === '192.168.2.0/24')) {
      el.inputSubnetCidr.value = data.subnet;
    }
  } catch (e) {}
}

// 7. 工具函数
function copyToClipboard(text) {
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text);
  } else {
    const ta = document.createElement('textarea');
    ta.value = text;
    document.body.appendChild(ta);
    ta.select();
    document.execCommand('copy');
    document.body.removeChild(ta);
  }
}

function escapeHtml(str) {
  if (!str) return '';
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}

// 8. 浏览器调试环境的 Mock 实现
let mockIsRunning = true;
let mockIsLoggedIn = false;
let mockHostname = 'localhost';
let mockAcceptRoutes = false;
let mockAcceptDns = false;
let mockExitNode = '';
let mockAllowLan = true;
let mockAdvExitNode = false;
let mockAdvRoutes = false;
let mockSubnet = '192.168.2.0/24';
let mockProxy = '';
let mockServer = '';

function handleMockExec(cmd, resolve) {
  console.log('[Browser Mock ksuExec]:', cmd);

  if (cmd.includes('status')) {
    const peers = mockIsLoggedIn ? {
      "node-nas": {
        HostName: "nas-home",
        OS: "linux",
        TailscaleIPs: ["100.86.10.2", "fd7a:115c:a1e0::2"],
        Online: true,
        ExitNodeOption: false
      },
      "node-vps": {
        HostName: "us-vps-gateway",
        OS: "linux",
        TailscaleIPs: ["100.86.10.88", "fd7a:115c:a1e0::88"],
        Online: true,
        ExitNodeOption: true
      },
      "node-mac": {
        HostName: "macbook-work",
        OS: "macOS",
        TailscaleIPs: ["100.86.10.3", "fd7a:115c:a1e0::3"],
        Online: true,
        ExitNodeOption: false
      },
      "node-pc": {
        HostName: "win11-pc",
        OS: "windows",
        TailscaleIPs: ["100.86.10.4", "fd7a:115c:a1e0::4"],
        Online: false,
        ExitNodeOption: false
      }
    } : {};

    resolve({
      code: 0,
      stdout: JSON.stringify({
        running: mockIsRunning,
        pids: mockIsRunning ? '14477 14512' : '',
        tun_name: 'tailscale0',
        tun_ip: (mockIsRunning && mockIsLoggedIn) ? '100.86.10.25' : '',
        data_dir: '/data/adb/modules/tailscale_native/data',
        proxy: mockProxy,
        login_server: mockServer,
        status_json: {
          BackendState: !mockIsRunning ? 'Stopped' : (mockIsLoggedIn ? 'Running' : 'NeedsLogin'),
          AuthURL: mockIsLoggedIn ? '' : 'https://login.tailscale.com/a/mock12345678',
          Self: {
            HostName: mockHostname,
            DNSName: `${mockHostname}.tailnet.ts.net.`,
            TailscaleIPs: (mockIsRunning && mockIsLoggedIn) ? ['100.86.10.25', 'fd7a:115c:a1e0::25'] : [],
            AcceptRoutes: mockAcceptRoutes,
            AcceptDNS: mockAcceptDns
          },
          Peer: peers
        }
      }),
      stderr: ''
    });
  } else if (cmd.includes('login_key')) {
    mockIsLoggedIn = true;
    mockHostname = 'android-phone';
    resolve({ code: 0, stdout: '{"success": true}', stderr: '' });
  } else if (cmd.includes('logout')) {
    mockIsLoggedIn = false;
    mockHostname = 'localhost';
    resolve({ code: 0, stdout: '{"success": true}', stderr: '' });
  } else if (cmd.includes('start')) {
    mockIsRunning = true;
    resolve({ code: 0, stdout: '{"success": true}', stderr: '' });
  } else if (cmd.includes('stop')) {
    mockIsRunning = false;
    resolve({ code: 0, stdout: '{"success": true}', stderr: '' });
  } else if (cmd.includes('restart')) {
    mockIsRunning = true;
    resolve({ code: 0, stdout: '{"success": true}', stderr: '' });
  } else if (cmd.includes('set_hostname')) {
    const match = cmd.match(/set_hostname "([^"]+)"/);
    if (match) mockHostname = match[1];
    resolve({ code: 0, stdout: '{"success": true}', stderr: '' });
  } else if (cmd.includes('set_proxy')) {
    const match = cmd.match(/set_proxy "([^"]*)"/);
    if (match) mockProxy = match[1];
    resolve({ code: 0, stdout: '{"success": true}', stderr: '' });
  } else if (cmd.includes('set_server')) {
    const match = cmd.match(/set_server "([^"]*)"/);
    if (match) mockServer = match[1];
    resolve({ code: 0, stdout: '{"success": true}', stderr: '' });
  } else if (cmd.includes('set_routes')) {
    mockAcceptRoutes = cmd.includes('1');
    resolve({ code: 0, stdout: '{"success": true}', stderr: '' });
  } else if (cmd.includes('set_dns')) {
    mockAcceptDns = cmd.includes('1');
    resolve({ code: 0, stdout: '{"success": true}', stderr: '' });
  } else if (cmd.includes('get_logs')) {
    resolve({
      code: 0,
      stdout: `controlplane.tailscale.com: error: Get "https://controlplane.tailscale.com/bootstrap-dns":
q=controlplane.tailscale.com" error: dial tcp [2001:67c0:e::011]:443: connect: network is unreachable
2026/09/13 18:13:22 [RATELIMIT] format("control: trying bootstrapDNS(%30, %s) for %q ...")
2026/09/13 18:13:23 control: bootstrapDNS("derp1f.tailscale.com", "185.40.234.219") for "controlplane.tailscale.com"
2026/09/13 18:13:23 [RATELIMIT] format("control: trying bootstrapDNS(%30, %s) for %q ...")
2026/09/13 18:13:23 [RATELIMIT] format("control: bootstrapDNS(%q, %q) for %q error: %v")
2026/09/13 18:13:24 Received error: fetch control key: Get "https://controlplane.tailscale.com/key?v=142": failed to resolve "controlplane.tailscale.com": no DNS fallback candidates remain
2026/09/13 18:13:24 logtail: [POST] /logslapi/v0/debug`,
      stderr: ''
    });
  } else if (cmd.includes('detect_subnet')) {
    resolve({ code: 0, stdout: '{"subnet": "192.168.2.0/24"}', stderr: '' });
  } else if (cmd.includes('ping_peer')) {
    const isOffline = cmd.includes('win11') || cmd.includes('100.86.10.4');
    const isRelay = cmd.includes('vps') || cmd.includes('100.86.10.88');
    const lat = isRelay ? (Math.floor(Math.random() * 40) + 140) : (Math.floor(Math.random() * 15) + 6);
    setTimeout(() => {
      if (isOffline) {
        resolve({
          code: 0,
          stdout: JSON.stringify({
            success: false,
            latency: "超时",
            type: "离线不可达",
            error: "节点离线无响应"
          }),
          stderr: ''
        });
      } else {
        resolve({
          code: 0,
          stdout: JSON.stringify({
            success: true,
            latency: `${lat}ms`,
            type: isRelay ? '中继 (DERP-tokyo)' : '直连 (P2P)',
            raw: 'pong'
          }),
          stderr: ''
        });
      }
    }, 400);
    return;
  } else if (cmd.includes('check_update')) {
    resolve({ code: 0, stdout: '{"current": "1.102.4", "latest": "1.102.4"}', stderr: '' });
  } else {
    resolve({ code: 0, stdout: '{"success": true}', stderr: '' });
  }
}

// 9. 页面加载与轮询启动
window.addEventListener('DOMContentLoaded', () => {
  bindEvents();
  refreshStatus();
  refreshLogs();

  // 轮询状态与日志
  pollTimer = setInterval(refreshStatus, 4000);
  logTimer = setInterval(refreshLogs, 3500);
});

