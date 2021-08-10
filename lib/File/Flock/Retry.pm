package File::Flock::Retry;

# AUTHORITY
# DATE
# DIST
# VERSION

use 5.010001;
use strict;
use warnings;

use Fcntl ':DEFAULT', ':flock';

sub lock {
    my ($class, $path, $opts) = @_;
    $opts //= {};
    my %h;

    defined($path) or die "Please specify path";
    $h{path}    = $path;
    $h{retries} = $opts->{retries} // 60;
    $h{shared}  = $opts->{shared} // 0;
    $h{mode}    = $opts->{mode} // (O_CREAT | O_RDWR);

    my $self = bless \%h, $class;
    $self->_lock;
    $self;
}

# return 1 if we lock, 0 if already locked. die on failure.
sub _lock {
    my $self = shift;

    # already locked
    return 0 if $self->{_fh};

    my $path = $self->{path};
    my $existed = -f $path;
    my $exists;
    my $tries = 0;
  TRY:
    while (1) {
        $tries++;

        # 1
        sysopen $self->{_fh}, $path, $self->{mode}
            or die "Can't open lock file '$path': $!";

        # 2
        my @st1 = stat($self->{_fh}); # stat before lock

        # 3
        if (flock($self->{_fh}, ($self->{shared} ? LOCK_SH : LOCK_EX) | LOCK_NB)) {
            # if file is unlinked by another process between 1 & 2, @st1 will be
            # empty and we check here.
            redo TRY unless @st1;

            # 4
            my @st2 = stat($path); # stat after lock

            # if file is unlinked between 3 & 4, @st2 will be empty and we check
            # here.
            redo TRY unless @st2;

            # if file is recreated between 2 & 4, @st1 and @st2 will differ in
            # dev/inode, we check here.
            redo TRY if $st1[0] != $st2[0] || $st1[1] != $st2[1];

            # everything seems okay
            last;
        } else {
            $tries <= $self->{retries}
                or die "Can't acquire lock on '$path' after $tries seconds";
            sleep 1;
        }
    }
    $self->{_acquired} = 1;
    1;
}

# return 1 if we unlock, 0 if already unlocked. die on failure.
sub _unlock {
    my ($self) = @_;

    my $path = $self->{path};

    # don't unlock if we are not holding the lock
    return 0 unless $self->{_fh};

    unlink $self->{path} if $self->{_acquired} && !(-s $self->{path});

    {
        # to shut up warning about flock on closed filehandle (XXX but why
        # closed if we are holding the lock?)
        no warnings;

        flock $self->{_fh}, LOCK_UN;
    }
    close delete($self->{_fh});
    1;
}

sub release {
    my $self = shift;
    $self->_unlock;
}

sub unlock {
    my $self = shift;
    $self->_unlock;
}

sub handle {
    my $self = shift;
    $self->{_fh};
}

sub DESTROY {
    my $self = shift;
    $self->_unlock;
}

1;
#ABSTRACT: Yet another flock module

=for Pod::Coverage ^(DESTROY)$

=head1 SYNOPSIS

 use File::Flock::Retry;

 # try to acquire exclusive lock. if fail to acquire lock within 60s, die.
 my $lock = File::Flock::Retry->lock($file);

 # explicitly unlock
 $lock->release;

 # automatically unlock if object is DESTROY-ed.
 undef $lock;


=head1 DESCRIPTION

This is yet another flock module. It is a more lightweight alternative to
L<File::Flock> with some other differences:

=over 4

=item * OO interface only

=item * Autoretry (by default for 60s) when trying to acquire lock

I prefer this approach to blocking/waiting indefinitely or failing immediately.

=back


=head1 METHODS

=head2 lock

Usage:

 $lock = File::Flock::Retry->lock($path, \%opts)

Attempt to acquire an exclusive lock on C<$path>. By default, C<$path> will be
created if not already exists (see L</mode>). If C<$path> is already locked by
another process, will retry every second for a number of seconds (by default
60). Will die if failed to acquire lock after all retries.

Will automatically unlock if C<$lock> goes out of scope. Upon unlock, will
remove C<$path> if it is still empty (zero-sized).

Available options:

=over

=item * mode

Integer. Default: O_CREAT | O_RDWR.

File open mode, to be passed to Perl's C<sysopen()>. For example, if you want to
avoid race condition between creating and locking the file, you might want to
use C<< O_CREAT | O_EXCL | O_RDWR >> to fail when the file already exists. Note
that the constants are available after you do a C<< use Fcntl ':DEFAULT'; >>.

=item * retries

Integer. Default: 60.

Number of retries (equals number of seconds, since retry is done every second).

=item * shared

Boolean. Default: 0.

By default, an exclusive lock (LOCK_EX) is attempted. However, if this option is
set to true, a shared lock (LOCK_SH) is attempted.

=back

=head2 unlock

Usage:

 $lock->unlock

Unlock. will remove lock file if it is still empty.

=head2 release

Usage:

 $lock->release

Synonym for L</unlock>.

=head2 handle

Usage:

 my $fh = $lock->handle;

Return the file handle.


=head1 CAVEATS

Not yet tested on Windows. Some filesystems do not support inode?


=head1 SEE ALSO

L<File::Flock>, a bit too heavy in terms of dependencies and startup overhead,
for my taste. It depends on things like L<File::Slurp> and
L<Data::Structure::Util> (which loads L<Digest::MD5>, L<Storable>, among
others).

L<File::Flock::Tiny> which is also tiny, but does not have the autoremove and
autoretry capability which I want. See also:
L<https://github.com/trinitum/perl-File-Flock-Tiny/issues/1>

flock() Perl function.

An alternative to flock() is just using sysopen() with O_CREAT|O_EXCL mode to
create lock files. This is supported on more filesystems (particularly network
filesystems which lack flock()).

=cut
