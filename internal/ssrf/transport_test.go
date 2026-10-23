package ssrf

import (
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"sync/atomic"
	"testing"
)

func TestTransportAllowlistReachesListedLoopbackWithoutAllowLoopback(t *testing.T) {
	var calls atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	serverURL, err := url.Parse(server.URL)
	if err != nil {
		t.Fatalf("parse server URL: %v", err)
	}
	// ParseAllowedPrefixes rejects loopback; build the prefix directly so the
	// test can dial a local server without AllowLoopback.
	allowed := []netip.Prefix{netip.MustParsePrefix("127.0.0.1/32")}
	listed := &http.Client{Transport: NewTransport(TransportOptions{AllowedPrefixes: allowed})}
	unlisted := &http.Client{Transport: NewTransport(TransportOptions{})}
	targets := map[string]string{
		"literal":  server.URL,
		"hostname": "http://" + net.JoinHostPort("localhost", serverURL.Port()),
	}
	for name, target := range targets {
		t.Run(name, func(t *testing.T) {
			if err := get(t, unlisted, target); !errors.Is(err, ErrBlockedAddress) {
				t.Fatalf("unlisted GET %s error = %v, want ErrBlockedAddress", target, err)
			}
			before := calls.Load()
			if err := get(t, listed, target); err != nil {
				t.Fatalf("allowlisted GET %s: %v", target, err)
			}
			if calls.Load() != before+1 {
				t.Fatalf("server calls = %d, want %d", calls.Load(), before+1)
			}
		})
	}
}

func TestTransportAllowlistStillBlocksUnlistedAddresses(t *testing.T) {
	allowed := []netip.Prefix{netip.MustParsePrefix("10.0.0.5/32"), netip.MustParsePrefix("127.0.0.1/32")}
	transport := NewTransport(TransportOptions{AllowedPrefixes: allowed})
	for _, addr := range []string{
		"10.43.0.1:443",
		"10.0.0.6:443",
		"169.254.169.254:80",
		"[::ffff:169.254.169.254]:80",
		"[fe80::1]:80",
		"192.168.1.1:443",
		"172.16.0.1:443",
		"100.64.0.1:443",
		"[::1]:443",
		"0.0.0.0:443",
		"224.0.0.1:443",
	} {
		t.Run(addr, func(t *testing.T) {
			conn, err := transport.DialContext(t.Context(), "tcp", addr)
			if err == nil {
				_ = conn.Close()
			}
			if !errors.Is(err, ErrBlockedAddress) {
				t.Fatalf("dial %s error = %v, want ErrBlockedAddress", addr, err)
			}
		})
	}
}

func get(t *testing.T, client *http.Client, target string) error {
	t.Helper()
	req, err := http.NewRequestWithContext(t.Context(), http.MethodGet, target, nil)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("GET %s status = %d, want %d", target, resp.StatusCode, http.StatusNoContent)
	}
	return nil
}
