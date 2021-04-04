package Net::Resolver::Timeout;
use strict;
use warnings;

our $VERSION = '0.001';

{
    package Net::Resolver::Timeout::Pipe;
    use Storable ();
    sub new {
        my ($class, %option) = @_;
        my $read_fh  = delete $option{read_fh}  or die;
        my $write_fh = delete $option{write_fh} or die;
        $write_fh->autoflush(1);
        bless { %option, read_fh => $read_fh, write_fh => $write_fh, buf => '' }, $class;
    }
    sub read :method {
        my $self = shift;
        my $_size = $self->_read(4) or return;
        my $size = unpack 'I', $_size;
        my $freezed = $self->_read($size);
        Storable::thaw($freezed);
    }
    sub write :method {
        my ($self, $data) = @_;
        my $freezed = Storable::freeze({data => $data});
        my $size = pack 'I', length($freezed);
        $self->_write("$size$freezed");
    }
    sub _read {
        my ($self, $size) = @_;
        my $fh = $self->{read_fh};
        my $offset = length $self->{buf};
        while ($offset < $size) {
            my $len = sysread $fh, $self->{buf}, 65536, $offset;
            if (!defined $len) {
                die $!;
            } elsif ($len == 0) {
                last;
            } else {
                $offset += $len;
            }
        }
        return substr $self->{buf}, 0, $size, '';
    }
    sub _write {
        my ($self, $data) = @_;
        my $fh = $self->{write_fh};
        my $size = length $data;
        my $offset = 0;
        while ($size) {
            my $len = syswrite $fh, $data, $size, $offset;
            if (!defined $len) {
                die $!;
            } elsif ($len == 0) {
                last;
            } else {
                $size   -= $len;
                $offset += $len;
            }
        }
        $size;
    }
}

{
    package Net::Resolver::Timeout::Backend;
    use Socket ();
    use Time::HiRes ();

    sub new {
        my $class = shift;
        bless {}, $class;
    }

    sub resolve {
        my ($self, $host, %argv) = @_;
        my @ip_string;
        for my $info ($self->resolve_addrinfo($host, %argv)) {
            my $family = $info->{family};
            my $addr = $info->{addr};
            my $unpack = $family == Socket::AF_INET ?
                \&Socket::unpack_sockaddr_in : \&Socket::unpack_sockaddr_in6;
            my $ip_binary = $unpack->($addr);
            my $ip_string = Socket::inet_ntop $family, $ip_binary;
            push @ip_string, $ip_string;
        }
        @ip_string;
    }

    sub resolve_addrinfo {
        my ($self, $host, %argv) = @_;
        $self->{error} = undef;
        my $service = "0";
        my %hint = (
            flags => Socket::AI_ADDRCONFIG,
            protocol => ($argv{protocol} || "tcp") eq "tcp" ? Socket::IPPROTO_TCP : Socket::IPPROTO_UDP,
            exists $argv{family}
                ? (family => $argv{family} eq "ipv4" ? Socket::AF_INET : Socket::AF_INET6)
                : (),
        );
        if ($argv{timeout}) {
            Time::HiRes::alarm $argv{timeout};
        }
        my ($err, @info) = Socket::getaddrinfo $host, $service, \%hint;
        if ($argv{timeout}) {
            Time::HiRes::alarm 0;
        }
        if ($err) {
            $self->{error} = $err;
            return;
        }
        @info;
    }

    my $REGEXP_IPv4_DECIMAL = qr/25[0-5]|2[0-4][0-9]|[0-1]?[0-9]{1,2}/;
    my $REGEXP_IPv4_DOTTEDQUAD = qr/$REGEXP_IPv4_DECIMAL\.$REGEXP_IPv4_DECIMAL\.$REGEXP_IPv4_DECIMAL\.$REGEXP_IPv4_DECIMAL/;

    sub reverse_resolve {
        my ($self, $ip_string, %argv) = @_;
        $self->{error} = undef;
        my $family = $ip_string =~ m/^$REGEXP_IPv4_DOTTEDQUAD$/ ?
            Socket::AF_INET : Socket::AF_INET6;
        my $port = $argv{port} || 0;
        my $ip_binary = Socket::inet_pton $family, $ip_string;
        my $pack = $family == Socket::AF_INET ?
            \&Socket::pack_sockaddr_in : \&Socket::pack_sockaddr_in6;
        my $addr = $pack->($port, $ip_binary);
        my $flags = ($argv{protocol} || "tcp") eq "udp" ? Socket::NI_DGRAM : 0;
        my $xflags = Socket::NIx_NOSERV; # not interested in "service"
        if ($argv{timeout}) {
            Time::HiRes::alarm $argv{timeout};
        }
        my ($err, $host, undef) = Socket::getnameinfo $addr, $flags, $xflags;
        if ($argv{timeout}) {
            Time::HiRes::alarm 0;
        }
        if ($err) {
            $self->{error} = $err;
            return;
        }
        $host;
    }

    sub error {
        my $self = shift;
        $self->{error}
    }
}

use Config;
my $SIGALRM_NUM = do {
    my @sig = split /\s+/, $Config::Config{sig_name};
    my $num = -1;
    for my $i (0..$#sig) {
        if ($sig[$i] eq "ALRM") {
            $num = $i, last;
        }
    }
    $num;
};

sub new {
    my $class = shift;
    my $self = bless {}, $class;
    $self->_fork;
}

