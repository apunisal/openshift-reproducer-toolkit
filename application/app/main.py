import json

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from app.config import HOST, PORT, ROOT_DIR
from app.services import cluster, prereqs, resources, runner
from app.services.preflight import run_preflight
from app.services.session_validate import validate_session

app = FastAPI(title="OCP Reproducer Toolkit", version="0.1.0")

static_dir = ROOT_DIR / "app" / "static"
app.mount("/static", StaticFiles(directory=str(static_dir)), name="static")


class LoginRequest(BaseModel):
    api_url: str
    kerberos: str
    username: str = "kubeadmin"
    password: str


class SelectionRequest(BaseModel):
    loki: bool = False
    loki_alerting: bool = False
    users: bool = False
    developer_view: bool = False
    acm: bool = False
    gpu: bool = False


class ScaleRequest(BaseModel):
    extra_workers: int = Field(ge=1, le=10)


@app.get("/")
async def index():
    return FileResponse(static_dir / "index.html")


@app.get("/api/health")
async def health():
    index = static_dir / "index.html"
    if not index.is_file():
        raise HTTPException(
            status_code=503,
            detail=f"Wizard UI not found at {index}. Run ./start.sh from the application/ folder.",
        )
    return {"ok": True, "host": HOST, "port": PORT}


@app.get("/api/prereqs")
async def get_prereqs():
    return prereqs.check_prerequisites()


@app.post("/api/cluster/login")
async def cluster_login(body: LoginRequest):
    result = cluster.login(body.api_url, body.username, body.password, body.kerberos)
    if not result["ok"]:
        raise HTTPException(status_code=400, detail=result["error"])
    info = cluster.get_cluster_info()
    validation = validate_session(info)
    return {
        "ok": True,
        "cluster": cluster.cluster_info_to_dict(info),
        "kerberos": cluster.sanitize_kerberos(body.kerberos),
        "validation": validation,
    }


@app.get("/api/cluster/info")
async def cluster_info():
    info = cluster.get_cluster_info()
    return cluster.cluster_info_to_dict(info)


@app.post("/api/resources/estimate")
async def estimate(body: SelectionRequest):
    info = cluster.get_cluster_info()
    if not info.connected:
        raise HTTPException(status_code=400, detail=info.error or "Not connected")
    return resources.estimate_resources(info, body.model_dump())


@app.post("/api/workers/scale")
async def scale_workers(body: ScaleRequest):
    result = runner.scale_workers(body.extra_workers)
    if not result["ok"]:
        raise HTTPException(status_code=400, detail=result["error"])
    return result


@app.post("/api/deploy/preflight")
async def deploy_preflight(body: SelectionRequest):
    info = cluster.get_cluster_info()
    if not info.connected:
        raise HTTPException(status_code=400, detail="Connect to a cluster first")
    return run_preflight(body.model_dump(), info.platform)


@app.post("/api/deploy")
async def deploy(body: SelectionRequest):
    info = cluster.get_cluster_info()
    if not info.connected:
        raise HTTPException(status_code=400, detail="Connect to a cluster first")

    selected = body.model_dump()
    if not any(selected.values()):
        raise HTTPException(status_code=400, detail="Select at least one component")

    if selected.get("loki_alerting") and not selected.get("loki"):
        raise HTTPException(
            status_code=400,
            detail="Per-user Loki log alerting requires the Loki logging stack to be selected.",
        )

    if selected.get("gpu") and info.platform != "AWS":
        raise HTTPException(
            status_code=400,
            detail="GPU nodes option is only supported on AWS clusters.",
        )

    try:
        job_id = runner.start_deployment(selected)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    return {"job_id": job_id}


@app.get("/api/deploy/{job_id}")
async def deploy_status(job_id: str):
    job = runner.get_job(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="Job not found")
    return {
        "id": job.id,
        "status": job.status,
        "current_step": job.current_step,
        "steps_completed": job.steps_completed,
        "steps_total": job.steps_total,
        "error": job.error,
        "log_count": len(job.logs),
    }


@app.get("/api/deploy/{job_id}/stream")
async def deploy_stream(job_id: str, offset: int = 0):
    def event_stream():
        for payload in runner.stream_logs(job_id, offset):
            yield f"data: {json.dumps(payload)}\n\n"

    return StreamingResponse(event_stream(), media_type="text/event-stream")


def main():
    import uvicorn

    uvicorn.run("app.main:app", host=HOST, port=PORT, reload=False)


if __name__ == "__main__":
    main()
