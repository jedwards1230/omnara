package httpapi

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"slices"
	"testing"

	"github.com/omnara-ai/omnara/internal/agentconfig"
	"github.com/omnara-ai/omnara/internal/ssrf"
)

func TestValidateModelProviderBaseURLNetworkPolicyHonorsOutboundAllowlist(t *testing.T) {
	allowed := []netip.Prefix{netip.MustParsePrefix("10.0.0.5/32")}
	for _, tc := range []struct {
		name    string
		baseURL string
		allowed []netip.Prefix
		wantErr bool
	}{
		{name: "listed private ip", baseURL: "https://10.0.0.5/v1", allowed: allowed},
		{name: "private ip without allowlist", baseURL: "https://10.0.0.5/v1", wantErr: true},
		{name: "unlisted private ip", baseURL: "https://10.0.0.6/v1", allowed: allowed, wantErr: true},
		{name: "metadata", baseURL: "http://169.254.169.254/v1", allowed: allowed, wantErr: true},
		{name: "hostname checked at dial time", baseURL: "https://models.example.com/v1", allowed: allowed},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := validateModelProviderBaseURLNetworkPolicy(tc.baseURL, false, tc.allowed)
			if (err != nil) != tc.wantErr {
				t.Fatalf("validate %s error = %v, wantErr %v", tc.baseURL, err, tc.wantErr)
			}
		})
	}
}

func TestNewWiresOutboundAllowedPrefixesIntoMCP(t *testing.T) {
	allowed := []netip.Prefix{netip.MustParsePrefix("127.0.0.1/32")}
	destination := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer destination.Close()

	// The allowlist must survive a later WithAgentConfigOptions, which cmd/api
	// only passes in insecure dev mode.
	server := mustNewUnitServer(t,
		WithOutboundAllowedPrefixes(allowed),
		WithAgentConfigOptions(agentconfig.CompileOptions{}),
	)
	if !slices.Equal(server.agentConfigOptions.OutboundAllowedPrefixes, allowed) {
		t.Fatalf("agent config prefixes = %v, want %v", server.agentConfigOptions.OutboundAllowedPrefixes, allowed)
	}
	if err := mcpOAuthGet(t, server, destination.URL); err != nil {
		t.Fatalf("allowlisted MCP OAuth request: %v", err)
	}
	if err := mcpOAuthGet(t, mustNewUnitServer(t), destination.URL); !errors.Is(err, ssrf.ErrBlockedAddress) {
		t.Fatalf("MCP OAuth without allowlist error = %v, want ssrf.ErrBlockedAddress", err)
	}
}

func mcpOAuthGet(t *testing.T, server *Server, target string) error {
	t.Helper()
	req, err := http.NewRequestWithContext(t.Context(), http.MethodGet, target, nil)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	resp, err := server.mcpOAuthHTTPClient.Do(req)
	if err != nil {
		return err
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("MCP OAuth status = %d, want %d", resp.StatusCode, http.StatusNoContent)
	}
	return nil
}
