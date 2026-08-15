#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';

use Test::More;
use FindBin qw($Bin);

BEGIN {
    package main;
    sub INFOLOG () { 0 }

    package Slim::Utils::Log;
    sub import { }
    sub logger { bless {}, 'Local::Log' }
    $INC{'Slim/Utils/Log.pm'} = 1;

    package Local::Log;
    sub is_info { 0 }
    sub info { }
    sub warn { }

    package Slim::Web::Pages;
    our @raw;
    sub addRawFunction { push @raw, [$_[1], $_[2]] }
    $INC{'Slim/Web/Pages.pm'} = 1;

    package Slim::Web::HTTP;
    our @responses;
    our @closed;
    sub addHTTPResponse { push @responses, [@_] }
    sub closeHTTPSocket { push @closed, $_[0]; $_[0]{opened} = 0 }
    sub _stringifyHeaders {
        my ($response) = @_;
        return 'HTTP/1.1 ' . $response->{code} . " Test\r\n"
            . 'Content-Type: ' . $response->{content_type} . "\r\n";
    }
    $INC{'Slim/Web/HTTP.pm'} = 1;

    package AnyEvent;
    our @watchers;
    sub import { }
    sub io {
        my ($class, %args) = @_;
        my $watcher = bless { %args }, 'Local::Watcher';
        push @watchers, $watcher;
        return $watcher;
    }
    $INC{'AnyEvent.pm'} = 1;

    package AnyEvent::Handle;
    our @handles;
    sub new {
        my ($class, %args) = @_;
        my $self = bless {
            args      => { %args },
            writes    => [],
            destroyed => 0,
        }, 'Local::Handle';
        push @handles, $self;
        return $self;
    }
    $INC{'AnyEvent/Handle.pm'} = 1;

    package Local::Handle;
    sub on_drain { $_[0]{on_drain} = $_[1] }
    sub push_write { push @{ $_[0]{writes} }, $_[1] }
    sub drain { $_[0]{on_drain}->() }
    sub destroy { $_[0]{destroyed} = 1 }
}

use lib "$Bin/..";
use Plugins::SpotOn::Soloist::StreamServer;

{
    package Local::URI;
    sub new { bless { path => $_[1] }, $_[0] }
    sub path { $_[0]{path} }

    package Local::Request;
    sub new {
        my ($class, %args) = @_;
        return bless {
            method   => $args{method} || 'GET',
            protocol => $args{protocol} || 'HTTP/1.0',
            uri      => Local::URI->new($args{path}),
        }, $class;
    }
    sub method { $_[0]{method} }
    sub protocol { $_[0]{protocol} }
    sub uri { $_[0]{uri} }

    package Local::Response;
    sub new { bless { request => $_[1], headers => {} }, $_[0] }
    sub request { $_[0]{request} }
    sub code { $_[0]{code} = $_[1] if @_ > 1; $_[0]{code} }
    sub content_type { $_[0]{content_type} = $_[1] if @_ > 1; $_[0]{content_type} }
    sub header { $_[0]{headers}{ $_[1] } = $_[2] if @_ > 2; $_[0]{headers}{ $_[1] } }

    package Local::HTTPClient;
    sub new { bless { opened => 1 }, $_[0] }
    sub opened { $_[0]{opened} }

    package Local::Pipeline;
    our @instances;
    sub new {
        my ($class, @steps) = @_;
        my $self = bless {
            steps   => [@steps],
            started => 0,
            stopped => 0,
            output  => bless({}, 'Local::Output'),
        }, $class;
        push @instances, $self;
        return $self;
    }
    sub start { $_[0]{started} = 1; 1 }
    sub stop { $_[0]{stopped}++; 1 }
    sub output_fh { $_[0]{output} }
    sub read_chunk {
        my ($self) = @_;
        my $step = shift @{ $self->{steps} } || ['', 'eof'];
        return @$step;
    }
    sub status_snapshot { return { state => 'running' } }
}

my $token = '0123456789abcdef01234567';
ok(Plugins::SpotOn::Soloist::StreamServer->init(), 'stream server registers LMS raw route');
is(scalar @Slim::Web::Pages::raw, 1, 'one raw route is registered');
like("plugins/SpotOn/soloist/stream/$token.flac", $Slim::Web::Pages::raw[0][0], 'route matches tokenized FLAC URL');

