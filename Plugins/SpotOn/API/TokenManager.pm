package Plugins::SpotOn::API::TokenManager;

use strict;
use warnings;

use File::Copy qw(move);
use File::Path qw(mkpath rmtree);
use File::Spec::Functions qw(catdir catfile);
use Digest::MD5 qw(md5_hex);
use JSON::XS::VersionOneAndTwo;

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Slim::Utils::Unicode;
use Time::HiRes;

# Helper is loaded by Plugin.pm at startup; require here for standalone use in tests
require Plugins::SpotOn::Helper;

# Constants
use constant TOKEN_EXPIRY_BUFFER    => 300;       # Refresh 5 min before expiry
use constant TOKEN_REFRESH_TIMER    => 45 * 60;   # 45 minute proactive refresh cycle
use constant CLIENT_ID              => '65b708073fc0480ea92a077233ca87bd';
use constant REQUIRED_SCOPES        => join(' ', qw(
    user-read-playback-state
    user-modify-playback-state
    user-read-currently-playing
    user-read-recently-played
    user-read-private
    playlist-read-private
    user-library-read
    user-top-read
    streaming
));

my $log   = logger('plugin.spoton');
my $prefs = preferences('plugin.spoton');
my $cache = Slim::Utils::Cache->new();

# ============================================================
# Public class methods
# ============================================================

