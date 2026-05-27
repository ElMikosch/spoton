#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

# Resolve the project root: t/ is directly under the project root
my $test_dir     = dirname(abs_path($0));
my $project_dir  = dirname($test_dir);
my $strings_file = "$project_dir/Plugins/SpotOn/strings.txt";

ok(-f $strings_file, "strings.txt exists at $strings_file");

SKIP: {
    skip "strings.txt not found", 1 unless -f $strings_file;

    open(my $fh, '<:encoding(UTF-8)', $strings_file)
        or die "Cannot open $strings_file: $!";
    my $content = do { local $/; <$fh> };
    close($fh);

    # Required keys that must have both EN and DE
    my @bilingual_keys = qw(
        PLUGIN_SPOTON
        PLUGIN_SPOTON_NAME
        PLUGIN_SPOTON_BINARY_MISSING
        PLUGIN_SPOTON_BINARY_STATUS
        PLUGIN_SPOTON_ACCOUNT_SETTINGS
        PLUGIN_SPOTON_ACCOUNT_PLACEHOLDER
        PLUGIN_SPOTON_BITRATE
    );

    # Keys that only require EN (format identifiers etc.)
    my @en_only_keys = qw(SON);

    # Build lookup of what exists
    # strings.txt format: KEY\n\tEN\tvalue\n\tDE\tvalue\n
    my %has_en;
    my %has_de;

    # Parse each line
    my $current_key = '';
    for my $line (split /\n/, $content) {
        if ($line =~ /^([A-Z][A-Z0-9_]+)\s*$/) {
            $current_key = $1;
        } elsif ($line =~ /^\t(EN|DE)\t(.+)$/) {
            my ($lang, $val) = ($1, $2);
            if ($lang eq 'EN') {
                $has_en{$current_key} = 1;
            } elsif ($lang eq 'DE') {
                $has_de{$current_key} = 1;
            }
        }
    }

    # Verify bilingual keys
    for my $key (@bilingual_keys) {
        ok($has_en{$key}, "$key has EN translation");
        ok($has_de{$key}, "$key has DE translation");
    }

    # Verify EN-only keys
    for my $key (@en_only_keys) {
        ok($has_en{$key}, "$key has EN translation");
    }

    # Verify correct indentation: lines must use Tab, not spaces
    my $bad_indent = 0;
    for my $line (split /\n/, $content) {
        # Translation lines should start with \t followed by language code
        if ($line =~ /^ +(?:EN|DE)\t/) {
            $bad_indent++;
        }
    }
    is($bad_indent, 0, "All translation lines use Tab indentation (not spaces)");
}

done_testing();