my $pipeline;
my $path = Plugins::SpotOn::Soloist::StreamServer->register_runtime(
    $token,
    sub {
        $pipeline = Local::Pipeline->new(
            ['FLAC-A', 'data'],
            [undef, 'would_block'],
            ['FLAC-B', 'data'],
            ['', 'eof'],
        );
        return $pipeline;
    },
);
is($path, "/plugins/SpotOn/soloist/stream/$token.flac", 'registered runtime gets stable stream path');

my $client = Local::HTTPClient->new();
my $response = Local::Response->new(Local::Request->new(
    method   => 'GET',
    protocol => 'HTTP/1.1',
    path     => $path,
));
$Slim::Web::Pages::raw[0][1]->($client, $response);

ok($pipeline->{started}, 'GET starts a fresh capture pipeline');
is($response->{code}, 200, 'stream responds successfully');
is($response->{content_type}, 'audio/flac', 'stream declares FLAC content');
is($response->{headers}{'Transfer-Encoding'}, 'chunked', 'HTTP/1.1 stream uses chunked transfer');

my $handle = $AnyEvent::Handle::handles[-1];
like($handle->{writes}[0], qr/^HTTP\/1\.1 200/, 'stream writes HTTP headers first');
$handle->drain();
is($handle->{writes}[1], "6\r\nFLAC-A\r\n", 'first FLAC chunk is framed');
$handle->drain();
is(scalar @AnyEvent::watchers, 1, 'empty nonblocking pipe installs a read watcher');
$AnyEvent::watchers[-1]{cb}->();
is($handle->{writes}[2], "6\r\nFLAC-B\r\n", 'read watcher resumes encoded output');
$handle->drain();
is($handle->{writes}[3], "0\r\n\r\n", 'EOF emits final HTTP chunk');
$handle->drain();
ok($pipeline->{stopped}, 'EOF tears down capture pipeline');
ok($handle->{destroyed}, 'EOF releases AnyEvent handle');
ok(!$client->{opened}, 'EOF closes LMS HTTP socket');

my $unknown_client = Local::HTTPClient->new();
my $unknown_response = Local::Response->new(Local::Request->new(
    path => '/plugins/SpotOn/soloist/stream/ffffffffffffffffffffffff.flac',
));
$Slim::Web::Pages::raw[0][1]->($unknown_client, $unknown_response);
is($unknown_response->{code}, 404, 'unregistered stream token is not exposed');
is(
    ${ $Slim::Web::HTTP::responses[-1][2] },
    "not_found\n",
    'unknown token has a bounded error response',
);

my $head_pipeline_count = scalar @Local::Pipeline::instances;
my $head_client = Local::HTTPClient->new();
my $head_response = Local::Response->new(Local::Request->new(
    method => 'HEAD',
    path   => $path,
));
$Slim::Web::Pages::raw[0][1]->($head_client, $head_response);
is($head_response->{code}, 200, 'HEAD reports stream availability');
is(scalar @Local::Pipeline::instances, $head_pipeline_count, 'HEAD does not start audio capture');

my $failed_token = 'aaaaaaaaaaaaaaaaaaaaaaaa';
Plugins::SpotOn::Soloist::StreamServer->register_runtime(
    $failed_token,
    sub { die "factory failed\n" },
);
my $failed_client = Local::HTTPClient->new();
my $failed_response = Local::Response->new(Local::Request->new(
    path => "/plugins/SpotOn/soloist/stream/$failed_token.flac",
));
$Slim::Web::Pages::raw[0][1]->($failed_client, $failed_response);
is($failed_response->{code}, 503, 'pipeline factory failures become bounded HTTP errors');
is(
    ${ $Slim::Web::HTTP::responses[-1][2] },
    "pipeline_unavailable\n",
    'pipeline exception details are not exposed to the client',
);
Plugins::SpotOn::Soloist::StreamServer->unregister_runtime($failed_token);

my $bad_token_error = eval {
    Plugins::SpotOn::Soloist::StreamServer->register_runtime('not-a-token', sub { });
    '';
} || $@;
like($bad_token_error, qr/24 lowercase hexadecimal/, 'invalid route tokens are rejected');

ok(Plugins::SpotOn::Soloist::StreamServer->unregister_runtime($token), 'runtime unregisters cleanly');
ok(
    !Plugins::SpotOn::Soloist::StreamServer->status_snapshot($token)->{registered},
    'unregistered token disappears from status',
);
ok(Plugins::SpotOn::Soloist::StreamServer->shutdown(), 'stream server shutdown is idempotent');

done_testing();
