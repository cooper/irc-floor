#!/usr/bin/perl

use warnings;
use strict;
use 5.010;

use IO::Async::Loop;
use IO::Async::Stream;
use IO::Async::Process;
use Data::Random::WordList;
use List::Util   'shuffle';
use Scalar::Util 'weaken';
use JSON qw(encode_json decode_json);

our $VERSION = 0.3;

######################
### Initialization ###
######################

my (@nicks, %nick_used, $nick_num, %branches, $in_cmd);
my %config = (
    clients_per_branch  => 100,
    spaced_output       => undef,
    max_nicks_in_ram    => 50000,
    address             => '127.0.0.1',
    port                => 6667,
    pong_timer          => 30,
    join_timer          => 10,
    pong_response       => 'pong',
    autojoin            => ['#k'],
    connections_in_row  => 50,
    word_list           => '/usr/share/dict/words'
);

my $conf = "$ENV{HOME}/.floorrc";
my $wl   = Data::Random::WordList->new(wordlist => $config{word_list});
my $loop = IO::Async::Loop->new;
my $std  = IO::Async::Stream->new_for_stdio(on_read => \&handle_stdin);

setup();
$loop->loop_forever;

sub setup {
    $loop->add($std);

    # load configuration.
    load();
    
    # determine how many nicks to load.
    $nick_num = $wl->{size};
    my $maxn = $config{max_nicks_in_ram};
    $nick_num = $maxn if $nick_num >= $maxn;
    
    # initial info.
    cmd_sysinfo();
    cmd_set();
    well(
        "IRC server is $config{address}\n",
        'type ? for help'
    );
    
    accept_command();
}

sub load {
    return unless -f $conf;
    local $/ = undef;
    open my $fh, '<', $conf or return;
    my $saved = decode_json(<$fh>);
    close $fh;
    @config{ keys %$saved } = values %$saved;
}

sub save {
    open my $fh, '>', $conf or unfortunately("can't save configuration: $!") and return;
    print $fh encode_json(\%config);
    close $fh;
}

##############
### Output ###
##############

# well: formats command responses in a pretty way.
sub well (@) {
    $std->write("\n");
    foreach (split /\n/, join '', @_) {
        s/^ +//g;
        s/ +$//g;
        s/\t/    /g;
        next unless length $_;
        $std->write("    $_\n");
    }
    $std->write("\n");
}

sub well_map {
    my %hash = @_;
    
    # empty set.
    return well 'none' if !@_;
    
    # only one pair. show as equality.
    return well shift, ' = ', do {
        my $v = shift;
        ref $v ? encode_json($v) : $v;
    } if @_ == 2;
    
    my $max  = length((sort { length $b <=> length $a } keys %hash)[0]) || 0;
    my $cute = '-' x ($max + 4);
    my (@lines, $key, $value) = $cute;
    
    do {
        if (defined $key) {
            $value //= 'undef';
            $value = encode_json($value) if ref $value;
            push @lines, sprintf "| %${max}s | %s", $key, $value;
        }
        push @lines, "| ".(' ' x $max)." |" if $config{spaced_output};
    } while (($key, $value) = splice @_, 0, 2);
    
    push @lines, $cute;
    well join "\n", @lines;
}

sub accept_command { $std->write("[floor] ") }

# honestly: prints automated information that is not a response to anything.
sub honestly {
    $std->write("\n") unless $in_cmd;
    &well;
    accept_command() unless $in_cmd;
}

# unfortunately: confesses an error or warning.
sub unfortunately { &honestly }

#############
### Shell ###
#############

sub handle_stdin {
    my ($stream, $buffer) = @_;
    while ($$buffer =~ s/^(.*)\r*\n+//) {
        $in_cmd   = 1;
        my @split = split /\s+/, $1;
        my $cmd   = shift @split or next;
           $cmd   = 'help' if $cmd eq '?' or $cmd eq 'commands';
        
        # exists.
        if (my $code = __PACKAGE__->can("cmd_$cmd")) {
            $code->(@split);
            next;
        }
        
        unfortunately 'huh';
    }
    continue {
        accept_command();
        undef $in_cmd;
    }
}

