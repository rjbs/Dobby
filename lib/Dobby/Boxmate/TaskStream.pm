package Dobby::Boxmate::TaskStream;
# ABSTRACT: handler for a lightweight output-annotating protocol

use v5.36.0;
use utf8;

use Time::Duration ();

my $WARNING   = "\x{26a0}\x{fe0f}";
my $CROSS     = "\x{274c}";
my $WEIRD     = "\x{2049}\x{fe0f}";
my $HOURGLASS = "\x{23f3}";
my $CHECK     = "\x{2705}";
my $STAR      = "\x{2734}\x{fe0f}";

my sub _fmt_dur ($secs) {
  Time::Duration::concise(
    Time::Duration::duration($secs, 3)
  )
}

=head1 OVERVIEW

When a box is being set up, the remote C<fmdev mysetup> script can emit
directives mixed in with ordinary output lines.  This module provides a
C<new_taskstream_cb> method, which returns a stateful callback suitable for use
as a C<taskstream_cb> on L<Dobby::BoxManager>.  The callback interprets the
directives and displays concise task-progress lines in place of the raw output
stream.

To get a callback:

  my $code = Dobby::Boxmate::TaskStream->new_taskstream_cb(\%arg);

The only meaningful argument to pass is:

  loop - an IO::Async::Loop to attach to

=head2 The Protocol

The TaskStream protocol is line-oriented.  Each line is either a directive or a
data line.  A directive is a line in one of these formats:

  TASK::START::$task_name
  TASK::ERROR::$message
  TASK::FINISH

The stream reader is always in one of two states: I<in-task> or I<no-task>.

=over 4

=item *

C<TASK::START> implicitly completes the previous task (if any), then announces
the new one.  Data lines received while a task is active are buffered
silently.

=item *

C<TASK::ERROR> reports a non-fatal error within the current task.  The buffered
data is flushed (indented), followed by an error indicator.  The task remains
active.

=item *

C<TASK::FINISH> successfully completes the current task without starting a new
one.  Subsequent data lines are passed straight through.

=item *

In the I<no-task> state, data lines are passed through without buffering.

=back

=cut

sub new_taskstream_cb ($class, $arg = undef) {
  $arg //= {};

  my $loop     = $arg->{loop};
  my $animated = $loop && -t STDOUT;

  my $state = Dobby::Boxmate::TaskStream::NoTask->new({
    loop              => $loop,
    animated          => $animated,
    prelude_permitted => 1,
  });

  return sub ($line, $success = undef) {
    unless (defined $line) {
      $state->on_eos($success);
      return;
    }

    $state = $state->on_line($line);
  };
}

package Dobby::Boxmate::TaskStream::_State {
  sub new ($class, $args) {
    return bless { loop => $args->{loop}, animated => $args->{animated} }, $class;
  }

  sub _clear_line ($self) {
    print "\r\e[K" if $self->{animated};
  }

  sub _new_in_task ($self, $name) {
    return Dobby::Boxmate::TaskStream::InTask->new({
      name     => $name,
      loop     => $self->{loop},
      animated => $self->{animated},
    });
  }

  sub _new_no_task ($self) {
    return Dobby::Boxmate::TaskStream::NoTask->new({
      loop              => $self->{loop},
      animated          => $self->{animated},
      prelude_permitted => 0,
    });
  }
}

package Dobby::Boxmate::TaskStream::NoTask {
  use parent -norequire, 'Dobby::Boxmate::TaskStream::_State';

  sub new ($class, $args) {
    my $self = $class->SUPER::new($args);
    $self->{prelude_permitted} = $args->{prelude_permitted};
    return $self;
  }

  sub on_line ($self, $line) {
    if ($line =~ /\ATASK::START::(.+)\Z/) {
      return $self->_new_in_task($1);
    }

    if ($line =~ /\ATASK::ERROR::(.+)\Z/) {
      say "$CROSS $1";
      return $self;
    }

    if ($line =~ /\ATASK::FINISH\Z/) {
      say "$WEIRD Unexpected task completion event";
      return $self;
    }

    if ($self->{prelude_permitted}) {
      say "$WARNING Now receiving streamed logs...";
      $self->{prelude_permitted} = 0;
    }

    print $line;
    return $self;
  }

  sub on_eos ($self, $success) {
    say "$CROSS Failed: process failure" unless $success;
  }
}

# InTask: a task is active
package Dobby::Boxmate::TaskStream::InTask {
  use parent -norequire, 'Dobby::Boxmate::TaskStream::_State';

  sub new ($class, $args) {
    my $self = {
      loop      => $args->{loop},
      animated  => $args->{animated},
      name      => $args->{name},
      start     => time,
      had_error => 0,
      buffer    => '',
      timer     => undef,
    };

    bless $self, $class;

    if ($self->{animated}) {
      print "$HOURGLASS Currently: $self->{name} (0s)";
      $self->_start_timer;
    } else {
      say "$HOURGLASS Currently: $self->{name}";
    }

    return $self;
  }

  sub _start_timer ($self) {
    require IO::Async::Timer::Periodic;
    $self->{timer} = IO::Async::Timer::Periodic->new(
      interval => 1,
      on_tick  => sub {
        my $dur = _fmt_dur(time - $self->{start});
        print "\r\e[K$HOURGLASS Currently: $self->{name} ($dur)";
      },
    );
    $self->{loop}->add($self->{timer});
    $self->{timer}->start;
  }

  sub _cancel_timer ($self) {
    return unless $self->{timer};
    $self->{timer}->stop;
    $self->{loop}->remove($self->{timer});
    $self->{timer} = undef;
  }

  sub _do_finish ($self) {
    my $dur    = _fmt_dur(time - $self->{start});
    my $mark   = $self->{had_error} ? $STAR : $CHECK;
    my $suffix = $self->{had_error} ? ' with errors' : '';
    $self->_cancel_timer;
    $self->_clear_line;
    say "$mark Completed: $self->{name} ($dur)$suffix";
  }

  sub _do_error ($self, $message) {
    print "\n" if $self->{animated};

    if (length $self->{buffer}) {
      (my $indented = $self->{buffer}) =~ s/^/    /mg;
      print $indented;
    }

    say "    $CROSS $message";

    $self->{buffer}    = '';
    $self->{had_error} = 1;

    if ($self->{animated}) {
      my $dur = _fmt_dur(time - $self->{start});
      print "$HOURGLASS Currently: $self->{name} ($dur)";
      return;
    }

    say "$HOURGLASS Currently: $self->{name}";
  }

  sub on_line ($self, $line) {
    if ($line =~ /\ATASK::START::(.+)\Z/) {
      $self->_do_finish;
      return $self->_new_in_task($1);
    }

    if ($line =~ /\ATASK::ERROR::(.+)\Z/) {
      $self->_do_error($1);
      return $self;
    }

    if ($line =~ /\ATASK::FINISH\Z/) {
      $self->_do_finish;
      return $self->_new_no_task;
    }

    $self->{buffer} .= $line;
    return $self;
  }

  sub on_eos ($self, $success) {
    if ($success) {
      $self->_do_finish;
    } else {
      $self->_cancel_timer;
      $self->_clear_line;
      print $self->{buffer} if length $self->{buffer};
      say "$CROSS Failed: $self->{name}";
    }
  }
}

1;
