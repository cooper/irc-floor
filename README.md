# floor

this is a Perl script to test the efficiency of an IRC server. it has an
interactive shell from which you can spawn clients and direct them to join
channels, change nicks, send messages, etc.

## this is not a botnet

this is not for actual spamming and I'm not just saying that because I think you
shouldn't use it that way. it will not be effective on any properly configured
IRC server with connection/IP limits.

## how to use

```sh
perl master.pl
```

### commands

available commands
```
--------------
|          ? | display this help text
|         ?@ | explain what each setting means
|          @ | display current configuration
|     create | create additional clients: [amount]
|      cycle | part and join IRC channel(s): [#channel] [part message]
|        irc | send raw data to all active connections
| nickchange | randomly change client nicknames: [times]
|        say | send a message to IRC channel(s): [#channel] message
|       show | show a status overview of current branches
|      spawn | spawn additional branch(es): [amount]
|    sysinfo | show information about the operating environment
|  wastenick | waste a nickname to test if the source is functioning
--------------
```


### configuration

change settings using the syntax `@name = value` syntax.
values are JSON-encoded.

type `@` to view current settings.

available settings
```
-----------------------
|            @address | str   address of the IRC server
|           @autojoin | list  channels to join automatically
| @clients_per_branch | int   connections to attempt on a single branch
| @connections_in_row | int   max of new connections per branch per second
|         @join_timer | int   how often to send JOINs to server (seconds)
|   @max_nicks_in_ram | int   number of nicknames to cache in memory
|      @pong_response | str   what to send as the parameter in PONGs
|         @pong_timer | int   how often to send PONGs to server (seconds)
|               @port | str   port of the IRC server
|      @spaced_output | bool  format table output in a more spaced layout
|          @word_list | str   path to dictionary file on the system
-----------------------
```
