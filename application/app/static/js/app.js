const state = {
  step: 0,
  cluster: null,
  selection: { loki: false, loki_alerting: false, users: false, developer_view: false, acm: false, gpu: false },
  resourceEstimate: null,
  jobId: null,
};

const panels = document.querySelectorAll(".panel");
const stepDots = document.querySelectorAll(".step-dot");

function goToStep(n) {
  state.step = n;
  panels.forEach((p, i) => p.classList.toggle("active", i === n));
  stepDots.forEach((d, i) => {
    d.classList.toggle("active", i === n);
    d.classList.toggle("done", i < n);
  });
  if (n === 2) syncDeveloperViewHints();
}

async function api(path, options = {}) {
  const res = await fetch(path, {
    headers: { "Content-Type": "application/json", ...options.headers },
    ...options,
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.detail || res.statusText);
  return data;
}

function getSelection() {
  const sel = {
    loki: false,
    loki_alerting: false,
    users: false,
    developer_view: false,
    acm: false,
    gpu: false,
  };
  document.querySelectorAll('input[name="component"]:checked').forEach((el) => {
    sel[el.value] = true;
  });
  const alertingEl = document.querySelector('input[name="loki_alerting"]');
  sel.loki_alerting = !!(alertingEl?.checked && sel.loki);

  const devUsers = document.querySelector('input[name="developer_view_users"]');
  const devLoki = document.querySelector('input[name="developer_view_loki"]');
  sel.developer_view =
    (sel.users && devUsers?.checked) || (sel.loki_alerting && devLoki?.checked);

  state.selection = sel;
  return sel;
}

function ocpMinorVersion(version) {
  const m = /^4\.(\d+)/.exec(version || "");
  return m ? parseInt(m[1], 10) : null;
}

function developerViewIgnoreMessage(version) {
  const display = version || "your cluster";
  return `Nice try, but I'm ignoring that. 💅 ${display} already has it—I'm not just a pretty interface you know! 😎`;
}

function syncDeveloperViewHints() {
  const ver = state.cluster?.openshift_version;
  const minor = ocpMinorVersion(ver);
  const showIgnore = minor !== null && minor < 19;

  const pairs = [
    ["developer_view_users", "developer-view-users-msg"],
    ["developer_view_loki", "developer-view-loki-msg"],
  ];

  for (const [inputName, msgId] of pairs) {
    const input = document.querySelector(`input[name="${inputName}"]`);
    const msgEl = document.getElementById(msgId);
    if (!input || !msgEl) continue;
    if (input.checked && showIgnore) {
      msgEl.textContent = developerViewIgnoreMessage(ver);
      msgEl.classList.remove("hidden");
    } else {
      msgEl.textContent = "";
      msgEl.classList.add("hidden");
    }
  }
}

function syncLokiAlertingOption() {
  const lokiOn = document.querySelector('input[value="loki"]')?.checked;
  const lokiCard = document.querySelector('.checkbox-card[data-key="loki"]');
  lokiCard?.classList.toggle("selected", !!lokiOn);

  const alerting = document.querySelector('input[name="loki_alerting"]');
  const alertingWrap = document.getElementById("loki-alerting-option");
  const alertingGroup = document.getElementById("loki-alerting-group");
  const devLoki = document.querySelector('input[name="developer_view_loki"]');
  const devLokiWrap = document.getElementById("developer-view-loki-option");

  if (alerting) {
    alerting.disabled = !lokiOn;
    if (!lokiOn) alerting.checked = false;
  }
  alertingWrap?.classList.toggle("disabled", !lokiOn);
  alertingGroup?.classList.toggle("disabled", !lokiOn);

  const alertingOn = !!(lokiOn && alerting?.checked);
  const devLokiEnabled = alertingOn;
  if (devLoki) {
    devLoki.disabled = !devLokiEnabled;
    if (!devLokiEnabled) devLoki.checked = false;
  }
  devLokiWrap?.classList.toggle("disabled", !devLokiEnabled);
  syncDeveloperViewHints();
}

function syncUsersOptions() {
  const usersOn = document.querySelector('input[value="users"]')?.checked;
  const devUsers = document.querySelector('input[name="developer_view_users"]');
  const devWrap = document.getElementById("developer-view-users-option");
  const usersCard = document.querySelector('.checkbox-card[data-key="users"]');

  if (devUsers) {
    devUsers.disabled = !usersOn;
    if (!usersOn) devUsers.checked = false;
  }
  devWrap?.classList.toggle("disabled", !usersOn);
  usersCard?.classList.toggle("selected", !!usersOn);
  syncDeveloperViewHints();
}

document.querySelectorAll(".checkbox-card").forEach((card) => {
  const input = card.querySelector('input[name="component"]');
  if (!input) return;
  const sync = () => {
    if (card.dataset.key !== "users") {
      card.classList.toggle("selected", input.checked);
    }
    syncLokiAlertingOption();
    syncUsersOptions();
  };
  input.addEventListener("change", sync);
  sync();
});

const lokiAlertingInput = document.querySelector('input[name="loki_alerting"]');
if (lokiAlertingInput) {
  lokiAlertingInput.addEventListener("change", () => {
    syncLokiAlertingOption();
    getSelection();
  });
}

document.querySelectorAll('input[name="developer_view_users"], input[name="developer_view_loki"]').forEach((el) => {
  el.addEventListener("change", () => {
    getSelection();
    syncDeveloperViewHints();
  });
});

syncLokiAlertingOption();
syncUsersOptions();

// Prerequisites
function prereqBadge(c) {
  if (c.ok) return { cls: "ok", label: "OK" };
  if (c.required) return { cls: "fail", label: "Missing" };
  return { cls: "warn", label: "Not ready" };
}

function renderValidation(validation, failedOnly) {
  if (!validation) return "";
  const errs = validation.errors || [];
  const warns = validation.warnings || [];
  if (failedOnly && errs.length === 0) return "";

  let html = "";
  if (errs.length) {
    html += `<div class="alert error"><strong>Cannot continue until these are fixed:</strong><ul class="validation-list">${errs
      .map((e) => `<li>${e}</li>`)
      .join("")}</ul></div>`;
  } else if (!failedOnly && validation.ok) {
    html += `<div class="alert success">Session checks passed — cloud and tools look good for this cluster.</div>`;
  }
  if (!failedOnly && warns.length) {
    html += `<div class="alert warning"><ul class="validation-list">${warns
      .map((w) => `<li>${w}</li>`)
      .join("")}</ul></div>`;
  }
  return html;
}

async function loadPrereqs() {
  const list = document.getElementById("prereq-list");
  const btn = document.getElementById("btn-to-connect");
  list.innerHTML = '<p class="desc"><span class="spinner"></span> Scanning…</p>';
  try {
    const data = await api("/api/prereqs");
    list.innerHTML = data.checks
      .map((c) => {
        const b = prereqBadge(c);
        return `
      <div class="check-item">
        <div>
          <div class="name">${c.name}</div>
          <div class="detail">${c.detail}</div>
        </div>
        <span class="badge ${b.cls}">${b.label}</span>
      </div>`;
      })
      .join("");

    const summaryClass = data.ready
      ? data.cloud_ok
        ? "success"
        : "warning"
      : "error";
    list.insertAdjacentHTML(
      "beforeend",
      `<div class="alert ${summaryClass}" style="margin-top:0.75rem">${data.summary}</div>
       <p class="desc" style="margin-top:0.5rem">Detected OS: <strong>${data.platform}</strong></p>`
    );
    btn.disabled = !data.ready;
  } catch (e) {
    list.innerHTML = `<div class="alert error">${e.message}</div>`;
    btn.disabled = true;
  }
}

document.getElementById("btn-recheck").addEventListener("click", loadPrereqs);
document.getElementById("btn-to-connect").addEventListener("click", () => goToStep(1));

// Login
document.getElementById("btn-login").addEventListener("click", async () => {
  const errEl = document.getElementById("login-error");
  const infoEl = document.getElementById("cluster-info");
  const valEl = document.getElementById("session-validation");
  const btnComponents = document.getElementById("btn-to-components");
  errEl.classList.add("hidden");
  infoEl.classList.add("hidden");
  valEl.classList.add("hidden");
  valEl.innerHTML = "";
  btnComponents.classList.add("hidden");

  const kerberos = document.getElementById("kerberos").value.trim();
  const apiUrl = document.getElementById("api-url").value.trim();
  const username = document.getElementById("username").value.trim();
  const password = document.getElementById("password").value;

  if (!kerberos || !apiUrl || !username || !password) {
    errEl.textContent = "Kerberos, API URL, username and password are required.";
    errEl.classList.remove("hidden");
    return;
  }

  const btn = document.getElementById("btn-login");
  btn.disabled = true;
  btn.innerHTML = '<span class="spinner"></span> Connecting…';

  try {
    const data = await api("/api/cluster/login", {
      method: "POST",
      body: JSON.stringify({ api_url: apiUrl, kerberos, username, password }),
    });
    state.cluster = data.cluster;
    state.kerberos = data.kerberos || data.cluster?.kerberos;
    renderClusterStats(data.cluster);
    infoEl.classList.remove("hidden");
    syncDeveloperViewHints();

    if (data.validation && !data.validation.ok) {
      valEl.innerHTML = renderValidation(data.validation, true);
      valEl.classList.remove("hidden");
      btnComponents.classList.add("hidden");
    } else {
      if (data.validation) {
        valEl.innerHTML = renderValidation(data.validation, false);
        valEl.classList.remove("hidden");
      }
      btnComponents.classList.remove("hidden");
    }
  } catch (e) {
    errEl.textContent = e.message;
    errEl.classList.remove("hidden");
  } finally {
    btn.disabled = false;
    btn.textContent = "Connect";
  }
});

function renderClusterStats(c) {
  const el = document.getElementById("cluster-stats");
  el.innerHTML = `
    <div class="stat"><div class="value">${c.user || "—"}</div><div class="label">Logged in as</div></div>
    <div class="stat"><div class="value">${c.kerberos || c.bucket_user || "—"}</div><div class="label">Kerberos (S3 key)</div></div>
    <div class="stat"><div class="value">${c.platform || "—"}</div><div class="label">Platform</div></div>
    <div class="stat"><div class="value">${c.region || "—"}</div><div class="label">Region</div></div>
    <div class="stat"><div class="value">${c.worker_count}</div><div class="label">Workers</div></div>
    <div class="stat"><div class="value">${c.total_cpu}</div><div class="label">CPU cores</div></div>
    <div class="stat"><div class="value">${c.total_memory_gi}</div><div class="label">Memory (Gi)</div></div>
  `;
}

document.getElementById("btn-to-components").addEventListener("click", () => goToStep(2));

// Components → Resources
document.getElementById("btn-to-resources").addEventListener("click", async () => {
  const sel = getSelection();
  if (!Object.values(sel).some(Boolean)) {
    alert("Select at least one component.");
    return;
  }
  if (document.querySelector('input[name="loki_alerting"]')?.checked && !sel.loki) {
    alert("Per-user Loki log alerting requires Loki logging to be selected.");
    return;
  }
  goToStep(3);
  await loadResourceEstimate();
});

async function loadResourceEstimate() {
  const content = document.getElementById("resource-content");
  const scaleSection = document.getElementById("scale-section");
  const btnDeploy = document.getElementById("btn-to-deploy");
  scaleSection.classList.add("hidden");
  btnDeploy.classList.add("hidden");
  content.innerHTML = '<p class="desc"><span class="spinner"></span> Calculating…</p>';

  try {
    const data = await api("/api/resources/estimate", {
      method: "POST",
      body: JSON.stringify(state.selection),
    });
    state.resourceEstimate = data;

    const cpuPct = data.required.cpu_cores
      ? Math.min(100, (data.required.cpu_cores / data.available.cpu_cores) * 100)
      : 0;
    const memPct = data.required.memory_gi
      ? Math.min(100, (data.required.memory_gi / data.available.memory_gi) * 100)
      : 0;

    let warnings = (data.warnings || [])
      .map((w) => `<div class="alert warning">${w}</div>`)
      .join("");

    let components = (data.components || [])
      .map(
        (c) =>
          `<li>${c.label} — ${c.cpu_cores} CPU, ${c.memory_gi} Gi RAM${
            c.extra_nodes ? ` (+${c.extra_nodes} new GPU nodes)` : ""
          }</li>`
      )
      .join("");

    content.innerHTML = `
      ${warnings}
      <div class="resource-bar">
        <div class="resource-row"><span>CPU required / available</span><span>${data.required.cpu_cores} / ${data.available.cpu_cores} cores</span></div>
        <div class="bar-track"><div class="bar-fill cpu" style="width:${cpuPct}%"></div></div>
        <div class="resource-row"><span>Memory required / available</span><span>${data.required.memory_gi} / ${data.available.memory_gi} Gi</span></div>
        <div class="bar-track"><div class="bar-fill mem" style="width:${memPct}%"></div></div>
      </div>
      <p class="desc" style="margin-top:0.75rem">${data.scale_assumption || ""}</p>
      <ul style="margin:0.5rem 0 0 1.2rem;font-size:0.9rem;color:var(--text-muted)">${components}</ul>
      ${
        data.sufficient
          ? '<div class="alert success">Cluster has enough worker resources for the selected components.</div>'
          : `<div class="alert warning">Insufficient resources. Recommend adding <strong>${data.recommended_extra_workers}</strong> worker node(s).</div>`
      }
      ${
        !data.sufficient && data.worker_machineset
          ? `<div class="alert warning">${data.scale_method || ""} Target MachineSet: <code>${data.worker_machineset}</code></div>`
          : !data.sufficient
            ? `<div class="alert warning">${data.scale_method || ""}</div>`
            : ""
      }
      ${
        data.gpu_extra_nodes
          ? `<div class="alert warning">GPU option will provision <strong>${data.gpu_extra_nodes}</strong> additional g4dn.xlarge EC2 instances (separate from worker scaling).</div>`
          : ""
      }
    `;

    if (!data.sufficient) {
      scaleSection.classList.remove("hidden");
      document.getElementById("scale-message").innerHTML =
        `Add <strong>${data.recommended_extra_workers}</strong> worker node(s) now, or continue anyway (deployment may fail or be slow).`;
    } else {
      btnDeploy.classList.remove("hidden");
    }
  } catch (e) {
    content.innerHTML = `<div class="alert error">${e.message}</div>`;
  }
}

document.getElementById("btn-scale").addEventListener("click", async () => {
  const extra = state.resourceEstimate?.recommended_extra_workers || 1;
  const btn = document.getElementById("btn-scale");
  btn.disabled = true;
  btn.textContent = "Scaling…";
  try {
    const result = await api("/api/workers/scale", {
      method: "POST",
      body: JSON.stringify({ extra_workers: extra }),
    });
    document.getElementById("scale-message").innerHTML =
      `<div class="alert success">${result.message}</div>`;
    document.getElementById("btn-to-deploy").classList.remove("hidden");
  } catch (e) {
    document.getElementById("scale-message").innerHTML = `<div class="alert error">${e.message}</div>`;
  } finally {
    btn.disabled = false;
    btn.textContent = "Add worker nodes";
  }
});

document.getElementById("btn-skip-scale").addEventListener("click", () => {
  document.getElementById("btn-to-deploy").classList.remove("hidden");
});

document.getElementById("btn-to-deploy").addEventListener("click", () => {
  goToStep(4);
  startDeployment();
});

// Deploy
function isErrorLine(line) {
  const l = line.toLowerCase();
  return (
    line.includes("ERROR") ||
    line.includes("❌") ||
    line.includes("FATAL") ||
    line.includes("Failed") ||
    line.includes("exit code") ||
    l.includes("error:") ||
    l.includes("failed at step")
  );
}

function showDeployErrors(lines, jobError) {
  const panel = document.getElementById("deploy-error-panel");
  const body = document.getElementById("deploy-error-body");
  const errors = [...lines];
  if (jobError && !errors.includes(jobError)) {
    errors.unshift(jobError);
  }
  if (errors.length === 0) return;
  body.textContent = errors.join("\n");
  panel.classList.remove("hidden");
}

function hideDeployErrors() {
  document.getElementById("deploy-error-panel").classList.add("hidden");
  document.getElementById("deploy-error-body").textContent = "";
}

async function startDeployment() {
  const logBox = document.getElementById("log-box");
  const statusText = document.getElementById("deploy-status-text");
  logBox.textContent = "";
  hideDeployErrors();
  document.getElementById("btn-back-deploy").disabled = true;
  document.getElementById("btn-finish").classList.add("hidden");

  statusText.textContent = "Running preflight checks…";

  try {
    const preflight = await api("/api/deploy/preflight", {
      method: "POST",
      body: JSON.stringify(state.selection),
    });

    if (!preflight.ok) {
      statusText.textContent = "Preflight failed — fix issues and try again";
      const lines = (preflight.errors || []).map((e) => `ERROR: ${e}`);
      showDeployErrors(lines, "Deployment blocked by preflight checks.");
      logBox.textContent = lines.join("\n");
      document.getElementById("btn-back-deploy").disabled = false;
      return;
    }

    if (preflight.warnings?.length) {
      preflight.warnings.forEach((w) => {
        const span = document.createElement("div");
        span.className = "line-warn";
        span.textContent = `⚠️  ${w}`;
        logBox.appendChild(span);
      });
    }

    statusText.textContent = "Starting deployment…";
    const { job_id } = await api("/api/deploy", {
      method: "POST",
      body: JSON.stringify(state.selection),
    });
    state.jobId = job_id;
    streamLogs(job_id);
  } catch (e) {
    statusText.textContent = "Failed to start";
    showDeployErrors([e.message], null);
    logBox.textContent = e.message;
    document.getElementById("btn-back-deploy").disabled = false;
  }
}

function streamLogs(jobId) {
  const logBox = document.getElementById("log-box");
  const statusText = document.getElementById("deploy-status-text");
  const errorLines = [];
  let offset = 0;

  const es = new EventSource(`/api/deploy/${jobId}/stream?offset=${offset}`);

  es.onmessage = (event) => {
    const data = JSON.parse(event.data);
    if (data.type === "error") {
      showDeployErrors([data.message], null);
      logBox.textContent += data.message + "\n";
      es.close();
      return;
    }

    offset = data.offset;
    (data.lines || []).forEach((line) => {
      const span = document.createElement("div");
      span.textContent = line;
      if (isErrorLine(line)) {
        span.className = "line-error";
        errorLines.push(line);
      } else if (line.includes("✅") || line.includes("DONE")) {
        span.className = "line-ok";
      }
      logBox.appendChild(span);
    });
    logBox.scrollTop = logBox.scrollHeight;

    const step = data.current_step
      ? `Running: ${data.current_step} (${data.steps_completed}/${data.steps_total})`
      : data.status === "completed"
        ? "All steps completed"
        : data.status === "failed"
          ? "Deployment failed"
          : "Deploying…";
    statusText.textContent = step;

    if (data.status === "completed" || data.status === "failed") {
      es.close();
      document.getElementById("btn-back-deploy").disabled = false;
      if (data.status === "failed") {
        showDeployErrors(errorLines, data.error);
      }
      if (data.status === "completed") {
        document.getElementById("btn-finish").classList.remove("hidden");
      }
    }
  };

  es.onerror = () => es.close();
}

document.getElementById("btn-finish").addEventListener("click", () => goToStep(0));

// Back buttons
document.querySelectorAll("[data-back]").forEach((btn) => {
  btn.addEventListener("click", () => goToStep(Number(btn.dataset.back)));
});

// Init
loadPrereqs();
