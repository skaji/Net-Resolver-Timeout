[![Actions Status](https://github.com/skaji/Net-Resolver-Timeout/workflows/linux/badge.svg)](https://github.com/skaji/Net-Resolver-Timeout/actions)

# NAME

Net::Resolver::Timeout - DNS resolver with timeout

# SYNOPSIS

    use Net::Resolver::Timeout;

    my $resolver = Net::Resolver::Timeout->new;

    my @ip = $resolver->resolve("twitter.com", timeout => 1.5);
    my $host = $resolver->reverse_resolve("104.244.42.193", timeout => 1.5);

# DESCRIPTION

Net::Resolver::Timeout is a wrapper around `Socket::getaddrinfo` and `Socket::getnameinfo`,
which allows you to specify timeout seconds.

# WHY?

It is known that `getaddrinfo(3)`/`getnameinfo(3)` is a blocking operation, and there is no way to specify timeout.
Actually, in my environment, the call of `Socket::getnameinfo` with twitter.com's IP `104.244.42.193` always blocks my code.

To specify timeout, you might want to write code like:

    my ($err, $host);
    eval {
      local $SIG{ALRM} = sub { die "__TIMEOUT__\n" };
      alarm 1;
      ($err, $host) = getnameinfo "104.244.42.193", 0, NIx_NOSERV;
    };

Unfortunately, this code does not work, because perl signal handlers can not interrupt C function `getnameinfo(3)`.

To avoid this limitation, `Net::Resolver::Timeout` first spawns a child process.
And call `Socket::getnameinfo`/`Socket::getnameinfo` with `alarm(2)` in the child process, _without_ perl-based signal handler
so that it gets `SIGALRM` properly.

# SEE ALSO

[Socket](https://metacpan.org/pod/Socket)

# AUTHOR

Shoichi Kaji <skaji@cpan.org>

# COPYRIGHT AND LICENSE

Copyright 2021 Shoichi Kaji <skaji@cpan.org>

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.
