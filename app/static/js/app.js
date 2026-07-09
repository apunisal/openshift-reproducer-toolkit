const state = {
  step: 0,
  cluster: null,
  selection: { loki: false, users: false, acm: false, gpu: false },
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
  const sel = { loki: false, users: false, acm: false, gpu: false };
  document.querySelectorAll('input[name="component"]:checked').forEach((el) => {
    sel[el.value] = true;
  });
  state.selection = sel;
  return sel;
}

// Checkbox card styling + users summary toggle when Loki is selected
function syncUsersSummary() {
  const lokiOn = document.querySelector('input[value="loki"]')?.checked;
  const basic = document.getElementById("users-summary-basic");
  const loki = document.getElementById("users-summary-loki");
  if (basic && loki) {
    basic.classList.toggle("hidden", !!lokiOn);
    loki.classList.toggle("hidden", !lokiOn);
  }
}

document.querySelectorAll(".checkbox-card").forEach((card) => {
  const input = card.querySelector("input");
  const sync = () => {
    card.classList.toggle("selected", input.checked);
    syncUsersSummary();
  };
  input.addEventListener("change", sync);
  sync();
});

// Prerequisites
async function loadPrereqs() {
  const list = document.getElementById("prereq-list");
  const btn = document.getElementById("btn-to-connect");
  list.innerHTML = '<p class="desc"><span class="spinner"></span> Scanning…</p>';
  try {
    const data = await api("/api/prereqs");
    list.innerHTML = data.checks
      .map(
        (c) => `
      <div class="check-item">
        <div>
          <div class="name">${c.name}</div>
          <div class="detail">${c.detail}</div>
        </div>
        <span class="badge ${c.ok ? "ok" : c.required ? "fail" : "optional"}">
          ${c.ok ? "OK" : c.required ? "Missing" : "Optional"}
        </span>
      </div>`
      )
      .join("");
    list.insertAdjacentHTML(
      "beforeend",
      `<p class="desc" style="margin-top:0.75rem">Detected OS: <strong>${data.platform}</strong></p>`
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
  errEl.classList.add("hidden");
  infoEl.classList.add("hidden");

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
    document.getElementById("btn-to-components").classList.remove("hidden");
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
      <ul style="margin:0.5rem 0 0 1.2rem;font-size:0.9rem;color:var(--text-muted)">${components}</ul>
      ${
        data.sufficient
          ? '<div class="alert success">Cluster has enough worker resources for the selected components.</div>'
          : `<div class="alert warning">Insufficient resources. Recommend adding <strong>${data.recommended_extra_workers}</strong> worker node(s) (m5.2xlarge equivalent).</div>`
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

  try {
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
