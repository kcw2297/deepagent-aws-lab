# ============================================================================
# 멀티스테이지 빌드
#   1단계: Go 컴파일 (빌드 도구가 최종 이미지에 남지 않도록 분리)
#   2단계: scratch(빈 이미지)에 바이너리만 복사 → 최종 ~7MB
#
# ⚠️ 아키텍처 주의
#   맥북(Apple Silicon)은 arm64, 워커 노드(t3.medium)는 x86_64입니다.
#   그냥 빌드하면 파드가 `exec format error`로 죽습니다.
#   반드시 --platform linux/amd64 로 빌드하세요.
#   (TARGETARCH는 buildx가 --platform 값에 따라 자동으로 채워줍니다)
# ============================================================================

FROM --platform=$BUILDPLATFORM golang:1.23-alpine AS build
ARG TARGETOS
ARG TARGETARCH
ARG VERSION=dev
WORKDIR /src
COPY go.mod ./
COPY main.go ./
# CGO_ENABLED=0 → 정적 링크. scratch에는 libc가 없으므로 필수입니다.
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -ldflags="-s -w -X main.version=${VERSION}" -o /out/app .

FROM scratch
COPY --from=build /out/app /app
EXPOSE 8080
USER 65534:65534
ENTRYPOINT ["/app"]
