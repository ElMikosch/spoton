#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

# Resolve the project root: t/ is directly under the project root
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname($test_dir);

# Helper: read a file and return list of non-comment lines
sub _noncomment_lines {
    my ($file) = @_;
    open(my $fh, '<', $file) or die "Cannot open $file: $!";
    my @lines;
    while (my $line = <$fh>) {
        chomp $line;
        # Skip lines that start with optional whitespace then #
        next if $line =~ /^\s*#/;
        push @lines, $line;
    }
    close($fh);
    return @lines;
}

# Helper: grep non-comment lines of a file for a pattern, return matching lines
sub _grep_file {
    my ($file, $pattern) = @_;
    my @matches = grep { $_ =~ $pattern } _noncomment_lines($file);
    return @matches;
}

# Helper: find all .pm files recursively under a directory
sub _find_pm_files {
    my ($dir) = @_;
    my @files;
    opendir(my $dh, $dir) or die "Cannot opendir $dir: $!";
    for my $entry (sort readdir($dh)) {
        next if $entry =~ /^\./;
        my $path = "$dir/$entry";
        if (-d $path) {
            push @files, _find_pm_files($path);
        } elsif ($entry =~ /\.pm$/) {
            push @files, $path;
        }
    }
    closedir($dh);
    return @files;
}

