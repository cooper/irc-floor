#!/usr/bin/perl

use warnings;
use strict;
use 5.010;

use IO::Async::Loop;
use IO::Async::Stream;
use IO::Async::Process;
use Data::Random::WordList;
use List::Util   qw(shuffle sum);
use Scalar::Util qw(weaken looks_like_number);
use JSON ();

our $VERSION = '0.62';


######################
### Initialization ###
######################

my $json = JSON->new->allow_nonref;
my (@nicks, %nick_used, $nick_num, %branches, $in_cmd, $not_full);

# DEFAULTS
my %config = (
    clients_per_branch  => 100,
    spaced_output       => undef,
    max_nicks_in_ram    => 5000,
    address             => '127.0.0.1',
    port                => 6667,
    pong_timer          => 30,
    join_timer          => 10,
    pong_response       => 'pong',
    autojoin            => [],
    connections_in_row  => 50,
    word_list           => '/usr/share/dict/words'
);

# command help text
my %cmd_help = (
    show        => 'show a status overview of current branches',
    create      => 'create additional clients: [amount]',
    spawn       => 'spawn additional branch(es): [amount]',
    say         => 'send a message to IRC channel(s): [#channels] message',
    me          => 'send an action to IRC channel(s): [#channels] action',
    cycle       => 'part and join IRC channel(s): [#channels] [part message]',
    nickchange  => 'randomly change client nicknames: [times]',
    irc         => 'send raw data to all active connections',
    sysinfo     => 'show information about the operating environment',
    wastenick   => 'waste a nickname to test if the source is functioning',
    join        => 'join IRC channels(s): #channels',
    part        => 'leave IRC channel(s): #channels',
    '@'         => 'display current configuration',
    '?@'        => 'explain what each setting means',
    '?'         => 'display this help text'
);

# setting help text
my %cmd_sethelp = (
    address             => 'str    address of the IRC server',
    port                => 'str    port of the IRC server',
    autojoin            => 'list   channels to join automatically',
    clients_per_branch  => 'int    connections to attempt on a single branch',
    max_nicks_in_ram    => 'int    number of nicknames to cache in memory',
    connections_in_row  => 'int    max of new connections per branch per second',
    pong_response       => 'str    what to send as the parameter in PONGs',
    pong_timer          => 'int    how often to send PONGs to server (seconds)',
    join_timer          => 'int    how often to send JOINs to server (seconds)',
    word_list           => 'str    path to dictionary file on the system',
    spaced_output       => 'bool   format table output in a more spaced layout'
);

my @huh = (
    'huh',
    'sorry.. im not gettin it',
    'nice try, bucko',
    'not quite understanding'
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
    well(
        "IRC server is $config{address}\n",
        "type @ to view configuration\n",
        'type ? for help'
    );
    
    well('All your floor are belong to us');
    accept_command();
}

sub load {
    return unless -f $conf;
    local $/ = undef;
    open my $fh, '<', $conf or return;
    my $saved = $json->decode(<$fh>);
    close $fh;
    @config{ keys %$saved } = values %$saved;
}

sub save {
    open my $fh, '>', $conf
        or unfortunately("can't save configuration: $!") and return;
    print $fh $json->encode(\%config);
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
    return well 'no active branches' if !@_;
    
    # only one pair. show as equality.
    return well(shift, ' = ', shift)
        if @_ == 2;
    
    my $max  = length((sort { length $b <=> length $a } keys %hash)[0]) || 0;
    my $cute = '-' x ($max + 4);
    my (@lines, $key, $value) = $cute;
    
    # alphabetize
    my %h = @_;
    @_ = map { $_ => $h{$_} } sort keys %h;
    
    do {
        push @lines, sprintf "| %${max}s | %s", $key, $value
            if defined $key;
        push @lines, "| ".(' ' x $max)." |" if $config{spaced_output};
    } while (($key, $value) = splice @_, 0, 2);
    
    push @lines, $cute;
    well join "\n", @lines;
}

sub accept_command { $std->write("[floor] ") }

# honestly: prints automated information that is not a response to anything.
sub honestly (@) {
    $std->write("\n") unless $in_cmd;
    &well;
    accept_command() unless $in_cmd;
}

# unfortunately: confesses an error or warning.
sub unfortunately (@) { &honestly }

#############
### Shell ###
#############

