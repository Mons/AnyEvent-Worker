package AnyEvent::Worker::Pool;

use common::sense 2;m{
use warnings;
use strict;
}x;

use AnyEvent::Worker;

sub new {
	my $pkg = shift;
	my $count = shift;
	my @args = @_;
	my $self = bless { @_ }, $pkg;
	$self->{pool} = [
		map { AnyEvent::Worker->new(@_) } 1..$count
	];
	return $self;
}

sub do {
	my $self = shift;
	my $cb = pop;
	my @args = @_;
	$self->take_worker(sub {
		my $worker = shift;
		$worker->do(@args, sub {
			$self->ret_worker($worker);
			goto &$cb;
		});
	});
	return;
}

sub take_worker {
	my $self = shift;
	my $cb = shift or die "cb required for take_worker at @{[(caller)[1,2]]}\n";
	#warn("take wrk, left ".$#{$self->{pool}}." for @{[(caller)[1,2]]}\n");
	if (@{$self->{pool}}) {
		$cb->(shift @{$self->{pool}});
	} else {
		#warn("no worker for @{[(caller 1)[1,2]]}, maybe increase pool?");
		push @{$self->{waiting_db}},$cb
	}
}

sub ret_worker {
	my $self = shift;
	#warn("ret wrk, got ".@{$self->{pool}}.'+'.@_." for @{[(caller)[1,2]]}\n");
	push @{ $self->{pool} }, @_;
	$self->take_worker(shift @{ $self->{waiting_db} }) if @{ $self->{waiting_db} };
}

1;