# show environment info.
sub cmd_sysinfo {
    well
    "this is floor v$VERSION\n",
    "running on perl ", $^V, " on ", ucfirst $^O, "\n",
    "your dictionary $config{word_list} has $$wl{size} entries\n",
    "All your floor are belong to us";
}

# test nickname dictionary.
sub cmd_wastenick {
    my $nick = get_nickname();
    well
    "you just wasted the nickname: $nick\n",
    "but there are ",
    scalar @nicks, " more in RAM\n and probably lots more in the dictionary";
}

# spawn enough branches to create x clients.
sub cmd_create {
    my ($pp, $b) = ($config{clients_per_branch}, scalar keys %branches);
    my $wanted = shift || $pp;
    my ($branches, $total) = (0, 0);
    until ($total >= $wanted) {
        $branches++;
        $total += $pp;
    }
    $b += $branches;
    well "spawning $branches branches to create $total clients\n",
         "current total capacity is ", $pp * $b," clients on $b branches";
    cmd_spawn($branches);
}

# spawn a branch.
sub cmd_spawn {
    my $count = shift || 1;
    new_branch() for 1..$count;
}

# show current branches.
sub cmd_show {
    well_map(map {
        my $b = $branches{$_};
        my $clients = $b->{connected} || 0;
        my $joined  = $b->{joined}    || 0;
        $_ => "$clients connections; $joined joined"
    } keys %branches);
}

