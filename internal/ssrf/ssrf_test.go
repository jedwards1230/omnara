package ssrf

import (
	"net"
	"net/netip"
	"strings"
	"testing"
)

func TestIsAllowedIPBlocksSpecialUseRanges(t *testing.T) {
	tests := []struct {
		name          string
		ip            string
		allowLoopback bool
		want          bool
	}{
		{name: "public ipv4", ip: "8.8.8.8", want: true},
		{name: "public ipv6", ip: "2001:4860:4860::8888", want: true},
		{name: "loopback ipv4 blocked", ip: "127.0.0.1"},
		{name: "loopback ipv4 allowed in dev", ip: "127.0.0.1", allowLoopback: true, want: true},
		{name: "loopback ipv6 blocked", ip: "::1"},
		{name: "loopback ipv6 allowed in dev", ip: "::1", allowLoopback: true, want: true},
		{name: "ipv4-compatible loopback blocked", ip: "::127.0.0.1"},
		{name: "ipv4-compatible loopback allowed in dev", ip: "::127.0.0.1", allowLoopback: true, want: true},
		{name: "unspecified ipv4", ip: "0.0.0.0"},
		{name: "unspecified ipv6", ip: "::"},
		{name: "private ipv4 10", ip: "10.0.0.1"},
		{name: "private ipv4 172", ip: "172.16.0.1"},
		{name: "private ipv4 192", ip: "192.168.1.1"},
		{name: "private ipv6 ula", ip: "fc00::1"},
		{name: "link local ipv4 metadata", ip: "169.254.169.254"},
		{name: "link local ipv6", ip: "fe80::1"},
		{name: "multicast ipv4", ip: "224.0.0.1"},
		{name: "multicast ipv6", ip: "ff02::1"},
		{name: "cgnat ipv4", ip: "100.64.0.1"},
		{name: "current network ipv4", ip: "0.1.2.3"},
		{name: "ipv4 protocol assignments", ip: "192.0.0.1"},
		{name: "deprecated 6to4 relay anycast", ip: "192.88.99.1"},
		{name: "benchmark ipv4", ip: "198.18.0.1"},
		{name: "test net 1", ip: "192.0.2.1"},
		{name: "test net 2", ip: "198.51.100.1"},
		{name: "test net 3", ip: "203.0.113.1"},
		{name: "reserved ipv4", ip: "240.0.0.1"},
		{name: "local nat64 ipv6", ip: "64:ff9b:1::1"},
		{name: "discard-only ipv6", ip: "100::1"},
		{name: "dummy ipv6", ip: "100:0:0:1::1"},
		{name: "unassigned ietf protocol ipv6", ip: "2001:5::1"},
		{name: "benchmark ipv6", ip: "2001:2::1"},
		{name: "deprecated orchid ipv6", ip: "2001:10::1"},
		{name: "amt ipv6", ip: "2001:3::1"},
		{name: "orchid v2 ipv6", ip: "2001:20::1"},
		{name: "deprecated site local ipv6", ip: "fec0::1"},
		{name: "documentation ipv6", ip: "2001:db8::1"},
		{name: "documentation ipv6 2024", ip: "3fff::1"},
		{name: "segment routing ipv6", ip: "5f00::1"},
		{name: "ipv4 mapped private", ip: "::ffff:10.0.0.1"},
		{name: "ipv4 mapped public", ip: "::ffff:8.8.8.8", want: true},
		{name: "ipv4-compatible metadata", ip: "::169.254.169.254"},
		{name: "ipv4-compatible public", ip: "::8.8.8.8", want: true},
		{name: "nat64 embedded metadata ipv4", ip: "64:ff9b::169.254.169.254"},
		{name: "nat64 embedded public ipv4", ip: "64:ff9b::8.8.8.8", want: true},
		{name: "6to4 embedded loopback ipv4", ip: "2002:7f00:1::"},
		{name: "6to4 embedded public ipv4", ip: "2002:0808:0808::", want: true},
		{name: "teredo embedded test-net client ipv4", ip: "2001:0000:4136:e378:8000:63bf:3fff:fdd2"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			ip := net.ParseIP(tc.ip)
			if ip == nil {
				t.Fatalf("parse %s", tc.ip)
			}
			if got := IsAllowedIP(ip, tc.allowLoopback); got != tc.want {
				t.Fatalf("IsAllowedIP(%s, %v) = %v, want %v", tc.ip, tc.allowLoopback, got, tc.want)
			}
		})
	}
	if IsAllowedIP(nil, false) {
		t.Fatal("invalid IP accepted")
	}
}

