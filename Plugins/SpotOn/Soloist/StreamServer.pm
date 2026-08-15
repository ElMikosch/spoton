package Plugins::SpotOn::Soloist::StreamServer;

use strict;
use warnings;

use Carp qw(croak);
use Scalar::Util qw(blessed refaddr);
use Time::HiRes ();

# LMS looks up raw handlers with URI->path(), which includes the leading slash.
# Keep the slash optional because the handler normalizes it before extracting
# the token and because older test/adaptor callers may already pass a bare path.
# `.soc` is the LMS-facing suffix for decoded PCM. It keeps SpotOn's custom
# input type attached after ProtocolHandler translates the logical URL to HTTP,
# allowing the existing soc -> pcm identity profile to be selected. `.pcm`
# remains accepted as a diagnostic/backward-compatible alias.
use constant STREAM_ROUTE => qr{\A/?plugins/SpotOn/soloist/stream/([0-9a-f]{24})\.(flac|pcm|soc)\z};
use constant MAX_CHUNK_BYTES => 32 * 1024;
use constant PCM_BYTES_PER_SECOND => 44_100 * 2 * 2;
use constant PCM_PACING_DELAY     => 2;

my %factories;
my %active;
my $initialized = 0;

sub init {
    return 1 if $initialized;
    require AnyEvent;
    require AnyEvent::Handle;
    require Slim::Web::HTTP;
    require Slim::Web::Pages;
    Slim::Web::Pages->addRawFunction(STREAM_ROUTE, \&_raw_handler);
    $initialized = 1;
    return 1;
}

sub register_runtime {
    my ($class, $token, $factory) = @_;
    return $class->register_runtime_format($token, 'flac', $factory);
}

sub register_runtime_format {
    my ($class, $token, $format, $factory) = @_;
    _validate_token($token);
    _validate_format($format);
    croak 'Soloist stream pipeline factory must be a code reference'
        unless ref($factory) eq 'CODE';

    my $key = _stream_key($token, $format);
    _close_entry($key, 'runtime_replaced') if $factories{$key};
    $factories{$key} = $factory;
    return stream_path($class, $token, $format);
}

sub unregister_runtime {
    my ($class, $token) = @_;
    _validate_token($token);
    for my $format (qw(flac pcm)) {
        my $key = _stream_key($token, $format);
        delete $factories{$key};
        _close_entry($key, 'runtime_unregistered');
    }
    return 1;
}

sub stream_path {
    my ($class, $token, $format) = @_;
    _validate_token($token);
    $format = 'flac' unless defined $format;
    _validate_format($format);
    my $suffix = $format eq 'pcm' ? 'soc' : $format;
    return "/plugins/SpotOn/soloist/stream/$token.$suffix";
}

sub shutdown {
    _close_entry($_, 'shutdown') for keys %active;
    %factories = ();
    return 1;
}

sub status_snapshot {
    my ($class, $token) = @_;
    if (defined $token) {
        _validate_token($token);
        my %formats;
        for my $format (qw(flac pcm)) {
            my $key = _stream_key($token, $format);
            $formats{$format} = {
                registered => $factories{$key} ? 1 : 0,
                active     => $active{$key} ? 1 : 0,
                pipeline   => $active{$key} && $active{$key}{pipeline}->can('status_snapshot')
                    ? $active{$key}{pipeline}->status_snapshot()
                    : undef,
            };
        }
        return {
            registered => ($formats{flac}{registered} || $formats{pcm}{registered}) ? 1 : 0,
            active     => ($formats{flac}{active} || $formats{pcm}{active}) ? 1 : 0,
            formats    => \%formats,
        };
    }

    return {
        registered => scalar(keys %factories),
        active     => scalar(keys %active),
    };
}

