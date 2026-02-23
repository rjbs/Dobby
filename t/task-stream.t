use v5.36.0;
use utf8;

use Carp ();
use Dobby::Boxmate::TaskStream;
use Encode ();

use Test::More;
use Test::Deep;

my $WARNING   = "\x{26a0}\x{fe0f}";
my $CROSS     = "\x{274c}";
my $WEIRD     = "\x{2049}\x{fe0f}";
my $HOURGLASS = "\x{23f3}";
my $CHECK     = "\x{2705}";
my $STAR      = "\x{2734}\x{fe0f}";

# Capture everything printed to STDOUT by $code and return it as a list of
# lines (trailing newlines stripped, trailing empty entry dropped).
sub lines_from ($code) {
  my $buf = q{};
  open my $fh, '>', \$buf or die "open: $!";

  # I guess you can't apply :encoding(UTF-8) to scalar fh??
  binmode $fh, ':utf8';

  local *STDOUT = $fh;
  $code->();
  $buf = Encode::decode('utf-8', $buf);
  my @lines = split /\n/, $buf;
  return @lines;
}

# Feed @$input as lines to a fresh callback, then signal EOS with the last
# element (which must be 0 or 1), and compare the output to $test_deep_arg.
sub output_ok ($input, $test_deep_arg, $desc) {
  local $Test::Builder::Level = $Test::Builder::Level + 1;

  my @input_lines = @$input;
  my $success = pop @input_lines;

  Carp::croak("last element of output_ok input arrayref should be 0 or 1")
    unless defined $success && ($success eq 1 or $success eq 0);

  my $streamer = Dobby::Boxmate::TaskStream->new_taskstream_cb;

  my @lines = lines_from(sub {
    $streamer->("$_\n") for @input_lines;
    $streamer->(undef, $success);
  });

  cmp_deeply(\@lines, $test_deep_arg, $desc);
}

output_ok(
  ["line one", "line two", 1],
  ["$WARNING Now receiving streamed logs...", 'line one', 'line two'],
  'data lines pass through when no task is active',
);

output_ok(
  ["first line", "second line", 1],
  ["$WARNING Now receiving streamed logs...", 'first line', 'second line'],
  'header only prints once, before the first directive',
);

output_ok(
  ["TASK::START::step one", "TASK::FINISH", "post-finish data", 1],
  [
    "$HOURGLASS Currently: step one",
    re(qr/\A$CHECK Completed: step one \(\d+s\)\z/),
    'post-finish data',
  ],
  'header not printed after a directive has been seen',
);

output_ok([1], [], 'success with no task produces no output');

output_ok(
  [0],
  ["$CROSS Failed: process failure"],
  'failure with no task emits EOS failure message',
);

output_ok(
  ["TASK::START::install packages", 1],
  [
    "$HOURGLASS Currently: install packages",
    re(qr/\A$CHECK Completed: install packages \(\d+s\)\z/),
  ],
  'START then success EOS',
);

output_ok(
  ["TASK::START::do stuff", "secret output 1", "secret output 2", 1],
  [
    "$HOURGLASS Currently: do stuff",
    re(qr/\A$CHECK Completed: do stuff \(\d+s\)\z/),
  ],
  'data lines during a task are buffered, not printed',
);

output_ok(
  ["TASK::START::configure samba", "samba error output", "TASK::ERROR::connection refused", 1],
  [
    # [0] Currently: configure samba
    # [1]     samba error output        (indented)
    # [2]     ❌ connection refused     (indented error)
    # [3] Currently: configure samba    (re-shown after error)
    # [4] ✴️ Completed: ... with errors
    "$HOURGLASS Currently: configure samba",
    '    samba error output',
    "    $CROSS connection refused",
    "$HOURGLASS Currently: configure samba",
    re(qr/\A$STAR Completed: configure samba \(\d+s\) with errors\z/),
  ],
  'ERROR flushes buffer indented, prints error line, task stays active',
);

output_ok(
  ["TASK::START::step", "TASK::ERROR::something bad", 1],
  [
    "$HOURGLASS Currently: step",
    "    $CROSS something bad",
    "$HOURGLASS Currently: step",
    re(qr/with errors\z/),
  ],
  'ERROR with empty buffer just prints the error line',
);

output_ok(
  ["TASK::START::frobulate", "first", "second", "third", "TASK::ERROR::it broke", 1],
  [
    "$HOURGLASS Currently: frobulate",
    '    first',
    '    second',
    '    third',
    "    $CROSS it broke",
    "$HOURGLASS Currently: frobulate",
    re(qr/with errors\z/),
  ],
  'multiple buffered lines all printed in order on ERROR',
);

output_ok(
  ["TASK::START::work", "before error", "TASK::ERROR::oops", "after error", 1],
  [
    "$HOURGLASS Currently: work",
    '    before error',
    "    $CROSS oops",
    "$HOURGLASS Currently: work",
    re(qr/with errors\z/),
  ],
  'buffer is cleared after ERROR; subsequent data is re-buffered',
);

output_ok(
  ["TASK::START::do thing", "TASK::FINISH", 1],
  [
    "$HOURGLASS Currently: do thing",
    re(qr/\A$CHECK Completed: do thing \(\d+s\)\z/),
  ],
  'FINISH completes the current task',
);

output_ok(
  ["TASK::START::do thing", "TASK::FINISH", "post-finish line", 1],
  [
    "$HOURGLASS Currently: do thing",
    re(qr/\A$CHECK Completed: do thing \(\d+s\)\z/),
    'post-finish line',
  ],
  'data lines pass through after FINISH',
);

output_ok(
  ["TASK::START::deploy", "TASK::ERROR::hiccup", "TASK::FINISH", 1],
  [
    "$HOURGLASS Currently: deploy",
    "    $CROSS hiccup",
    "$HOURGLASS Currently: deploy",
    re(qr/\A$STAR Completed: deploy \(\d+s\) with errors\z/),
  ],
  "FINISH after ERROR uses star and 'with errors' suffix",
);

output_ok(
  ["TASK::ERROR::something went wrong", 1],
  ["$CROSS something went wrong"],
  'ERROR in NoTask emits cross and message, no header',
);

output_ok(
  ["TASK::FINISH", 1],
  ["$WEIRD Unexpected task completion event"],
  'FINISH in NoTask emits interrobang message',
);

output_ok(
  ["TASK::START::task one", "TASK::START::task two", 1],
  [
    "$HOURGLASS Currently: task one",
    re(qr/\A$CHECK Completed: task one \(\d+s\)\z/),
    "$HOURGLASS Currently: task two",
    re(qr/\A$CHECK Completed: task two \(\d+s\)\z/),
  ],
  'second START implicitly completes the first task',
);

output_ok(
  ["TASK::START::task one", "TASK::ERROR::oops", "TASK::START::task two", 1],
  [
    "$HOURGLASS Currently: task one",
    "    $CROSS oops",
    "$HOURGLASS Currently: task one",
    re(qr/\A$STAR Completed: task one \(\d+s\) with errors\z/),
    "$HOURGLASS Currently: task two",
    re(qr/\A$CHECK Completed: task two \(\d+s\)\z/),
  ],
  'implicit completion via START also honours had_error',
);

output_ok(
  ["TASK::START::important step", "accumulated output", 0],
  [
    "$HOURGLASS Currently: important step",
    'accumulated output',
    "$CROSS Failed: important step",
  ],
  'failed EOS with running task dumps buffer and uses task name',
);

done_testing;