sub _fork {
    my $self = shift;
    $self->{pid} = -1;
    $self->{pipe} = undef;

    pipe my $read1, my $write1;
    pipe my $read2, my $write2;
    my $pid = fork // die;
    if ($pid) {
        close $read1;
        close $write2;
        my $pipe = Net::Resolver::Timeout::Pipe->new(read_fh => $read2, write_fh => $write1);
        $self->{pid} = $pid;
        $self->{pipe} = $pipe;
        return $self;
    }
    close $write1;
    close $read2;
    my $pipe = Net::Resolver::Timeout::Pipe->new(read_fh => $read1, write_fh => $write2);
    my $backend = Net::Resolver::Timeout::Backend->new;
    while (1) {
        my $data = $pipe->read;
        die if !$data;
        my $method = $data->{data}{method};
        if ($method eq "exit") {
            exit;
        }
        my @result;
        if ($method eq "resolve") {
            @result = $backend->resolve(@{$data->{data}{argv}});
        }
        if ($method eq "reverse_resolve") {
            $result[0] = $backend->reverse_resolve(@{$data->{data}{argv}});
        }
        my $error = $backend->error;
        $pipe->write({ result => \@result, error => $backend->error });
    }
}


sub resolve {
    my ($self, $host, %argv) = @_;
    $self->{pipe}->write({ method => "resolve", argv => [$host, %argv] });
    my $data = $self->{pipe}->read;
    if (!$data) {
        waitpid $self->{pid}, 0;
        if ( ($? & 127) != $SIGALRM_NUM ) {
            warn "sub process exits with unexpected status $?";
        }
        $self->{error} = "timeout";
        $self->_fork;
        return;
    }
    if (my $error = $data->{data}{error}) {
        $self->{error} = $error;
        return;
    }
    return @{$data->{data}{result}};
}

sub reverse_resolve {
    my ($self, $ip_string, %argv) = @_;
    $self->{pipe}->write({ method => "reverse_resolve", argv => [$ip_string, %argv] });
    my $data = $self->{pipe}->read;
    if (!$data) {
        waitpid $self->{pid}, 0;
        if ( ($? & 127) != $SIGALRM_NUM ) {
            warn "child process exits with unexpected status $?";
        }
        $self->{error} = "timeout";
        $self->_fork;
        return;
    }
    if (my $error = $data->{data}{error}) {
        $self->{error} = $error;
        return;
    }
    return $data->{data}{result}[0];
}

sub error {
    my $self = shift;
    $self->{error};
}

sub DESTROY {
    my $self = shift;
    return if !$self->{pipe};
    $self->{pipe}->write({ method => "exit" });
    waitpid $self->{pid}, 0;
}

1;
__END__

=encoding utf-8

=head1 NAME

Net::Resolver::Timeout - DNS resolver with timeout

=head1 SYNOPSIS

  use Net::Resolver::Timeout;

  my $resolver = Net::Resolver::Timeout->new;

  my @ip = $resolver->resolve("twitter.com", timeout => 1.5);
  my $host = $resolver->reverse_resolve("104.244.42.193", timeout => 1.5);

=head1 DESCRIPTION

Net::Resolver::Timeout is a wrapper around C<Socket::getaddrinfo> and C<Socket::getnameinfo>,
which allows you to specify timeout seconds.

=head1 WHY?

It is known that C<getaddrinfo(3)>/C<getnameinfo(3)> is a blocking operation, and there is no way to specify timeout.
Actually, in my environment, the call of C<Socket::getnameinfo> with twitter.com's IP C<104.244.42.193> always blocks my code.

To specify timeout, you might want to write code like:

  my ($err, $host);
  eval {
    local $SIG{ALRM} = sub { die "__TIMEOUT__\n" };
    alarm 1;
    ($err, $host) = getnameinfo "104.244.42.193", 0, NIx_NOSERV;
    alarm 0;
  };

Unfortunately, this code does not work, because perl signal handlers can not interrupt C function C<getnameinfo(3)>.

To avoid this limitation, C<Net::Resolver::Timeout> first spawns a child process.
And call C<Socket::getnameinfo>/C<Socket::getnameinfo> with C<alarm(2)> in the child process, I<without> perl-based signal handler
so that it gets C<SIGALRM> properly.

=head1 METHOD

=head2 new

Constructor.

  my $resolver = Net::Resolver::Timeout->new;

=head2 resolve

Resolve IP addresses from host.

  my @ip = $resolver->resolve($host, %argv);

Here C<%argv> may contain the following keys:

=over 4

=item timeout

Timeout seconds, eg: C<1>, C<2>, C<0.5>, C<1.5>.

=item protocol

Protocol, C<tcp> or C<udp>.

=item family

Address family, C<ipv4> or C<ipv6>

=back

=head2 reverse_resolve

Resolve host from IP address.

  my $host = $resolver->reverse_resolve($ip, %argv);

Here C<%argv> may contain the following keys:

=over 4

=item timeout

Timeout seconds, eg: C<1>, C<2>, C<0.5>, C<1.5>.

=item protocol

Protocol, C<tcp> or C<udp>.

=item port

Port number, eg: C<80>, C<443>

=back

=head1 SEE ALSO

L<Socket>

=head1 AUTHOR

Shoichi Kaji <skaji@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2021 Shoichi Kaji <skaji@cpan.org>

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
