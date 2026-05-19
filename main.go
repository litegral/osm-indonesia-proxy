package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

var (
	rdb       *redis.Client
	targetURL *url.URL
	ctx       = context.Background()
)

func main() {
	redisAddr := getEnv("REDIS_ADDR", "localhost:6379")
	tileServerAddr := getEnv("TILE_SERVER_URL", "http://localhost:8080")
	listenAddr := getEnv("LISTEN_ADDR", ":3000")

	rdb = redis.NewClient(&redis.Options{
		Addr: redisAddr,
	})

	if err := rdb.Ping(ctx).Err(); err != nil {
		log.Fatalf("cannot connect to redis: %v", err)
	}

	var err error
	targetURL, err = url.Parse(tileServerAddr)
	if err != nil {
		log.Fatalf("invalid tile server URL: %v", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", authMiddleware(proxyHandler()))

	log.Printf("tile auth proxy listening on %s -> %s", listenAddr, tileServerAddr)
	if err := http.ListenAndServe(listenAddr, mux); err != nil {
		log.Fatal(err)
	}
}

func authMiddleware(next http.Handler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		key := r.Header.Get("X-Api-Key")
		if key == "" {
			key = r.URL.Query().Get("key")
		}

		if key == "" {
			http.Error(w, "missing api key", http.StatusUnauthorized)
			return
		}

		clientName, err := rdb.Get(ctx, "tile:key:"+key).Result()
		if err == redis.Nil {
			http.Error(w, "invalid api key", http.StatusForbidden)
			return
		} else if err != nil {
			log.Printf("redis error: %v", err)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}

		// origin whitelisting:
		// flutter mobile apps don't send Origin or Referer, so if both are absent
		// we skip the check (native app assumed).
		// browser-based clients (Laravel) will always send Origin, so we validate those.
		origin := r.Header.Get("Origin")
		referer := r.Header.Get("Referer")
		originAllowed, err := checkOrigin(key, origin, referer)
		if err != nil {
		    log.Printf("origin check error: %v", err)
		    http.Error(w, "internal error", http.StatusInternalServerError)
		    return
		}
		if !originAllowed {
		    log.Printf("origin rejected for key %s: origin=%s referer=%s", key, origin, referer)
		    http.Error(w, "origin not allowed", http.StatusForbidden)
		    return
		}

		allowed, err := checkRateLimit(key)
		if err != nil {
			log.Printf("rate limit check error: %v", err)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		if !allowed {
			w.Header().Set("Retry-After", "60")
			http.Error(w, "rate limit exceeded", http.StatusTooManyRequests)
			return
		}

		go logUsage(key, clientName, r)

		next.ServeHTTP(w, r)
	}
}

// checkOrigin validates the request Origin or Referer against the allowed domain stored in redis.
// stored as: tile:origin:<key> -> "yourdomain.com" (just the domain, no scheme)
// if no origin is set for the key, all origins are allowed (flutter key behavior).
// if origin is set, requests with no Origin/Referer are rejected -- prevents direct browser access.
func checkOrigin(key, origin, referer string) (bool, error) {
	allowedDomain, err := rdb.Get(ctx, "tile:origin:"+key).Result()
	if err == redis.Nil {
		// no origin restriction set for this key, allow all (flutter key)
		return true, nil
	} else if err != nil {
		return false, err
	}

	// origin restriction is set -- strictly require it.
	// no Origin/Referer = not from allowed domain = reject.
	if origin == "" && referer == "" {
		return false, nil
	}

	if origin != "" {
		return strings.Contains(origin, allowedDomain), nil
	}

	return strings.Contains(referer, allowedDomain), nil
}

func checkRateLimit(key string) (bool, error) {
	limit := int64(1000)
	limitStr, err := rdb.Get(ctx, "tile:limit:"+key).Result()
	if err == nil {
		var parsed int64
		if _, err := fmt.Sscanf(limitStr, "%d", &parsed); err == nil {
			limit = parsed
		}
	}

	bucket := time.Now().Format("2006-01-02T15:04")
	counterKey := "tile:rate:" + key + ":" + bucket

	pipe := rdb.Pipeline()
	incr := pipe.Incr(ctx, counterKey)
	pipe.Expire(ctx, counterKey, 2*time.Minute)
	if _, err := pipe.Exec(ctx); err != nil {
		return false, err
	}

	return incr.Val() <= limit, nil
}

func proxyHandler() http.Handler {
	proxy := httputil.NewSingleHostReverseProxy(targetURL)
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		log.Printf("proxy error: %v", err)
		http.Error(w, "tile server unavailable", http.StatusBadGateway)
	}
	return proxy
}

func logUsage(key, clientName string, r *http.Request) {
	pipe := rdb.Pipeline()
	day := time.Now().Format("2006-01-02")

	pipe.Incr(ctx, "tile:usage:"+key+":total")
	pipe.Incr(ctx, "tile:usage:"+key+":day:"+day)
	pipe.Set(ctx, "tile:usage:"+key+":last_seen", time.Now().Unix(), 0)
	pipe.Set(ctx, "tile:usage:"+key+":client", clientName, 0)

	if _, err := pipe.Exec(ctx); err != nil {
		log.Printf("failed to log usage for %s (%s): %v", clientName, key, err)
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
