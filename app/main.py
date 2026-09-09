"""
Day 5 실습용 최소 FastAPI 앱.

목적은 애플리케이션 로직이 아니라 "내가 만든 이미지가 ECR을 거쳐 EKS에서 도는가"입니다.
그래서 응답에 파드/노드/IP 정보를 실어 보내, 스케줄링과 네트워킹을 눈으로 확인합니다.
"""

import os
import socket
from datetime import datetime, timezone

from fastapi import FastAPI

app = FastAPI(title="deepagent-app")

# 빌드 시 주입. Dockerfile의 ARG VERSION → ENV APP_VERSION
VERSION = os.getenv("APP_VERSION", "dev")


@app.get("/")
def root():
    return {
        "message": "hello from EKS",
        "version": VERSION,
        # 파드 이름 (컨테이너 호스트명 = 파드 이름)
        "pod": socket.gethostname(),
        # 아래 둘은 Deployment의 downward API로 주입받습니다.
        # 파드가 스스로 알 수 없는 정보라 쿠버네티스가 알려줘야 합니다.
        "node": os.getenv("NODE_NAME", "unknown"),
        "podIP": os.getenv("POD_IP", "unknown"),
        # 노드 아키텍처. Graviton 전환이 실제로 반영됐는지 확인용.
        "arch": os.uname().machine,
        "time": datetime.now(timezone.utc).isoformat(),
    }


@app.get("/healthz")
def healthz():
    """쿠버네티스 liveness/readiness probe 용. 가볍고 의존성이 없어야 합니다."""
    return {"status": "ok"}
