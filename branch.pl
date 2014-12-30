#!/usr/bin/perl

use warnings;
use strict;
use 5.010;

use IO::Async::Loop;
use IO::Async::Stream;
use IO::Async::Timer::Periodic;
use JSON qw(encode_json decode_json);

my ($pong_timer, $join_timer, $updt_timer, $conn_timer);
my (%config, @nicks, %connections, %not_joined, %joined, $started);

$SIG{PIPE} = sub {};

my $loop = IO::Async::Loop->new;
my $std  = IO::Async::Stream->new_for_stdio(on_read => \&handle_stdin);

create_timers();
$loop->loop_forever;

##############################
### Sending data to master ###
##############################

sub send_ {
    my ($command, $opts) = @_;
    my $string = encode_json([ $command, $opts || {} ]);
    $std->write("$string\n");
}

sub honestly (@) {
    send_(honestly => \@_);
}

sub update_info {
    send_(update => {
        connected  => scalar keys %connections,
        joined     => scalar keys %joined,
        not_joined => scalar keys %not_joined
    });
}

#############################
### Incoming instructions ###
#############################

sub handle_stdin {
    my ($stream, $buffer) = @_;
    while ($$buffer =~ s/^(.*)\r*\n+//) {
        my ($command, $data) = @{ decode_json($1) or next };
        my $code = __PACKAGE__->can("m_$command") or next;
        $code->($data);
    }
}

sub m_config {
    %config = %{ +shift };
    $join_timer->{interval} = $config{join_timer};
    $pong_timer->{interval} = $config{pong_timer};
}

sub m_nicks { @nicks = @{ +shift } }

sub m_nickchange {
    my @nicks = @{ shift->{nicks} };
    foreach my $s (values %joined) {
        my $nick = pop @nicks or last;
        $s->write("NICK $nick\r\n");
    }
}

sub m_start {
    return if $started;
    $conn_timer->start;
    $loop->add($conn_timer);
    $started = 1;
}

sub m_raw {
    my $data = shift;
    $_->write("$$data{data}\r\n") foreach
        $data->{joined_only} ? values %joined : values %connections;
}

sub new_connection {
    my $nick = shift;
    my $f = $loop->connect(
        addr => {
            family   => index($config{address}, ':') != -1 ? 'inet6' : 'inet',
            socktype => 'stream',
            port     => $config{port},
            ip       => $config{address}
        },
        handle => IO::Async::Stream->new
    );
    $f->on_ready(sub {
        
        # something went wrong.
        if ($f->failure || $f->is_cancelled) {
            push @nicks, $nick;
            undef $f;
            return;
        }
         
        # seems ok...
        my $stream = $f->get;
        $stream->configure(
            on_read        => sub {},
            on_read_error  => \&connection_done,
            on_write_error => \&connection_done,
            on_read_eof    => \&connection_done,
            on_write_eof   => \&connection_done
        );
        $connections{$stream} = $not_joined{$stream} = $stream;
        $loop->add($stream);

        $stream->{nick} = $nick;
        $stream->write("NICK $nick\r\nUSER $nick $nick $nick $nick\r\n");
        
        undef $f;
    });
}

sub connection_done {
    my $stream = shift;
    delete $connections{$stream};
    delete $not_joined{$stream};
    delete $joined{$stream};
    push @nicks, $stream->{nick};
}

##############
### Timers ###
##############

sub create_timers {
    $pong_timer = IO::Async::Timer::Periodic->new(
        interval => 30,
        on_tick  => \&pong_timer
    );

    $join_timer = IO::Async::Timer::Periodic->new(
        interval => 10,
        on_tick  => \&join_timer
    );

    $updt_timer = IO::Async::Timer::Periodic->new(
        interval => 3,
        on_tick  => \&update_info
    );

    $conn_timer = IO::Async::Timer::Periodic->new(
        interval => 1,
        on_tick  => \&conn_timer
    );

    $pong_timer->start;
    $join_timer->start;
    $updt_timer->start;

    $loop->add($_) foreach ($std, $pong_timer, $join_timer, $updt_timer);
}

sub join_timer {
    my $channels = join ',', @{ $config{autojoin} };
    my @not_joined = values %not_joined;
    while (my $conn = shift @not_joined) {
        $conn->write("JOIN $channels\r\n");
        $joined{$conn} = $conn;
    }
    %not_joined = ();
}

sub pong_timer {
    $_->write("PONG :$config{pong_response}\r\n") foreach values %connections;
}

sub conn_timer {
    my $i = 0;
    while (my $nick = shift @nicks) {
        $i++;
        new_connection($nick);
        last if $i == $config{connections_in_row};
    }
}

