# ============================================================================
# 멀티스테이지 빌드
#   1단계: venv에 의존성 설치 (pip 캐시·빌드 도구가 최종 이미지에 안 남도록 분리)
#   2단계: slim 베이스에 venv와 소스만 복사
#
# [아키텍처 메모]
# 노드를 Graviton(t4g, arm64)으로 맞췄기 때문에 맥북(Apple Silicon)과 동일합니다.
# 그래서 --platform 플래그 없이 그냥 빌드하면 됩니다.
#
# 만약 노드가 x86_64(t3 등)라면 반드시 아래처럼 빌드해야 합니다:
#   docker build --platform linux/amd64 ...
# 안 그러면 파드가 `exec format error`로 CrashLoopBackOff에 빠집니다.
# 이미지의 아키텍처는 빌드한 머신을 따라가기 때문입니다.
# ============================================================================

FROM python:3.13-slim AS build
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
WORKDIR /tmp/build
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

FROM python:3.13-slim
ARG VERSION=dev
ENV APP_VERSION=${VERSION} \
    PATH="/opt/venv/bin:$PATH" \
    # .pyc를 안 만들게 합니다. 차트에서 루트 파일시스템을 읽기 전용으로 두기 때문입니다.
    PYTHONDONTWRITEBYTECODE=1 \
    # 로그가 버퍼에 갇히지 않게 — kubectl logs로 바로 보이도록
    PYTHONUNBUFFERED=1

COPY --from=build /opt/venv /opt/venv
WORKDIR /app
COPY main.py .

# 비루트 실행 (65534 = nobody)
USER 65534:65534
EXPOSE 8080
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
