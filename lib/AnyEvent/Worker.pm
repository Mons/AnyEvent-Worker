package AnyEvent::Worker;

use common::sense 2;m{
use warnings;
use strict;
}x;
=head1 NAME

AnyEvent::Worker - The great new AnyEvent::Worker!

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

=head1 SYNOPSIS

    use AnyEvent 5;
    use AnyEvent::Worker;
    
    my $worker1 = AnyEvent::Worker->new( [ 'Actual::Worker::Class' => @init_args ] );
    my $worker2 = AnyEvent::Worker->new( sub { return "Cb 1 @_"; } );
    
    # Invoke method `test' on Actual::Worker::Class with arguments @args
    $worker1->do( test => @args , sub {
        return warn "Request died: $@" if $@;
        warn "Received response: @_";
    });
    
    # Just call callback, passed to worker2 with arguments @args
    $worker2->do( @args , sub {
        return warn "Request died: $@" if $@;
        warn "Received response: @_";
    });

=cut

use Carp;
use Socket ();
use Scalar::Util ();
use Storable ();

use AnyEvent ();
use AnyEvent::Util ();

use Errno ();
use Fcntl ();
use POSIX ();

our $VERSION = '0.01';
our $FD_MAX = eval { POSIX::sysconf (&POSIX::_SC_OPEN_MAX) - 1 } || 1023;

# Almost fully derived from AnyEvent::DBI

our $WORKER;

sub serve_fh($$) {
	my ($fh, $version) = @_;

	if ($VERSION != $version) {
		syswrite $fh,
			pack "L/a*",
				Storable::freeze
					[undef, __PACKAGE__." version mismatch ($VERSION vs. $version)"];
		return;
	}
	
	eval {
		my $rbuf;
		my $name = ref $WORKER eq 'CODE' ? __PACKAGE__ : ref $WORKER;
		$0 .= ' - '.$name;
		my $O = $0;
		my $N = 0;
		while () {
			sysread $fh, $rbuf, 16384, length $rbuf
				or last;
			
			while () {
				my $len = unpack "L", $rbuf;
				
				# full request available?
				last unless $len && $len + 4 <= length $rbuf;
				
				my $req = Storable::thaw substr $rbuf, 4;
				substr $rbuf, 0, $len + 4, ""; # remove length + request
				my $wbuf = eval {
					++$N;
					if (ref $WORKER eq 'CODE') {
						local $0 = "$O : request $N";
						pack "L/a*", Storable::freeze [ 1, $WORKER->(@$req) ];
					} else {
						my $method = shift @$req;
						#warn ">> request $method";
						local $0 = "$O : request $N : $method";
						pack "L/a*", Storable::freeze [ 1, $WORKER->$method(@$req) ];
					}
				};
				$0 = "$O : idle";
				$wbuf = pack "L/a*", Storable::freeze [ undef, ref $@ ? ("$@->[0]", $@->[1]) : ("$@", 0) ]
					if $@;
				
				#warn "<< response";
				for (my $ofs = 0; $ofs < length $wbuf; ) {
					$ofs += (my $wr = syswrite $fh, substr $wbuf, $ofs
									or die "unable to write results");
				}
			}
		}
	};
	warn if $@;
}

sub serve_fd($$) {
	open my $fh, ">>&=$_[0]"
		or die "Couldn't open server file descriptor: $!";

	serve_fh $fh, $_[1];
}

# stupid Storable autoloading, total loss-loss situation
Storable::thaw Storable::freeze [];

=head1 METHODS

=over 4

=cut

sub new {
	my ($class, $cb, %arg) = @_;
	
	my ($client, $server) = AnyEvent::Util::portable_socketpair
		or croak "unable to create Anyevent::DBI communications pipe: $!";
	
	my %dbi_args = %arg;
	delete @dbi_args{qw(on_connect on_error timeout exec_server)};
	
	my $self = bless \%arg, $class;
	$self->{fh} = $client;
	
	AnyEvent::Util::fh_nonblocking $client, 1;
	
	my $rbuf;
	my @caller = (caller)[1,2]; # the "default" caller
	
	{
		Scalar::Util::weaken (my $self = $self);
		
		$self->{rw} = AnyEvent->io (fh => $client, poll => "r", cb => sub {
			return unless $self;
			
			$self->{last_activity} = AnyEvent->now;
			
			my $len = sysread $client, $rbuf, 65536, length $rbuf;
			
			if ($len > 0) {
				# we received data, so reset the timer
				
				while () {
					my $len = unpack "L", $rbuf;
					
					# full response available?
					last unless $len && $len + 4 <= length $rbuf;
					my $res = Storable::thaw substr $rbuf, 4;
					substr $rbuf, 0, $len + 4, ""; # remove length + request
					
					last unless $self;
					my $req = shift @{ $self->{queue} };
					
					if (defined $res->[0]) {
						$res->[0] = $self;
						$req->[0](@$res);
					} else {
						my $cb = shift @$req;
						local $@ = $res->[1];
						$@ =~ s{\n$}{};
						$cb->($self);
						$self->_error ($res->[1], @$req, $res->[2]) # error, request record, is_fatal
							if $self; # cb() could have deleted it
					}
					
					# no more queued requests, so become idle
					undef $self->{last_activity}
						if $self && !@{ $self->{queue} };
				}
			
			} elsif (defined $len) {
				# todo, caller?
				$self->_error ("unexpected eof", @caller, 1);
			} elsif ($! != Errno::EAGAIN) {
				# todo, caller?
				$self->_error ("read error: $!", @caller, 1);
			}
		});
		
		$self->{tw_cb} = sub {
			if ($self->{timeout} && $self->{last_activity}) {
				if (AnyEvent->now > $self->{last_activity} + $self->{timeout}) {
					# we did time out
					my $req = $self->{queue}[0];
					$self->_error (timeout => $req->[1], $req->[2], 1); # timeouts are always fatal
				} else {
					# we need to re-set the timeout watcher
					$self->{tw} = AnyEvent->timer (
						after => $self->{last_activity} + $self->{timeout} - AnyEvent->now,
						cb    => $self->{tw_cb},
					);
					Scalar::Util::weaken $self;
				}
			} else {
				# no timeout check wanted, or idle
				undef $self->{tw};
			}
		};
		
		$self->{ww_cb} = sub {
			return unless $self;
			
			$self->{last_activity} = AnyEvent->now;
			
			my $len = syswrite $client, $self->{wbuf}
				or return delete $self->{ww};
			
			substr $self->{wbuf}, 0, $len, "";
		};
	}
	
	my $pid = fork;
	
	if ($pid) {
		# parent
		close $server;
	}
	elsif (defined $pid) {
		# child
		if (ref $cb eq 'CODE'){
			$WORKER = $cb;
		}
		elsif ( ref $cb eq 'ARRAY') {
			my ( $class,@args ) = @$cb;
			eval qq{ use $class; 1 } or die $@ unless $class->can('new');
			$WORKER = $class->new(@args);
		}
		my $serv_fno = fileno $server;
		
		($_ != $serv_fno) && POSIX::close $_
			for $^F+1..$FD_MAX;
		serve_fh $server, $VERSION;
		
		# no other way on the broken windows platform, even this leaks
		# memory and might fail.
		kill 9, $$ if AnyEvent::WIN32;
		
		# and this kills the parent process on windows
		POSIX::_exit 0;
	}
	else {
		croak "fork: $!";
	}
	$self->{child_pid} = $pid;
	$self
}

