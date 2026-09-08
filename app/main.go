// Day 5 실습용 최소 HTTP 서버.
// 외부 의존성이 없어 정적 바이너리로 빌드되고, scratch 이미지에 담으면 ~7MB가 됩니다.
// 파드가 어느 노드/AZ에 떴는지 응답에 실어 보내 스케줄링을 눈으로 확인합니다.
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"
)

var version = "dev" // 빌드 시 -ldflags 로 주입

func main() {
	mux := http.NewServeMux()

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		host, _ := os.Hostname()
		// NODE_NAME / POD_IP 는 Deployment에서 downward API로 주입합니다.
		resp := map[string]string{
			"message":  "hello from EKS",
			"version":  version,
			"pod":      host,
			"node":     os.Getenv("NODE_NAME"),
			"podIP":    os.Getenv("POD_IP"),
			"time":     time.Now().Format(time.RFC3339),
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(resp)
	})

	// 쿠버네티스 probe 용 엔드포인트
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "ok")
	})

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	log.Printf("listening on :%s (version=%s)", port, version)
	log.Fatal(http.ListenAndServe(":"+port, mux))
}
