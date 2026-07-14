package Plugins::SpotOn::API::WebPlayer;

# Web-Player token lifecycle (D-06) -- fully independent from PKCE
# (TokenManager.pm) and Keymaster. Owns sp_dc storage, TOTP generation,
# the open.spotify.com/api/token mint, clienttoken.spotify.com acquisition,
# caching, in-flight coalescing, masking, and the multi-channel degradation
# state (D-03/D-04/D-05) consumed by Plugin.pm (OPML), Settings.pm, and
# Status.pm. TokenManager MUST NOT learn about Web-Player tokens (D-07).

use strict;
use warnings;

use JSON::XS::VersionOneAndTwo;
use Digest::SHA qw(hmac_sha1);
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

my $log   = logger('plugin.spoton');
my $prefs = preferences('plugin.spoton');
# Same shared cache instance/namespace as TokenManager.pm/PKCE.pm/Client.pm
# (cache version lives in Plugin.pm, single source of truth). Distinct key
# prefix spoton_wp_* keeps Web-Player entries out of PKCE's spoton_token_*
# namespace.
my $cache = Slim::Utils::Cache->new('spoton', Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION());

# ============================================================
# TOTP (RFC 6238-derived, no base32 module -- RESEARCH Pitfall 1)
# ============================================================

# _totp($secret_bytes, $epoch)
# $secret_bytes: arrayref of ints 0..255 (validated SecretSource cipher).
# The reference algorithm base32-encodes the transformed decimal string
# then a TOTP library immediately base32-decodes it right back -- the two
# operations cancel, so the HMAC key is exactly the ASCII decimal
# concatenation of the transformed bytes. No CPAN base32/OATH module is
# needed (none is bundled with LMS -- CLAUDE.md forbids external deps).
sub _totp {
    my ($secret_bytes, $epoch) = @_;
    my @t = map { $secret_bytes->[$_] ^ (($_ % 33) + 9) } 0 .. $#$secret_bytes;
    my $key     = join('', @t);
    my $counter = int($epoch / 30);
    my $msg     = pack('N2', 0, $counter);
    my $hash    = hmac_sha1($msg, $key);
    my $off     = ord(substr($hash, -1)) & 0x0f;
    my $bin     = unpack('N', substr($hash, $off, 4)) & 0x7fffffff;
    return sprintf('%06d', $bin % 1_000_000);
}

# _mask($value)
# T-52-02/T-52-07: masked preview for log lines -- never log a full sp_dc,
# accountId, or token value. Copied verbatim from TokenManager.pm::_mask.
sub _mask {
    my ($value) = @_;
    return 'unknown' unless defined $value && length $value;
    return substr($value, 0, 4) . '****';
}

# ============================================================
# Plugins::SpotOn::API::WebPlayer::SecretSource (D-01 pluggable secret source)
# ============================================================
# Thin, config-selectable indirection over the TOTP secret feed. Today only
# the xyloflake/spot-secrets-go community JSON is implemented; the shape
# (getSecret($cb)) is designed so a future self-hosted source (deferred per
# CONTEXT.md) can be swapped in without touching TOTP or token code.
package Plugins::SpotOn::API::WebPlayer::SecretSource;

use strict;
use warnings;

use JSON::XS::VersionOneAndTwo;
use Slim::Networking::SimpleAsyncHTTP;

use constant SECRET_URL => 'https://raw.githubusercontent.com/xyloflake/spot-secrets-go/refs/heads/main/secrets/secretDict.json';
use constant CACHE_KEY      => 'spoton_wp_secret';
use constant CACHE_TTL      => 6 * 3600;   # a few hours -- avoid per-mint refetch (RESEARCH Pattern 3)
use constant MAX_CIPHER_LEN => 64;         # bound untrusted array length (T-52-01)

# NOTE: $log and $cache are the SAME lexicals declared in the enclosing
# Plugins::SpotOn::API::WebPlayer package above -- a bare `package NAME;`
# statement (no block) does not open a new lexical scope in Perl, so they
# remain visible here. Re-declaring them with `my` would only shadow the
# originals and trigger a "masks earlier declaration" warning; reusing
# them keeps this package on the single shared cache/log instance.

# getSecret($class, $cb, $opts)
# cb->({ version => $int, cipher => [ints 0..255] }) on success.
# cb->(undef, 'unreachable') on ANY anomaly -- non-JSON, wrong shape,
# out-of-range values, unreachable host. NEVER dies, NEVER evals the
# fetched payload, NEVER treats the bytes as anything but TOTP input
# (T-52-01). $opts->{forceRefresh} bypasses the cache (Pitfall 2 retry).
sub getSecret {
    my ($class, $cb, $opts) = @_;
    $opts ||= {};

    unless ($opts->{forceRefresh}) {
        if (my $cached = $cache->get(CACHE_KEY)) {
            $cb->($cached);
            return;
        }
    }

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http   = shift;
            my $result = $class->_parseAndValidate($http->content);
            unless ($result) {
                $log->warn('WebPlayer::SecretSource: xyloflake payload failed strict validation (T-52-01/D-05)');
                $cb->(undef, 'unreachable');
                return;
            }
            $cache->set(CACHE_KEY, $result, CACHE_TTL);
            $cb->($result);
        },
        sub {
            my ($http, $error) = @_;
            $log->warn("WebPlayer::SecretSource: fetch failed: $error (D-05)");
            $cb->(undef, 'unreachable');
        },
        { timeout => 30 }
    )->get(SECRET_URL());
}

# _parseAndValidate($class, $jsonStr)
# Pure function -- exposed for direct unit testing without live HTTP
# (Perl has no true sub privacy; the leading underscore is a naming
# convention only). Strictly validates untrusted xyloflake JSON (T-52-01):
# must decode to a hashref with at least one key; EVERY candidate key must
# be a positive integer and EVERY candidate value must be an arrayref of
# integers in 0..255 within MAX_CIPHER_LEN -- a single anomaly anywhere in
# the payload rejects the WHOLE payload (fail-closed) rather than silently
# falling back to a lower/different version. Selects the highest valid
# numeric version. Never eval's the payload, never dies.
sub _parseAndValidate {
    my ($class, $jsonStr) = @_;
    return undef unless defined $jsonStr && length $jsonStr;

    my $decoded = eval { from_json($jsonStr) };
    return undef if $@ || !$decoded || ref($decoded) ne 'HASH';
    return undef unless %$decoded;

    my $bestVersion;
    my $bestCipher;

    for my $key (sort keys %$decoded) {
        return undef unless $key =~ /^\d+$/;
        my $version = $key + 0;
        return undef unless $version > 0;

        my $value = $decoded->{$key};
        return undef unless ref($value) eq 'ARRAY';
        return undef unless @$value > 0 && @$value <= MAX_CIPHER_LEN;

        for my $b (@$value) {
            return undef unless defined $b && $b =~ /^-?\d+$/ && $b >= 0 && $b <= 255;
        }

        if (!defined $bestVersion || $version > $bestVersion) {
            $bestVersion = $version;
            $bestCipher  = $value;
        }
    }

    return undef unless defined $bestVersion;
    return { version => $bestVersion, cipher => $bestCipher };
}

package Plugins::SpotOn::API::WebPlayer;

1;
