package ssrf

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"slices"
	"time"
)

type TransportOptions struct {
	AllowLoopback                bool
	DialTimeout                  time.Duration
	TLSHandshakeTimeout          time.Duration
	ResponseHeaderTimeout        time.Duration
	DisableResponseHeaderTimeout bool
	IdleConnTimeout              time.Duration
	// AllowedPrefixes admits otherwise-blocked destinations, such as a private
	// model gateway, after DNS resolution. Build it with ParseAllowedPrefixes;
	// reserved ranges such as link-local never match. The zero value admits
	// nothing beyond IsAllowedIP.
	AllowedPrefixes []netip.Prefix
}

func NewTransport(opts TransportOptions) *http.Transport {
	if opts.DialTimeout == 0 {
		opts.DialTimeout = 5 * time.Second
	}
	if opts.TLSHandshakeTimeout == 0 {
		opts.TLSHandshakeTimeout = 10 * time.Second
	}
	if opts.ResponseHeaderTimeout == 0 && !opts.DisableResponseHeaderTimeout {
		opts.ResponseHeaderTimeout = 30 * time.Second
	}
	if opts.IdleConnTimeout == 0 {
		opts.IdleConnTimeout = 90 * time.Second
	}
	dialer := &net.Dialer{Timeout: opts.DialTimeout, KeepAlive: 30 * time.Second}
	allowedPrefixes := slices.Clone(opts.AllowedPrefixes)
	return &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			return dial(ctx, dialer, network, addr, opts.AllowLoopback, allowedPrefixes)
		},
		TLSHandshakeTimeout:   opts.TLSHandshakeTimeout,
		ResponseHeaderTimeout: opts.ResponseHeaderTimeout,
		IdleConnTimeout:       opts.IdleConnTimeout,
		ForceAttemptHTTP2:     true,
		HTTP2: &http.HTTP2Config{
			SendPingTimeout: 15 * time.Second,
			PingTimeout:     5 * time.Second,
		},
	}
}

func Dial(ctx context.Context, dialer *net.Dialer, network, addr string, allowLoopback bool) (net.Conn, error) {
	return dial(ctx, dialer, network, addr, allowLoopback, nil)
}

// dial resolves addr, then dials the first address that IsAllowedIPWithPrefixes
// admits, pinned so a second lookup cannot rebind the connection.
func dial(
	ctx context.Context,
	dialer *net.Dialer,
	network, addr string,
	allowLoopback bool,
	allowedPrefixes []netip.Prefix,
) (net.Conn, error) {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return nil, err
	}
	if ip := net.ParseIP(host); ip != nil {
		if !IsAllowedIPWithPrefixes(ip, allowLoopback, allowedPrefixes) {
			return nil, fmt.Errorf("%w: %s", ErrBlockedAddress, ip)
		}
		return dialer.DialContext(ctx, network, net.JoinHostPort(ip.String(), port))
	}
	addrs, err := net.DefaultResolver.LookupIPAddr(ctx, host)
	if err != nil {
		return nil, err
	}
	for _, a := range addrs {
		if IsAllowedIPWithPrefixes(a.IP, allowLoopback, allowedPrefixes) {
			return dialer.DialContext(ctx, network, net.JoinHostPort(a.IP.String(), port))
		}
	}
	return nil, fmt.Errorf("%w: %s (no allowed IPs)", ErrBlockedAddress, host)
}