func TestParseAllowedPrefixes(t *testing.T) {
	tests := []struct {
		name    string
		cidrs   []string
		want    []string
		wantErr string
	}{
		{name: "empty", cidrs: nil},
		{name: "blank entries", cidrs: []string{"", "  "}},
		{name: "single ipv4", cidrs: []string{"10.0.0.5/32"}, want: []string{"10.0.0.5/32"}},
		{
			name:  "multiple with whitespace",
			cidrs: []string{" 10.0.0.0/24 ", "\t192.0.2.10/32", "172.16.0.0/12"},
			want:  []string{"10.0.0.0/24", "192.0.2.10/32", "172.16.0.0/12"},
		},
		{name: "host bits masked", cidrs: []string{"10.0.0.5/24"}, want: []string{"10.0.0.0/24"}},
		{name: "loopback", cidrs: []string{"127.0.0.1/32"}, want: []string{"127.0.0.1/32"}},
		{name: "ipv6 ula", cidrs: []string{"fd00:1234::/48"}, want: []string{"fd00:1234::/48"}},
		{name: "not a cidr", cidrs: []string{"not-a-cidr"}, wantErr: "invalid CIDR"},
		{name: "bare ip", cidrs: []string{"10.0.0.5"}, wantErr: "invalid CIDR"},
		{name: "bad length", cidrs: []string{"10.0.0.0/33"}, wantErr: "invalid CIDR"},
		{name: "ipv6 zone", cidrs: []string{"fe80::1%eth0/128"}, wantErr: "invalid CIDR"},
		{name: "one bad entry fails all", cidrs: []string{"10.0.0.5/32", "nope"}, wantErr: "invalid CIDR"},
		{name: "ipv4 any", cidrs: []string{"0.0.0.0/0"}, wantErr: "allows every address"},
		{name: "ipv6 any", cidrs: []string{"::/0"}, wantErr: "allows every address"},
		{name: "metadata", cidrs: []string{"169.254.169.254/32"}, wantErr: "169.254.0.0/16"},
		{name: "covers link-local", cidrs: []string{"128.0.0.0/1"}, wantErr: "169.254.0.0/16"},
		{name: "ipv6 link-local", cidrs: []string{"fe80::/64"}, wantErr: "fe80::/10"},
		{name: "ipv4 multicast", cidrs: []string{"239.1.2.3/32"}, wantErr: "224.0.0.0/4"},
		{name: "ipv6 multicast", cidrs: []string{"ff02::1/128"}, wantErr: "ff00::/8"},
		{name: "ipv4 unspecified", cidrs: []string{"0.0.0.0/8"}, wantErr: "0.0.0.0/32"},
		{name: "ipv6 unspecified", cidrs: []string{"::/128"}, wantErr: "::/128"},
		{name: "ipv4-mapped private", cidrs: []string{"::ffff:10.0.0.0/104"}, wantErr: "::ffff:0.0.0.0/96"},
		{name: "ipv4-mapped metadata", cidrs: []string{"::ffff:169.254.169.254/128"}, wantErr: "::ffff:0.0.0.0/96"},
		{name: "ipv4-compatible", cidrs: []string{"::a9fe:a9fe/128"}, wantErr: "::/96"},
		{name: "nat64 metadata", cidrs: []string{"64:ff9b::a9fe:a9fe/128"}, wantErr: "64:ff9b::/96"},
		{name: "6to4 metadata", cidrs: []string{"2002:a9fe:a9fe::/48"}, wantErr: "2002::/16"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := ParseAllowedPrefixes(tc.cidrs)
			if tc.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
					t.Fatalf("ParseAllowedPrefixes(%q) error = %v, want containing %q", tc.cidrs, err, tc.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("ParseAllowedPrefixes(%q): %v", tc.cidrs, err)
			}
			if len(got) != len(tc.want) {
				t.Fatalf("ParseAllowedPrefixes(%q) = %v, want %v", tc.cidrs, got, tc.want)
			}
			for i, prefix := range got {
				if prefix.String() != tc.want[i] {
					t.Fatalf("ParseAllowedPrefixes(%q)[%d] = %s, want %s", tc.cidrs, i, prefix, tc.want[i])
				}
			}
		})
	}
}