# refreshToken($class, $accountId, $cb)
# Spawns binary with --get-token, parses JSON from stdout,
# caches token, invokes $cb->($token) on success, $cb->(undef) on failure.
sub refreshToken {
    my ($class, $accountId, $cb) = @_;

    my $binary = Plugins::SpotOn::Helper->get();
    unless ($binary) {
        $log->error("TokenManager: no binary found, cannot refresh token");
        $cb->(undef);
        return;
    }

    my $cacheDir = $class->_cacheDir($accountId);

    # Shell-safe quoting — T-02-04 protection
    (my $safeBin   = $binary)   =~ s/'/'\\''/g;
    (my $safeCache = $cacheDir) =~ s/'/'\\''/g;
    (my $safeScope = REQUIRED_SCOPES) =~ s/'/'\\''/g;

    my $cmd = sprintf(
        "'%s' -n 'SpotOn' --cache '%s' --get-token --scope '%s' 2>/dev/null",
        $safeBin, $safeCache, $safeScope
    );

    # T-02-06: alarm(10) to prevent LMS freeze on network outage
    my $output;
    local $SIG{ALRM} = sub { die "timeout\n" };
    eval {
        alarm(10);
        $output = `$cmd`;
        alarm(0);
    };
    alarm(0);

    if ($@) {
        $log->error("TokenManager: --get-token timed out for account $accountId");
        $cb->(undef);
        return;
    }

    unless ($output && $output =~ /^\{/) {
        $log->error("TokenManager: --get-token returned no JSON for account $accountId");
        $cb->(undef);
        return;
    }

    my $tokenData = eval { from_json($output) };
    if ($@ || !$tokenData) {
        $log->error("TokenManager: JSON parse error from --get-token for account $accountId: $@");
        $cb->(undef);
        return;
    }

    # Handle both camelCase and snake_case key names
    my $token     = $tokenData->{accessToken}  || $tokenData->{access_token};
    my $expiresIn = $tokenData->{expiresIn}    || $tokenData->{expires_in} || 3600;

    unless ($token) {
        $log->error("TokenManager: no accessToken in binary response for account $accountId");
        $cb->(undef);
        return;
    }

    $class->_cacheToken($accountId, { accessToken => $token, expiresIn => $expiresIn });
    $cb->($token);
}

# getToken($class, $accountId, $cb)
# Checks cache first; falls back to refreshToken on miss.
sub getToken {
    my ($class, $accountId, $cb) = @_;

    my $cached = $cache->get("spoton_token_$accountId");
    if (defined $cached) {
        main::INFOLOG && $log->info("TokenManager: cache hit for account $accountId");
        $cb->($cached);
        return;
    }

    $class->refreshToken($accountId, $cb);
}

# addAccount($class, $username, $password, $cb)
# Authenticates via binary --authenticate, stores account in prefs.
sub addAccount {
    my ($class, $username, $password, $cb) = @_;

    unless ($username && $password) {
        $cb->(undef, "Username and password are required");
        return;
    }

    my $binary = Plugins::SpotOn::Helper->get();
    unless ($binary) {
        $cb->(undef, "SpotOn binary not found");
        return;
    }

    # Compute account ID: MD5 of transliterated username, first 8 hex chars
    my $normalized = Slim::Utils::Unicode::utf8toLatin1Transliterate($username) || $username;
    my $accountId  = substr(md5_hex($normalized), 0, 8);

    my $tempDir = $class->_newAccountCacheDir();

    # Create temp dir
    eval { mkpath($tempDir) };
    if ($@) {
        $cb->(undef, "Cannot create temp directory: $@");
        return;
    }

    # Shell-safe quoting — T-02-04: all user-supplied values
    (my $safeBin   = $binary)   =~ s/'/'\\''/g;
    (my $safeUser  = $username) =~ s/'/'\\''/g;
    (my $safePass  = $password) =~ s/'/'\\''/g;
    (my $safeCache = $tempDir)  =~ s/'/'\\''/g;

    my $cmd = sprintf(
        "'%s' -n 'SpotOn' --username '%s' --password '%s' --authenticate --cache '%s' 2>/dev/null",
        $safeBin, $safeUser, $safePass, $safeCache
    );

    # T-02-06: alarm(15) — auth takes longer than token fetch
    my $output;
    local $SIG{ALRM} = sub { die "timeout\n" };
    eval {
        alarm(15);
        $output = `$cmd`;
        alarm(0);
    };
    alarm(0);

    if ($@) {
        eval { rmtree($tempDir) };
        $cb->(undef, "Authentication timed out");
        return;
    }

    unless ($output && $output =~ /^authorized/i) {
        eval { rmtree($tempDir) };
        my $error = $output ? "Authentication failed: $output" : "Authentication failed";
        $log->error("TokenManager: addAccount failed for '$username'");
        $cb->(undef, $error);
        return;
    }

    # Finalize: move temp dir to permanent location keyed by accountId
    my $finalDir = $class->_cacheDir($accountId);

    # Remove existing dir if present (re-auth of same account)
    eval { rmtree($finalDir) } if -d $finalDir;

    unless (rename($tempDir, $finalDir) || move($tempDir, $finalDir)) {
        eval { rmtree($tempDir) };
        $cb->(undef, "Cannot finalize account directory");
        return;
    }

    # Set secure permissions — T-02-05
    $class->_setPermissions($accountId);

    # Store in prefs
    my $accounts = $prefs->get('accounts') || {};
    $accounts->{$accountId} = {
        username    => $username,
        displayName => $username,    # Phase 3 will update via getMe
    };
    $prefs->set('accounts', $accounts);

    main::INFOLOG && $log->info("TokenManager: account $accountId added for '$username'");
    $cb->($accountId, undef);
}

# removeAccount($class, $accountId)
# Removes account from prefs, cache, and filesystem.
sub removeAccount {
    my ($class, $accountId) = @_;

    # Remove from prefs
    my $accounts = $prefs->get('accounts') || {};
    delete $accounts->{$accountId};
    $prefs->set('accounts', $accounts);

    # Clear cached token
    $cache->remove("spoton_token_$accountId");

    # Remove credential directory
    my $dir = $class->_cacheDir($accountId);
    eval { rmtree($dir) } if -d $dir;

    # Clear active account if it was this one
    my $active = $prefs->get('activeAccount') || '';
    if ($active eq $accountId) {
        $prefs->set('activeAccount', '');
    }

    main::INFOLOG && $log->info("TokenManager: account $accountId removed");
}

# getAccountIds($class)
# Returns list of known account IDs.
sub getAccountIds {
    my ($class) = @_;
    my $accounts = $prefs->get('accounts') || {};
    return keys %{$accounts};
}

# getActiveAccountName($class, $client)
# Returns displayName of active account, or undef.
sub getActiveAccountName {
    my ($class, $client) = @_;

    my $activeId;
    if ($client) {
        $activeId = $prefs->client($client)->get('activeAccount');
    }
    $activeId ||= $prefs->get('activeAccount');

    return undef unless $activeId;

    my $accounts = $prefs->get('accounts') || {};
    return $accounts->{$activeId} ? $accounts->{$activeId}{displayName} : undef;
}

# refreshAllTokens($class)
# Refreshes tokens for all accounts and re-arms the 45-minute timer.
sub refreshAllTokens {
    my ($class) = @_;

    my @ids = $class->getAccountIds();
    for my $id (@ids) {
        $class->refreshToken($id, sub {
            my $token = shift;
            main::INFOLOG && $log->info("TokenManager: refreshed token for account $id")
                if $token;
            $log->error("TokenManager: failed to refresh token for account $id")
                unless $token;
        });
    }

    # Re-arm timer
    Slim::Utils::Timers::killTimers($class, \&refreshAllTokens);
    Slim::Utils::Timers::setTimer(
        $class,
        Time::HiRes::time() + TOKEN_REFRESH_TIMER,
        \&refreshAllTokens
    );
}

# ============================================================
# Private methods
# ============================================================

# _cacheDir($class, $accountId)
# Returns path to the credential/cache directory for this account.
sub _cacheDir {
    my ($class, $accountId) = @_;
    return catdir(preferences('server')->get('cachedir'), 'spoton', $accountId);
}

# _newAccountCacheDir()
# Returns path to a temporary directory used during authentication.
sub _newAccountCacheDir {
    my ($class) = @_;
    return catdir(preferences('server')->get('cachedir'), 'spoton', '__AUTHENTICATE__');
}

# _cacheToken($class, $accountId, $tokenData)
# Caches the access token with TTL = expiresIn - TOKEN_EXPIRY_BUFFER.
# T-02-07: Never logs the token value itself.
sub _cacheToken {
    my ($class, $accountId, $tokenData) = @_;

    my $expiresIn = $tokenData->{expiresIn} || 3600;
    my $ttl = $expiresIn > TOKEN_EXPIRY_BUFFER
        ? $expiresIn - TOKEN_EXPIRY_BUFFER
        : ($expiresIn > 60 ? $expiresIn : 60);

    $cache->set("spoton_token_$accountId", $tokenData->{accessToken}, $ttl);
    main::INFOLOG && $log->info("TokenManager: token cached for account $accountId, TTL ${ttl}s");
}

# _setPermissions($class, $accountId)
# Sets chmod 0700 on credential directory, 0600 on credentials.json.
# T-02-05 mitigation: prevent world-readable credential files.
sub _setPermissions {
    my ($class, $accountId) = @_;

    my $dir  = $class->_cacheDir($accountId);
    my $cred = catfile($dir, 'credentials.json');

    chmod 0700, $dir  if -d $dir;
    chmod 0600, $cred if -f $cred;
}

# _finalizeAccountDir($class, $tempDir, $accountId)
# Moves temp authentication directory to the permanent per-account location.
sub _finalizeAccountDir {
    my ($class, $tempDir, $accountId) = @_;

    my $finalDir = $class->_cacheDir($accountId);
    return rename($tempDir, $finalDir) || move($tempDir, $finalDir);
}

1;
