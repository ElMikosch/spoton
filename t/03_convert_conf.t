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
    skip "custom-convert.conf not found", 9 unless -f $conf_file;

    open(my $fh, '<', $conf_file) or die "Cannot open $conf_file: $!";
    my $content = do { local $/; <$fh> };
    close($fh);

    # 4 required pipeline headers
    ok($content =~ m{^son pcm}m,  "son pcm pipeline header exists");
    ok($content =~ m{^son flc}m,  "son flc pipeline header exists");
    ok($content =~ m{^son mp3}m,  "son mp3 pipeline header exists");
    ok($content =~ m{^son ogg}m,  "son ogg pipeline header exists");

    # All pipelines reference [spoton] (not [spotty])
    my @pipeline_lines = grep { /\[spoton\]/ } split(/\n/, $content);
    ok(scalar(@pipeline_lines) >= 4,
        "At least 4 pipeline lines reference [spoton]");

    # No [spotty] references
    ok($content !~ m{\[spotty\]}, "No [spotty] references in convert.conf");

    # son ogg pipeline contains --passthrough
    # The pipeline may have a comment line between header and binary invocation
    ok($content =~ m{^son ogg[^\n]*\n(?:[^\n]*\n)*?[^\n]*--passthrough}m,
        "son ogg pipeline contains --passthrough");

    # son flc pipeline contains [flac]
    ok($content =~ m{^son flc[^\n]*\n(?:[^\n]*\n)*?[^\n]*\[flac\]}m,
        "son flc pipeline contains [flac]");

    # son mp3 pipeline contains [lame]
    ok($content =~ m{^son mp3[^\n]*\n(?:[^\n]*\n)*?[^\n]*\[lame\]}m,
        "son mp3 pipeline contains [lame]");
}

done_testing();
