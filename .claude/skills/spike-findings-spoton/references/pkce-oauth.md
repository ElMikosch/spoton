# PKCE OAuth Flow

## Requirements

- PKCE (S256) is the only auth flow (no Implicit Grant, no Client Credentials)
- Token refresh must work in pure Perl (no binary spawn)
- Refresh Token Rotation is active — persist new refresh_token ATOMICALLY after every refresh
- All Browse/Library/Player endpoints must work with PKCE tokens

## How to Build It

### 1. PKCE Code Verifier + Challenge

```perl
use Digest::SHA qw(sha256);
use MIME::Base64 qw(encode_base64url);
use Crypt::OpenSSL::Random;

my $verifier_bytes = Crypt::OpenSSL::Random::random_bytes(64);
my $code_verifier  = encode_base64url($verifier_bytes);
$code_verifier =~ s/=+$//;

my $code_challenge = encode_base64url(sha256($code_verifier));
$code_challenge =~ s/=+$//;
```

### 2. Authorization URL

```perl
my $auth_uri = URI->new('https://accounts.spotify.com/authorize');
$auth_uri->query_param(client_id     => $CLIENT_ID);
$auth_uri->query_param(response_type => 'code');
$auth_uri->query_param(redirect_uri  => $REDIRECT_URI);
$auth_uri->query_param(scope         => join(' ', @SCOPES));
$auth_uri->query_param(code_challenge_method => 'S256');
$auth_uri->query_param(code_challenge => $code_challenge);
```

### 3. Required Scopes (13)

```perl
my @SCOPES = qw(
    streaming
    user-read-recently-played  user-top-read
    user-library-read          user-library-modify
    user-follow-read
    user-read-playback-state   user-modify-playback-state
    user-read-currently-playing
    user-read-playback-position
    playlist-read-private
    playlist-modify-public     playlist-modify-private
);
```

The `streaming` scope is CRITICAL — without it, credential derivation (Spike 004) fails.

### 4. Callback Server (HTTP::Daemon on port 8989)

```perl
my $daemon = HTTP::Daemon->new(
    LocalAddr => '127.0.0.1',
    LocalPort => 8989,
    ReuseAddr => 1,
);
# Wait for GET /callback?code=... request
```

Redirect URI `http://127.0.0.1:8989/callback` must be registered in the Spotify Developer App.

### 5. Token Exchange (Authorization Code → Tokens)

```perl
my $resp = $ua->post('https://accounts.spotify.com/api/token', [
    grant_type    => 'authorization_code',
    code          => $auth_code,
    redirect_uri  => $REDIRECT_URI,
    client_id     => $CLIENT_ID,
    code_verifier => $code_verifier,
]);
# Returns: { access_token, refresh_token, expires_in, scope, token_type }
```

No client_secret needed — PKCE replaces it with the code_verifier proof.

### 6. Token Refresh (Pure Perl, No Binary)

```perl
my $resp = $ua->post('https://accounts.spotify.com/api/token', [
    grant_type    => 'refresh_token',
    refresh_token => $REFRESH_TOKEN,
    client_id     => $CLIENT_ID,
]);
# Returns: { access_token, refresh_token (NEW!), expires_in, scope }
```

### 7. Atomic Token Persistence

Refresh Token Rotation means every refresh returns a NEW refresh_token. The old one is invalidated. Use write-then-rename to avoid partial writes:

```perl
# Write to temp file first
my $tmp = "$token_file.tmp.$$";
open my $fh, '>', $tmp or die;
print $fh encode_json($token_data);
close $fh;
chmod 0600, $tmp;
rename $tmp, $token_file or die;
```

If a refresh succeeds but persistence fails, the user must re-authenticate via the browser flow.

## What to Avoid

- **Don't use Implicit Grant** — deprecated by Spotify, no refresh_token
- **Don't assume refresh_token stability** — Spotify rotates it on every refresh
- **Don't cache scopes from initial auth** — refresh grants additional scopes (~20 vs 13 requested)
- **Don't hardcode token expiry** — use `expires_in` from the response (currently 3600s but may change)
- **Don't use client_secret** — PKCE flow doesn't need it; if you send it, it may fail

## Constraints

- Redirect URI must be pre-registered in the Spotify Developer App
- Dev Mode: `product` field removed from /me response
- Dev Mode: editorial playlists may return 404 (browse/featured-playlists removed)
- Dev Mode: search max limit=10 per type
- Access token TTL: 3600s (1 hour)
- Spike used `http://127.0.0.1:8989/callback` — only works when browser runs on the LMS host
- **Production design:** GitHub Pages static relay at `https://stiefenm.github.io/spoton/auth/`. LMS encodes its local callback URL + nonce in the OAuth `state` parameter. Static page validates private-IP target, then `window.location.href` redirects to `http://<lms>:9000/plugins/SpotOn/callback?code=...`. Copy-paste fallback if redirect fails. See ROADMAP.md v3.0 section.

## Origin

Synthesized from spikes: 001, 002, 003
Source files available in: sources/001-pkce-auth-flow/, sources/002-pkce-browse-endpoints/, sources/003-pkce-token-refresh/