sub handle_stdin {
    my ($stream, $buffer) = @_;
    while ($$buffer =~ s/^(.*)\r*\n+//) {
        my $line  = $1;
        $in_cmd   = 1;
        my @split = split /\s+/, $line;
        my $cmd   = shift @split or next;
            $cmd  = 'help'    if $cmd eq '?' or $cmd eq 'commands';
            $cmd  = 'sethelp' if $cmd eq '?@';
            _set() and next   if $cmd eq '@';
        
        # variable.
        if    ($line =~ m/^\@(\w+)$/)            { _set($1)     }
        elsif ($line =~ m/^\@(\w+)\s*=\s*(.+)$/) { _set($1, $2) }
        
        # command.
        elsif (my $code = __PACKAGE__->can("cmd_$cmd")) {
            $code->(@split);
        }
        
        # unknown.
        else { unfortunately $huh[rand @huh], "\n", 'type ? for help' }
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
    "your dictionary $config{word_list} has $$wl{size} entries";
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
    my ($create_n) = required_params(1, @_) or return;
    requires_number($create_n) or return;
    my $per_branch = $config{clients_per_branch};
    
    # create full branches.
    my $branches_needed = int($create_n / $per_branch);
    new_branch() for 1 .. $branches_needed;
    
    # create a last branch with the rest.
    if (($branches_needed + 1) * $per_branch > $create_n) {
        my $leftover = $create_n - $branches_needed * $per_branch;
        
        # see if we can squeeze any into one that's not full.
        if ($not_full) {
            my $can_fit = $per_branch - $not_full->{clients};
            $can_fit = $leftover if $can_fit > $leftover; # can fit more than needed
            introduce($not_full, $can_fit);
            $leftover -= $can_fit;
        }
        
        # still some left over. create another branch.
        if ($leftover > 0) {
            $not_full = new_branch($leftover);
            $branches_needed++;
        }
        
    }
    
    my $total_br = scalar keys %branches;
    my $capacity = sum map $_->{clients}, values %branches;
    well "spawning $branches_needed branches to create $create_n clients\n",
         "current total capacity is $capacity clients on $total_br branches";
}

# spawn a branch.
sub cmd_spawn {
    my $count = requires_number(shift || 1) or return;
    new_branch() for 1 .. $count;
}

# show current branches.
sub cmd_show {
    well_map(map {
        my $b = $branches{$_};
        my $clients = $b->{connected} || 0;
        my $joined  = $b->{joined}    || 0;
        $_ => "$clients connected; $joined joined"
    } keys %branches);
}

# set or show configuration values.
sub _set {
    my ($key, $value) = (shift, join ' ', @_);
    
    # @
    # show all current values
    if (!length $key && !length $value) {
        well_map(map { '@'.$_ => $json->encode($config{$_}) } keys %config);
        well
            "type ?@ for explanation of each setting\n",
            "set configuration values with: ",
            "\@key = value";
        return 1;
    }
    
    # @name = value
    # set a value
    if (length $value) {
        $value = 'null' if $value eq 'undef';
        $value = eval { $json->decode($value) } if
            defined $value;
        if ($@) {
            unfortunately("value syntax error\n", "$@");
            return;
        }
        $config{$key} = $value;
        delete $config{$key} if !defined $value;
        send_all(config => \%config);
        save();
    }
    
    # @name
    # show a value
    well_map('@'.$key => $json->encode($config{$key}));
}

# join channel(s)
sub cmd_join {
    required_params(1, @_) or return;
    my @channels = &get_channels;
    send_all(join => { channels => \@channels });
}

# part channel(s)
sub cmd_part {
    required_params(1, @_) or return;
    my @channels = &get_channels;
    send_all(part => { channels => \@channels });
}

# send privmsg to channel(s).
sub cmd_say {
    required_params(1, @_) or return;
    my @channels = &get_channels;
    my $message = join ' ', @_;
    send_channels("PRIVMSG %s :$message", @channels);
}

# send action to channel(s).
sub cmd_me {
    required_params(1, @_) or return;
    my @channels = &get_channels;
    my $message = join ' ', @_;
    send_channels("PRIVMSG %s :\1ACTION $message\1", @channels);
}

# part and join channel(s).
sub cmd_cycle {
    my @channels = &get_channels;
    my $message = join ' ', @_;
    send_channels("PART %s :$message", @channels);
}

# change nicknames.
sub cmd_changenick { &cmd_nickchange }
sub cmd_nickchange {
    
    # do multiple times?
    my $times = shift;
    requires_number($times) or return if $times;
    my $n = 0;
    
    $times ||= 1;
    ROUND: for (1 .. $times) {
        BRANCH: foreach my $b (values %branches) {
            next BRANCH unless $b->{joined};
            # note: $b->{joined} may be inaccurate by up to three seconds.
            my @new_nicks = map { get_nickname() } 1 .. $b->{joined};
            $n += $b->{joined};
            send_to($b, nickchange => { nicks => \@new_nicks });
        }
    }
    
    well "$n nicks changed";
}

# send raw IRC data.
sub cmd_irc {
    required_params(1, @_) or return;
    unfortunately 'no active branches'
        and return if !keys %branches;
    send_all(raw => { data => join ' ', @_ });
}

# get channels from command or fall back to autojoin channels.
sub get_channels {
    unfortunately 'no active branches'
        and return if !keys %branches;
    my @channels = $_[0] && substr($_[0], 0, 1) eq '#' ?
        split /\,/, shift : ();
    return @channels;
}

# show error if not enough args.
sub required_params {
    my ($n, @args) = @_;
    if (@args < $n) {
        my $s = $n > 1 ? 's' : '';
        my $cmd = (caller 1)[3] =~ s/^(.*::)?cmd_//r;
        unfortunately(
            "requires $n parameter$s\n",
            $cmd_help{$cmd}
        );
        return;
    }
    return @args;
}

# show an error if not a number.
sub requires_number {
    my $n = shift;
    return $n if looks_like_number($n);
    my $cmd = (caller 1)[3] =~ s/^(.*::)?cmd_//r;
    unfortunately(
        "expected a number\n",
        $cmd_help{$cmd}
    );
    return;
}

sub cmd_help {
    well_map(%cmd_help);
}

sub cmd_sethelp {
    well_map(map { '@'.$_ => $cmd_sethelp{$_} } keys %cmd_sethelp);
}

#########################
### Branch management ###
#########################

sub new_branch {
    my $client_n = shift // $config{clients_per_branch};

    # create the process.
    my $branch = IO::Async::Process->new(
        command   => [ qw(perl branch.pl) ],
        stdout    => { on_read => \&handle_branch     },
        stderr    => { on_read => \&handle_branch_err },
        stdin     => { via     => 'pipe_write'        },
        on_finish => sub {
            my ($branch, $code) = @_;
            unfortunately '[', $branch->pid, '] ', " exited with code $code";
            delete $branches{ $branch->pid };
        }
    );
    $loop->add($branch);

    if (!$branch->pid) {
        unfortunately "can't create branch: ",
        $branch->errstr || $@ || $! || 'idk';
        return;
    }

    # hold onto it.
    $branches{ $branch->pid } = $branch;
    $branch->stdout->{branch} = $branch;
    $branch->stderr->{branch} = $branch;
    $branch->{clients} = 0;

    # say hello.
    introduce($branch, $client_n);
    
    return $branch;
}

sub introduce {
    my ($branch, $client_n) = @_;
    $branch->{clients} += $client_n;
    
    # send configuration values.
    send_to($branch, config => \%config);
    
    # allocate a lot of nicknames.
    my @b_nicks;
    push @b_nicks, get_nickname() for 1 .. $client_n;
    send_to($branch, nicks => \@b_nicks);
    
    # begin.
    send_to($branch, 'start');
    
}

sub send_to {
    my ($branch, $command, $opts) = @_;
    my $string = $json->encode([ $command, $opts || {} ]);
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

sub send_channels {
    my ($line, @channels) = @_;
    send_all(channels => {
        line        => $line,
        channels    => \@channels
    });
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
        my ($command, $data) = @{ +eval { $json->decode($1) } or next };
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
    my @lines;
    while ($$buffer =~ s/^(.*)\r*\n+//) {
        push @lines, $1;
    }
    unfortunately '[', $branch->pid, '] ', join "\n", @lines;
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

sub valid_nick {
    return shift() =~ m/^[A-Za-z_`\-^\|\\\{}\[\]][A-Za-z_0-9`\-^\|\\\{}\[\]]*$/;
}
