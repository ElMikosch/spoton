#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

# Resolve the project root: t/ is directly under the project root
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname($test_dir);
my $conf_file   = "$project_dir/Plugins/SpotOn/custom-convert.conf";

ok(-f $conf_file, "custom-convert.conf exists at $conf_file");

SKIP: {
    skip "custom-convert.conf not found", 4 unless -f $conf_file;

    open(my $fh, '<', $conf_file) or die "Cannot open $conf_file: $!";
    my $content = do { local $/; <$fh> };
    close($fh);

    # v2.0: unified daemon uses soc pcm pipeline only (son-* pipelines removed)
    ok($content =~ m{^soc pcm}m,  "soc pcm pipeline header exists");

    # No son-* pipelines (removed in Phase 30)
    ok($content !~ m{^son }m, "No son-* pipeline headers (legacy removed)");

    # No [spotty] references
    ok($content !~ m{\[spotty\]}, "No [spotty] references in convert.conf");

    # Command line is '-' (direct streaming, no transcoder)
    ok($content =~ m{^\t-$}m, "Pipeline command is '-' (direct streaming)");
}

done_testing();