sub _raw_handler {
    my ($http_client, $response) = @_;
    my $request = $response->request();
    my $path = eval { $request->uri()->path() } || '';
    $path =~ s{\A/}{};

    my ($token, $wire_format) = $path =~ STREAM_ROUTE;
    my $format = defined $wire_format && $wire_format eq 'soc'
        ? 'pcm'
        : $wire_format;
    my $key = $token && $format ? _stream_key($token, $format) : '';
    return _error_response($http_client, $response, 404, 'not_found')
        unless $key && $factories{$key};

    my $method = eval { $request->method() } || '';
    return _error_response($http_client, $response, 405, 'method_not_allowed')
        unless $method eq 'GET' || $method eq 'HEAD';

    $response->code(200);
    $response->content_type(
        $format eq 'pcm'
            ? 'audio/L16;rate=44100;channels=2'
            : 'audio/flac'
    );
    $response->header('Accept-Ranges' => 'none');
    $response->header('Cache-Control' => 'no-store');
    $response->header('Connection' => 'close');

    if ($method eq 'HEAD') {
        my $empty = '';
        Slim::Web::HTTP::addHTTPResponse($http_client, $response, \$empty, 1, 0);
        return;
    }

    _close_entry($key, 'replaced') if $active{$key};

    my $pipeline;
    my $started = eval {
        $pipeline = $factories{$key}->();
        croak 'invalid pipeline' unless blessed($pipeline) && $pipeline->can('start');
        $pipeline->start() ? 1 : 0;
    };
    if (!$started) {
        eval { $pipeline->stop() } if blessed($pipeline) && $pipeline->can('stop');
        return _error_response($http_client, $response, 503, 'pipeline_unavailable');
    }

    my $is_chunked = eval { $request->protocol() eq 'HTTP/1.1' } ? 1 : 0;
    if ($is_chunked) {
        $response->header('Transfer-Encoding' => 'chunked');
        $response->header('Connection' => 'close');
    }

    my $entry = {
        pipeline   => $pipeline,
        http_client => $http_client,
        done       => 0,
        format     => $format,
    };
    if ($format eq 'pcm') {
        $entry->{pace_started_at} = _now();
        $entry->{pace_bytes} = 0;
        $entry->{pace_not_before} = $entry->{pace_started_at} + PCM_PACING_DELAY;
    }
    $active{$key} = $entry;

    my ($handle, $writer, $cleanup);
    $cleanup = sub {
        my ($reason) = @_;
        return if $entry->{done}++;

        undef $entry->{read_watcher};
        undef $entry->{pace_timer};
        eval { $pipeline->stop() };
        eval { $handle->destroy() } if $handle;
        delete $active{$key}
            if $active{$key} && refaddr($active{$key}) == refaddr($entry);
        eval {
            Slim::Web::HTTP::closeHTTPSocket($http_client)
                if !$http_client->can('opened') || $http_client->opened();
        };
    };

    $writer = sub {
        return if $entry->{done};

        if ($entry->{finish_after_drain}) {
            $cleanup->('eof');
            return;
        }

        if (defined $entry->{headers}) {
            my $headers = delete $entry->{headers};
            $handle->push_write($headers);
            return;
        }

        if ($entry->{format} eq 'pcm') {
            my $wait = $entry->{pace_not_before} - _now();
            if ($wait > 0) {
                return if $entry->{pace_timer};
                $entry->{pace_timer} = AnyEvent->timer(
                    after => $wait,
                    cb    => sub {
                        undef $entry->{pace_timer};
                        $writer->();
                    },
                );
                return;
            }
        }

        my ($chunk, $status) = $pipeline->read_chunk(MAX_CHUNK_BYTES);
        if ($status eq 'data') {
            if ($entry->{format} eq 'pcm') {
                $entry->{pace_bytes} += length($chunk);
                $entry->{pace_not_before} = $entry->{pace_started_at}
                    + PCM_PACING_DELAY
                    + ($entry->{pace_bytes} / PCM_BYTES_PER_SECOND);
            }
            my $bytes = $is_chunked
                ? sprintf('%X', length($chunk)) . "\r\n" . $chunk . "\r\n"
                : $chunk;
            $handle->push_write($bytes);
            return;
        }

        if ($status eq 'would_block') {
            return if $entry->{read_watcher};
            my $output = $pipeline->output_fh();
            unless ($output) {
                $cleanup->('missing_output');
                return;
            }
            $entry->{read_watcher} = AnyEvent->io(
                fh   => $output,
                poll => 'r',
                cb   => sub {
                    undef $entry->{read_watcher};
                    $writer->();
                },
            );
            return;
        }

        if ($status eq 'eof') {
            if ($is_chunked) {
                $entry->{finish_after_drain} = 1;
                $handle->push_write("0\r\n\r\n");
            }
            else {
                $cleanup->('eof');
            }
            return;
        }

        $cleanup->($status || 'read_failed');
    };

    $handle = AnyEvent::Handle->new(
        fh       => $http_client,
        linger   => 0,
        timeout  => 300,
        on_error => sub {
            my ($hdl, $fatal, $message) = @_;
            $cleanup->('socket_error');
        },
        on_timeout => sub {
            $cleanup->('socket_timeout');
        },
    );
    $entry->{handle} = $handle;
    $entry->{headers} = Slim::Web::HTTP::_stringifyHeaders($response) . "\r\n";
    $handle->on_drain($writer);
    $writer->();
    return;
}

sub _close_entry {
    my ($token, $reason) = @_;
    my $entry = delete $active{$token} || return;
    return if $entry->{done}++;

    undef $entry->{read_watcher};
    undef $entry->{pace_timer};
    eval { $entry->{pipeline}->stop() } if $entry->{pipeline};
    eval { $entry->{handle}->destroy() } if $entry->{handle};
    my $client = $entry->{http_client};
    eval {
        Slim::Web::HTTP::closeHTTPSocket($client)
            if $client && (!$client->can('opened') || $client->opened());
    };
}

sub _error_response {
    my ($http_client, $response, $code, $error) = @_;
    my $body = "$error\n";
    $response->code($code);
    $response->content_type('text/plain; charset=utf-8');
    $response->header('Cache-Control' => 'no-store');
    $response->header('Connection' => 'close');
    Slim::Web::HTTP::addHTTPResponse($http_client, $response, \$body, 1, 0);
    return;
}

sub _validate_token {
    my ($token) = @_;
    croak 'Soloist stream token must be 24 lowercase hexadecimal characters'
        unless defined $token && !ref($token) && $token =~ /\A[0-9a-f]{24}\z/;
    return $token;
}

sub _validate_format {
    my ($format) = @_;
    croak 'Soloist stream format must be flac or pcm'
        unless defined $format && !ref($format)
            && $format =~ /\A(?:flac|pcm)\z/;
    return $format;
}

sub _stream_key {
    my ($token, $format) = @_;
    return "$token:$format";
}

sub _now {
    return Time::HiRes::time();
}

1;
