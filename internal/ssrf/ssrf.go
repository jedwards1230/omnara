package ssrf

import (
	"errors"
	"fmt"
	"net"
	"net/netip"
	"strings"
)

var ErrBlockedAddress = errors.New("ssrf: address blocked")

func IsAllowedIP(ip net.IP, allowLoopback bool) bool {
	if v4 := ip.To4(); v4 != nil {
		ip = v4
	} else if ip.To16() == nil {
		return false
	}
	if ip.IsLoopback() {
		return allowLoopback
	}
	if !ip.IsGlobalUnicast() || ip.IsPrivate() {
		return false
	}
	if !embeddedIPv4Allowed(ip, allowLoopback) {
		return false
	}
	for _, prefix := range blockedPrefixes {
		if cidrContains(prefix, ip) {
			return false
		}
	}
	return true
}

// IsAllowedIPWithPrefixes reports whether ip passes IsAllowedIP or falls
// inside one of the operator-allowed prefixes. Addresses in
// reservedAllowlistPrefixes (link-local, multicast, unspecified, and IPv6 forms
// that embed IPv4) never match, even when allowed was not built by
// ParseAllowedPrefixes. IPv4-mapped IPv6 addresses match IPv4 prefixes.
func IsAllowedIPWithPrefixes(ip net.IP, allowLoopback bool, allowed []netip.Prefix) bool {
	if IsAllowedIP(ip, allowLoopback) {
		return true
	}
	address, ok := netip.AddrFromSlice(ip)
	if !ok {
		return false
	}
	address = address.Unmap()
	for _, reserved := range reservedAllowlistPrefixes {
		if reserved.Contains(address) {
			return false
		}
	}
	for _, prefix := range allowed {
		if prefix.Contains(address) {
			return true
		}
	}
	return false
}

// ParseAllowedPrefixes parses operator-supplied CIDRs for
// TransportOptions.AllowedPrefixes. Blank entries are skipped. A prefix that
// covers every address, or overlaps any of reservedAllowlistPrefixes, is
// rejected: IPv4 destinations must be listed in plain IPv4 form.
func ParseAllowedPrefixes(cidrs []string) ([]netip.Prefix, error) {
	var prefixes []netip.Prefix
	for _, cidr := range cidrs {
		cidr = strings.TrimSpace(cidr)
		if cidr == "" {
			continue
		}
		prefix, err := netip.ParsePrefix(cidr)
		if err != nil {
			return nil, fmt.Errorf("invalid CIDR: %w", err)
		}
		prefix = prefix.Masked()
		if prefix.Bits() == 0 {
			return nil, fmt.Errorf("CIDR %q allows every address", cidr)
		}
		for _, reserved := range reservedAllowlistPrefixes {
			if prefix.Overlaps(reserved) {
				return nil, fmt.Errorf("CIDR %q overlaps reserved range %s", cidr, reserved)
			}
		}
		prefixes = append(prefixes, prefix)
	}
	return prefixes, nil
}

// reservedAllowlistPrefixes can never be opened by an operator allowlist:
// unspecified, link-local (including cloud metadata), and multicast ranges,
// plus the IPv6 forms that embed an IPv4 address and could otherwise smuggle a
// link-local IPv4 destination past the IPv4 checks.
var reservedAllowlistPrefixes = []netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/32"),
	netip.MustParsePrefix("169.254.0.0/16"),
	netip.MustParsePrefix("224.0.0.0/4"),
	netip.MustParsePrefix("::/128"),
	netip.MustParsePrefix("fe80::/10"),
	netip.MustParsePrefix("ff00::/8"),
	netip.MustParsePrefix("::ffff:0:0/96"),
	ipv4CompatibleIPv6,
	nat64WellKnownIPv6,
	sixToFourIPv6,
}

// blockedPrefixes supplements net.IP's broad classifications with a
// conservative snapshot of special-purpose ranges that untrusted outbound
// requests must not reach. Keep it synchronized with the IANA registries:
// https://www.iana.org/assignments/iana-ipv4-special-registry/
// https://www.iana.org/assignments/iana-ipv6-special-registry/
var blockedPrefixes = []netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/8"),
	netip.MustParsePrefix("100.64.0.0/10"),
	netip.MustParsePrefix("192.0.0.0/24"),
	netip.MustParsePrefix("192.0.2.0/24"),
	netip.MustParsePrefix("192.88.99.0/24"),
	netip.MustParsePrefix("198.18.0.0/15"),
	netip.MustParsePrefix("198.51.100.0/24"),
	netip.MustParsePrefix("203.0.113.0/24"),
	netip.MustParsePrefix("240.0.0.0/4"),
	netip.MustParsePrefix("64:ff9b:1::/48"),
	netip.MustParsePrefix("100::/64"),
	netip.MustParsePrefix("100:0:0:1::/64"),
	netip.MustParsePrefix("2001::/23"),
	netip.MustParsePrefix("2001:db8::/32"),
	netip.MustParsePrefix("3fff::/20"),
	netip.MustParsePrefix("5f00::/16"),
	netip.MustParsePrefix("fec0::/10"),
}

var (
	ipv4CompatibleIPv6 = netip.MustParsePrefix("::/96")
	nat64WellKnownIPv6 = netip.MustParsePrefix("64:ff9b::/96")
	sixToFourIPv6      = netip.MustParsePrefix("2002::/16")
)

func embeddedIPv4Allowed(ip net.IP, allowLoopback bool) bool {
	if ip.To4() != nil {
		return true
	}
	ip = ip.To16()
	if ip == nil {
		return false
	}
	for _, embedded := range embeddedIPv4Addresses(ip) {
		if !IsAllowedIP(embedded, allowLoopback) {
			return false
		}
	}
	return true
}

func embeddedIPv4Addresses(ip net.IP) []net.IP {
	switch {
	case cidrContains(ipv4CompatibleIPv6, ip):
		return []net.IP{net.IPv4(ip[12], ip[13], ip[14], ip[15])}
	case cidrContains(nat64WellKnownIPv6, ip):
		return []net.IP{net.IPv4(ip[12], ip[13], ip[14], ip[15])}
	case cidrContains(sixToFourIPv6, ip):
		return []net.IP{net.IPv4(ip[2], ip[3], ip[4], ip[5])}
	default:
		return nil
	}
}

func cidrContains(prefix netip.Prefix, ip net.IP) bool {
	address, ok := netip.AddrFromSlice(ip)
	return ok && prefix.Contains(address)
}