func TestIsAllowedIPWithPrefixes(t *testing.T) {
	allowed, err := ParseAllowedPrefixes([]string{"192.168.50.10/32", "10.0.0.0/24", "fd00:1234::/48"})
	if err != nil {
		t.Fatalf("parse allowed prefixes: %v", err)
	}
	// Bypasses ParseAllowedPrefixes to prove reserved ranges never match.
	unsafe := []netip.Prefix{
		netip.MustParsePrefix("0.0.0.0/0"),
		netip.MustParsePrefix("::/0"),
	}
	tests := []struct {
		name    string
		ip      string
		allowed []netip.Prefix
		want    bool
	}{
		{name: "listed private ipv4", ip: "192.168.50.10", allowed: allowed, want: true},
		{name: "listed private ipv4 mapped", ip: "::ffff:192.168.50.10", allowed: allowed, want: true},
		{name: "listed range", ip: "10.0.0.200", allowed: allowed, want: true},
		{name: "listed ipv6 ula", ip: "fd00:1234::1", allowed: allowed, want: true},
		{name: "public still allowed", ip: "8.8.8.8", allowed: allowed, want: true},
		{name: "neighbor of listed host", ip: "192.168.50.11", allowed: allowed},
		{name: "outside listed range", ip: "10.0.1.1", allowed: allowed},
		{name: "cluster service ip", ip: "10.43.0.1", allowed: allowed},
		{name: "other rfc1918", ip: "172.16.0.1", allowed: allowed},
		{name: "cgnat", ip: "100.64.0.1", allowed: allowed},
		{name: "metadata", ip: "169.254.169.254", allowed: allowed},
		{name: "loopback unlisted", ip: "127.0.0.1", allowed: allowed},
		{name: "unlisted ula", ip: "fd00:5678::1", allowed: allowed},
		{name: "no prefixes", ip: "192.168.50.10"},
		{name: "unsafe list private", ip: "10.43.0.1", allowed: unsafe, want: true},
		{name: "unsafe list metadata", ip: "169.254.169.254", allowed: unsafe},
		{name: "unsafe list mapped metadata", ip: "::ffff:169.254.169.254", allowed: unsafe},
		{name: "unsafe list ipv6 link-local", ip: "fe80::1", allowed: unsafe},
		{name: "unsafe list multicast", ip: "224.0.0.1", allowed: unsafe},
		{name: "unsafe list ipv6 multicast", ip: "ff02::1", allowed: unsafe},
		{name: "unsafe list unspecified", ip: "0.0.0.0", allowed: unsafe},
		{name: "unsafe list ipv6 unspecified", ip: "::", allowed: unsafe},
		{name: "unsafe list nat64 metadata", ip: "64:ff9b::169.254.169.254", allowed: unsafe},
		{name: "unsafe list 6to4 private", ip: "2002:0a00:0001::", allowed: unsafe},
		{name: "unsafe list ipv4-compatible private", ip: "::10.0.0.1", allowed: unsafe},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			ip := net.ParseIP(tc.ip)
			if ip == nil {
				t.Fatalf("parse %s", tc.ip)
			}
			if got := IsAllowedIPWithPrefixes(ip, false, tc.allowed); got != tc.want {
				t.Fatalf("IsAllowedIPWithPrefixes(%s, %v) = %v, want %v", tc.ip, tc.allowed, got, tc.want)
			}
		})
	}
	if IsAllowedIPWithPrefixes(nil, false, unsafe) {
		t.Fatal("invalid IP accepted")
	}
}
