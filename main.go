package main

import (
	"fmt"
	"net/http"
	"os"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var requestsTotal = prometheus.NewCounterVec(
	prometheus.CounterOpts{
		Name: "http_requests_total",
		Help: "Total HTTP requests received, by path and status",
	},
	[]string{"path", "status"},
)

func init() {
	prometheus.MustRegister(requestsTotal)
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	http.HandleFunc("/api/v1/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"status": "healthy", "message": "Systems functional"}`)
		requestsTotal.WithLabelValues("/api/v1/health", "200").Inc()
	})

	http.Handle("/metrics", promhttp.Handler())

	fmt.Printf("Backend listening on port %s...\n", port)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		fmt.Println("Server failed:", err)
	}
}