# set or show configuration values.
sub cmd_set {
    my ($key, $value) = (shift, join ' ', @_);
    if (!length $key && !length $value) {
        return well_map(%config);
    }
    if (length $value) {
        $value = undef if $value eq 'undef';
        $value = eval { decode_json($value) } if
            defined $value &&
            $value =~ m/\{.*\}|\[.*\]/;
        $config{$key} = $value;
        send_all(config => \%config);
        save();
    }
    well_map($key => exists $config{$key} ? $config{$key} // 'undef' : 'nonexistent');
}

# send privmsg to channel(s).
sub cmd_say {
    required_params(1, @_) or return;
    my @channels = &get_channels;
    my $message = join ' ', @_;
    send_cmd_joined("PRIVMSG $_ :$message") foreach @channels;
}

# part and join channel(s).
sub cmd_cycle {
    my @channels = &get_channels;
    my $message = join ' ', @_;
    send_cmd_all("PART $_ :$message", "JOIN $_") foreach @channels;
}

# send raw IRC data.
sub cmd_irc {
    my ($data) = required_params(1, @_) or return;
    send_all(raw => { data => $data });
}

# get channels from command or fall back to autojoin channels.
sub get_channels {
    return $_[0] && substr($_[0], 0, 1) eq '#' ?
        split /\,/, shift :
        @{ $config{autojoin} };
}

# show error if not enough args.
sub required_params {
    my ($n, @args) = @_;
    if (@args < $n) {
        my $s = $n > 1 ? 's' : '';
        unfortunately("command requires $n parameter$s");
        return;
    }
    return @args;
}

sub cmd_help {
    well_map(
        set         => 'set or show a configuration value: [key [value]]',
        show        => 'show a status overview of current branches',
        spawn       => 'spawn additional branch(es): [amount]',
        create      => 'shortcut for spawn: desired number of clients',
        say         => 'send a message to IRC channel(s): [#channel] message',
        cycle       => 'part and join IRC channel(s): [#channel] [part message]',
        irc         => 'send raw data to all active connections',
        sysinfo     => 'show information about the operating environment',
        wastenick   => 'waste a nickname to test if the source is functioning',
        sethelp     => 'explain what each configuration value means',
        help        => 'display this information'
    );
}

sub cmd_sethelp {
    well_map(
        address             => ' str) address of the IRC server',
        port                => ' str) port of the IRC server',
        autojoin            => 'list) channels to join automatically',
        clients_per_branch  => ' int) connections to attempt on a single branch',
        max_nicks_in_ram    => ' int) number of nicknames to cache in memory',
        connections_in_row  => ' int) max of new connections per branch per second',
        pong_response       => ' str) what to send as the parameter in PONGs',
        pong_timer          => ' int) how often to send PONGs to server (seconds)',
        join_timer          => ' int) how often to send JOINs to server (seconds)',
        word_list           => ' str) path to dictionary file on the system',
        spaced_output       => 'bool) format table output in a more spaced layout'
    );
}

#########################
### Branch management ###
#########################

sub new_branch {

    # create the process.
    my $branch = IO::Async::Process->new(
        command   => [ qw(perl branch.pl) ],
        stdout    => { on_read => \&handle_branch     },
        stderr    => { on_read => \&handle_branch_err },
        stdin     => { via     => 'pipe_write'        },
        on_finish => sub {
            my ($branch, $code) = @_;
            unfortunately $branch->pid, " exited with code $code";
            delete $branches{ $branch->pid };
        }
    );
    $loop->add($branch);

    if (!$branch->pid) {
        unfortunately "can't create branch: ", $branch->errstr || $@ || $! || 'idk';
        return;
    }

    # hold onto it.
    $branches{ $branch->pid } = $branch;
    $branch->stdout->{branch} = $branch;

    # say hello.
    introduce($branch);
    
    return $branch;
}

sub introduce {
    my $branch = shift;
    
    # send configuration values.
    send_to($branch, config => \%config);
    
    # allocate a lot of nicknames.
    my @b_nicks;
    push @b_nicks, get_nickname() for 1..$config{clients_per_branch};
    send_to($branch, nicks => \@b_nicks);
    
    # begin.
    send_to($branch, 'start');
    
}

sub send_to {
    my ($branch, $command, $opts) = @_;
    my $string = encode_json([ $command, $opts || {} ]);
    $branch->stdin->write("$string\n");
}

sub send_all {
    send_to($_, @_) foreach values %branches; 
}

# send IRC command(s) on all clients.
sub send_cmd_all {
    send_all(raw => { data => $_ }) foreach @_;
}

# send IRC command(s) on joined clients.
sub send_cmd_joined {
    send_all(raw => { data => $_, joined_only => 1 }) foreach @_;
}

############################
### Branch data handling ###
############################

sub handle_branch {
    my ($stream, $buffer) = @_;
    my $branch = $stream->{branch} or return;
    my $handled;
    while ($$buffer =~ s/^(.*)\r*\n+//) {
        undef $handled;
        my ($command, $data) = @{ +eval { decode_json($1) } or next };
        my $code = __PACKAGE__->can("b_$command") or next;
        $code->($branch, $data);
        $handled = 1;
    }
    continue {
        unfortunately '[', $branch->pid, '] ', $1 unless $handled;
    }
}

sub handle_branch_err {
    my ($stream, $buffer) = @_;
    my $branch = $stream->{branch} or return;
    while ($$buffer =~ s/^(.*)\r*\n+//) {
        unfortunately '[', $branch->pid, '] error: ', $1;
    }
    delete $stream->{branch};
}

sub b_honestly {
    my ($branch, $data) = @_;
    my @args = @$data;
    honestly '[', $branch->pid, '] ', @args;
}

sub b_update {
    my ($branch, $data) = @_;
    $branch->{$_} = $data->{$_} foreach keys %$data;
}

##########################
### Choosing nicknames ###
##########################

sub get_nickname {
    @nicks = shuffle $wl->get_words($nick_num) if !@nicks;
    my $nick = shift @nicks;
    return &get_nickname if !$nick || !valid_nick($nick) || $nick_used{$nick};
    $nick_used{$nick} = 1;
    return $nick;
}

sub valid_nick { shift() =~ m/^[A-Za-z_`\-^\|\\\{}\[\]][A-Za-z_0-9`\-^\|\\\{}\[\]]*$/ }