sub _server_pid {
	shift->{child_pid}
}

our %TERM;

sub kill_child {
	my $self      = shift;
	my $child_pid = delete $self->{child_pid};
	#print STDERR "killing $child_pid\n";
	if ($child_pid) {
		# send SIGKILL in two seconds
		$TERM{$child_pid}++;
		# TODO: kill timer
		my $murder_timer = AnyEvent->timer (
			after => 2,
			cb    => sub {
				kill 9, $child_pid
					and delete $TERM{$child_pid};
			},
		);
		
		# reap process
		my $kid_watcher; $kid_watcher = AnyEvent->child (
			pid => $child_pid,
			cb  => sub {
				# just hold on to this so it won't go away
				delete $TERM{$child_pid};
				undef $kid_watcher;
				# cancel SIGKILL
				undef $murder_timer;
			},
		);
		
		close $self->{fh};
	}
}

sub END {
	for (keys %TERM) {
		#print STDERR "END: kill $_\n";
		# TODO: waitpid
		kill KILL => $_ or warn "kill $_ failed: $!";
	}
}

sub DESTROY {
	shift->kill_child;
}

sub _error {
	my ($self, $error, $filename, $line, $fatal) = @_;
	if ($fatal) {
		delete $self->{tw};
		delete $self->{rw};
		delete $self->{ww};
		delete $self->{fh};
		
		# for fatal errors call all enqueued callbacks with error
		while (my $req = shift @{$self->{queue}}) {
			local $@ = $error;
			$req->[0]->($self);
		}
		$self->kill_child;
	}
	
	local $@ = $error;
	
	if ($self->{on_error}) {
		$self->{on_error}($self, $filename, $line, $fatal)
	} else {
		die "$error at $filename, line $line\n";
	}
}

=item $worker->on_error ($cb->($worker, $filename, $line, $fatal))

Sets (or clears, with C<undef>) the C<on_error> handler.

=cut

sub on_error {
	$_[0]{on_error} = $_[1];
}

=item $worker->timeout ($seconds)

Sets (or clears, with C<undef>) the database timeout. Useful to extend the
timeout when you are about to make a really long query.

=cut

sub timeout {
	my ($self, $timeout) = @_;
	
	$self->{timeout} = $timeout;
	
	# reschedule timer if one was running
	$self->{tw_cb}->();
}

=item $worker->do ( @args, $cb->( $worker, @response ) )

Executes worker code and execure the callback, when response is ready

=cut

sub do {
	my $self = shift;
	my $cb = pop;
	my ($filename,$line) = (caller)[1,2];
	
	unless ($self->{fh}) {
		local $@ = my $err = 'no worker connection';
		$cb->($self);
		$self->_error ($err, $filename, $line, 1);
		return;
	}
	
	push @{ $self->{queue} }, [$cb, $filename, $line];
	
	# re-start timeout if necessary
	if ($self->{timeout} && !$self->{tw}) {
		$self->{last_activity} = AnyEvent->now;
		$self->{tw_cb}->();
	}
	
	$self->{wbuf} .= pack "L/a*", Storable::freeze \@_;
	
	unless ($self->{ww}) {
		my $len = syswrite $self->{fh}, $self->{wbuf};
		substr $self->{wbuf}, 0, $len, "";
		
		# still any left? then install a write watcher
		$self->{ww} = AnyEvent->io (fh => $self->{fh}, poll => "w", cb => $self->{ww_cb})
			if length $self->{wbuf};
	}
}

=back

=head1 AUTHOR

Mons Anderson, C<< <mons at cpan.org> >>

=head1 COPYRIGHT & LICENSE

Copyright 2009 Mons Anderson, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

1; # End of AnyEvent::Worker
