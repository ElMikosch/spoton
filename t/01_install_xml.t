#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

# Resolve the project root: t/ is directly under the project root
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname($test_dir);
my $xml_file    = "$project_dir/Plugins/SpotOn/install.xml";

# Check file exists
ok(-f $xml_file, "install.xml exists at $xml_file");

SKIP: {
    skip "install.xml not found", 7 unless -f $xml_file;

    open(my $fh, '<', $xml_file) or die "Cannot open $xml_file: $!";
    my $content = do { local $/; <$fh> };
    close($fh);

    # Parse as XML using regex (XML::Simple may not be available outside LMS)
    ok($content =~ m{<extension>}, "install.xml contains <extension> root element");

    # module = Plugins::SpotOn::Plugin
    ok($content =~ m{<module>\s*Plugins::SpotOn::Plugin\s*</module>},
        "module is Plugins::SpotOn::Plugin");

    # minVersion = 8.0
    ok($content =~ m{<minVersion>\s*8\.0\s*</minVersion>},
        "minVersion is 8.0");

    # maxVersion = *
    ok($content =~ m{<maxVersion>\s*\*\s*</maxVersion>},
        "maxVersion is *");

    # id must exist, be non-empty, and NOT be Spotty's GUID
    my ($id) = ($content =~ m{<id>\s*([0-9a-f-]+)\s*</id>}i);
    ok(defined $id && length($id) > 0, "id field is non-empty");
    isnt($id, '21cbb80e-67b8-44a8-a662-21c6c7ae5260', "id is not Spotty's GUID");

    # category = musicservices
    ok($content =~ m{<category>\s*musicservices\s*</category>},
        "category is musicservices");
}

done_testing();