# ============================================================
# PROTO-01: No spotify:// in routing-URL contexts across Perl source files
# Scan Plugin.pm, ProtocolHandler.pm, Connect.pm, DontStopTheMusic.pm
# non-comment lines for spotify:// (double-slash). Assert zero matches.
# ============================================================
{
    my @files = (
        "$project_dir/Plugins/SpotOn/Plugin.pm",
        "$project_dir/Plugins/SpotOn/ProtocolHandler.pm",
        "$project_dir/Plugins/SpotOn/Connect.pm",
        "$project_dir/Plugins/SpotOn/DontStopTheMusic.pm",
    );

    my @matches;
    for my $file (@files) {
        ok(-f $file, "PROTO-01: source file exists: " . (File::Basename::basename($file)));
        for my $line (_noncomment_lines($file)) {
            if ($line =~ m{spotify://}) {
                push @matches, "$file: $line";
            }
        }
    }

    is(scalar @matches, 0,
        "PROTO-01: zero spotify:// occurrences in non-comment Perl source lines (found: "
        . scalar(@matches)
        . (scalar(@matches) ? ": " . join("; ", @matches[0..($#matches > 2 ? 2 : $#matches)]) : "")
        . ")");
}

# ============================================================
# PROTO-02: ProtocolHandler registered as 'spoton' not 'spotify' in Plugin.pm
# ============================================================
{
    my $plugin_file = "$project_dir/Plugins/SpotOn/Plugin.pm";

    my @spoton_matches  = _grep_file($plugin_file, qr{registerHandler\s*\(\s*['"]spoton['"]});
    my @spotify_matches = _grep_file($plugin_file, qr{registerHandler\s*\(\s*['"]spotify['"]});

    is(scalar @spoton_matches, 1,
        "PROTO-02: Plugin.pm registers handler as 'spoton' exactly once (found: "
        . scalar(@spoton_matches) . ")");

    is(scalar @spotify_matches, 0,
        "PROTO-02: Plugin.pm does NOT register handler as 'spotify' (found: "
        . scalar(@spotify_matches) . ")");
}

# ============================================================
# PROTO-04: Connect URLs use spoton://connect- prefix (3 construction sites)
# ============================================================
{
    my $connect_file = "$project_dir/Plugins/SpotOn/Connect.pm";

    my @matches = _grep_file($connect_file, qr{sprintf.*spoton://connect-});

    cmp_ok(scalar @matches, '>=', 3,
        "PROTO-04: Connect.pm has >= 3 sprintf.*spoton://connect- constructions (found: "
        . scalar(@matches) . ")");
}

# ============================================================
# PROTO-05: No registerHandler('spotify') anywhere under Plugins/SpotOn/
# ============================================================
{
    my $plugins_dir = "$project_dir/Plugins/SpotOn";
    my @pm_files    = _find_pm_files($plugins_dir);

    ok(scalar @pm_files > 0, "PROTO-05: found .pm files under Plugins/SpotOn/");

    my @bad_matches;
    for my $file (@pm_files) {
        for my $line (_noncomment_lines($file)) {
            if ($line =~ qr{registerHandler\s*\(\s*['"]spotify['"]}) {
                push @bad_matches, "$file: $line";
            }
        }
    }

    is(scalar @bad_matches, 0,
        "PROTO-05: zero registerHandler('spotify') across all SpotOn .pm files (found: "
        . scalar(@bad_matches) . ")");
}

# ============================================================
# PROTO-06: cacheSchemaVersion pref and SPOTON_CACHE_VERSION constant in Plugin.pm
# ============================================================
{
    my $plugin_file = "$project_dir/Plugins/SpotOn/Plugin.pm";

    my @cache_ver_matches = _grep_file($plugin_file, qr{cacheSchemaVersion});
    my @const_matches     = _grep_file($plugin_file, qr{SPOTON_CACHE_VERSION});

    cmp_ok(scalar @cache_ver_matches, '>=', 2,
        "PROTO-06: Plugin.pm has >= 2 cacheSchemaVersion references (found: "
        . scalar(@cache_ver_matches) . ")");

    cmp_ok(scalar @const_matches, '>=', 1,
        "PROTO-06: Plugin.pm has >= 1 SPOTON_CACHE_VERSION reference (found: "
        . scalar(@const_matches) . ")");
}

# ============================================================
# Rust binary normalization check:
# main.rs must use replace("spoton://", ...) not replace("spotify://", ...)
# ============================================================
{
    my $rust_file = "$project_dir/librespot-spoton/src/main.rs";

    SKIP: {
        skip "Rust main.rs not found", 2 unless -f $rust_file;

        open(my $fh, '<', $rust_file) or die "Cannot open $rust_file: $!";
        my @lines = <$fh>;
        close($fh);
        chomp @_ for @lines;

        my @spoton_replace  = grep { /replace\("spoton:\/\/"/ } @lines;
        my @spotify_replace = grep { /replace\("spotify:\/\/"/ } @lines;

        cmp_ok(scalar @spoton_replace, '>=', 1,
            "Rust binary: >= 1 replace(\"spoton://\") call in main.rs (found: "
            . scalar(@spoton_replace) . ")");

        is(scalar @spotify_replace, 0,
            "Rust binary: zero replace(\"spotify://\") calls in main.rs (found: "
            . scalar(@spotify_replace) . ")");
    }
}

# ============================================================
# Cache namespace check:
# All 6 Perl modules use Cache->new('spoton', ...) — assert 6 total
# and zero Cache->new() no-args calls in those files
# ============================================================
{
    my @cache_files = (
        "$project_dir/Plugins/SpotOn/Plugin.pm",
        "$project_dir/Plugins/SpotOn/ProtocolHandler.pm",
        "$project_dir/Plugins/SpotOn/Connect.pm",
        "$project_dir/Plugins/SpotOn/DontStopTheMusic.pm",
        "$project_dir/Plugins/SpotOn/API/Client.pm",
        "$project_dir/Plugins/SpotOn/API/TokenManager.pm",
    );

    my $named_ns_count = 0;
    my $noargs_count   = 0;

    for my $file (@cache_files) {
        for my $line (_noncomment_lines($file)) {
            $named_ns_count++ if $line =~ qr{Cache->new\s*\(\s*['"]spoton['"]};
            # Match Cache->new() with no arguments (empty parens, possible whitespace)
            $noargs_count++   if $line =~ qr{Cache->new\s*\(\s*\)};
        }
    }

    is($named_ns_count, 6,
        "Cache namespace: exactly 6 Cache->new('spoton', ...) calls across all 6 modules (found: "
        . $named_ns_count . ")");

    is($noargs_count, 0,
        "Cache namespace: zero Cache->new() no-args calls across all 6 modules (found: "
        . $noargs_count . ")");
}

done_testing();
