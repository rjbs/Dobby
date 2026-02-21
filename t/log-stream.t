use v5.36.0;
use utf8;

use Test::More;
use Dobby::Boxmate::LogStream;

my sub cb { Dobby::Boxmate::LogStream->new_logstream_cb }

# Capture everything printed to STDOUT by $code and return it as a list of
# lines (trailing newlines stripped, trailing empty entry dropped).
sub lines_from ($code) {
  my $buf = '';
  open my $fh, '>', \$buf or die "open: $!";
  binmode $fh, ':utf8';
  local *STDOUT = $fh;
  $code->();
  utf8::decode($buf);
  my @lines = split /\n/, $buf;
  return @lines;
}

# ── pass-through mode (no active task) ───────────────────────────────────────

subtest "data lines pass through when no task is active" => sub {
  my $cb = cb();
  my @lines = lines_from(sub {
    $cb->("line one\n");
    $cb->("line two\n");
    $cb->(undef, 1);
  });
  is_deeply \@lines,
    ["\x{26a0}\x{fe0f} Now receiving streamed logs...", 'line one', 'line two'],
    'lines preceded by one-time header';
};

subtest "header only prints once, before the first directive" => sub {
  my $cb = cb();
  my @lines = lines_from(sub {
    $cb->("first line\n");
    $cb->("second line\n");
    $cb->(undef, 1);
  });
  is scalar(grep { /receiving/ } @lines), 1, 'header appears exactly once';
  is $lines[0], "\x{26a0}\x{fe0f} Now receiving streamed logs...", 'header is first';
};

subtest "header not printed after a directive has been seen" => sub {
  my $cb = cb();
  my @lines = lines_from(sub {
    $cb->("BOX::START::step one\n");
    $cb->("BOX::FINISH\n");
    $cb->("post-finish data\n");
    $cb->(undef, 1);
  });
  ok !grep({ /receiving/ } @lines), 'no header after a directive was seen';
};

subtest "success with no task produces no output" => sub {
  my $cb = cb();
  my @lines = lines_from(sub { $cb->(undef, 1) });
  is scalar @lines, 0, 'nothing printed';
};

subtest "failure with no task emits EOS failure message" => sub {
  my $cb = cb();
  my @lines = lines_from(sub { $cb->(undef, 0) });
  is_deeply \@lines, ["\x{274c} Failed: process failure"];
};

# ── single task, success ──────────────────────────────────────────────────────

subtest "START then success EOS" => sub {
  my $cb = cb();
  my @lines = lines_from(sub {
    $cb->("BOX::START::install packages\n");
    $cb->(undef, 1);
  });
  is scalar @lines, 2, 'exactly two output lines';
  is   $lines[0], "\x{23f3} Currently: install packages",                'currently line';
  like $lines[1], qr/\A\x{2705} Completed: install packages \(\d+s\)\z/, 'completed line';
};

subtest "data lines during a task are buffered, not printed" => sub {
  my $cb = cb();
  my @lines = lines_from(sub {
    $cb->("BOX::START::do stuff\n");
    $cb->("secret output 1\n");
    $cb->("secret output 2\n");
    $cb->(undef, 1);
  });
  ok !grep({ /secret/ } @lines), 'buffered lines absent from output on success';
  is scalar @lines, 2, 'only currently + completed';
};

# ── BOX::ERROR ────────────────────────────────────────────────────────────────

subtest "ERROR flushes buffer indented, prints error line, task stays active" => sub {
  my $cb = cb();
  my @lines = lines_from(sub {
    $cb->("BOX::START::configure samba\n");
    $cb->("samba error output\n");
    $cb->("BOX::ERROR::connection refused\n");
    $cb->(undef, 1);
  });
  # [0] Currently: configure samba
  # [1]     samba error output        (indented)
  # [2]     ❌ connection refused     (indented error)
  # [3] Currently: configure samba    (re-shown after error)
  # [4] ✴️ Completed: ... with errors
  is scalar @lines, 5, 'five output lines';
  is   $lines[0], "\x{23f3} Currently: configure samba",                  'currently line';
  is   $lines[1], '    samba error output',                               'buffered line indented';
  is   $lines[2], "    \x{274c} connection refused",                      'error line indented';
  is   $lines[3], "\x{23f3} Currently: configure samba",                  'currently re-shown';
  like   $lines[4], qr/\A\x{2734}/,                                       'starts with eight-pointed star';
  like   $lines[4], qr/Completed: configure samba \(\d+s\) with errors\z/, 'completed with errors';
};

subtest "ERROR with empty buffer just prints the error line" => sub {
  my $cb = cb();
  my @lines = lines_from(sub {
    $cb->("BOX::START::step\n");
    $cb->("BOX::ERROR::something bad\n");
    $cb->(undef, 1);
  });
  is scalar @lines, 4;
  is   $lines[0], "\x{23f3} Currently: step";
  is   $lines[1], "    \x{274c} something bad",       'error line, no preceding buffer';
  is   $lines[2], "\x{23f3} Currently: step";
  like $lines[3], qr/with errors\z/,                  'completed with errors';
};

subtest "multiple buffered lines all printed in order on ERROR" => sub {
  my $cb = cb();
  my @lines = lines_from(sub {
    $cb->("BOX::START::frobulate\n");
    $cb->("first\n");
    $cb->("second\n");
    $cb->("third\n");
    $cb->("BOX::ERROR::it broke\n");
    $cb->(undef, 1);
  });
  is   $lines[1], '    first';
  is   $lines[2], '    second';
  is   $lines[3], '    third';
  is   $lines[4], "    \x{274c} it broke";
};

subtest "buffer is cleared after ERROR; subsequent data is re-buffered" => sub {
  my $cb = cb();
  my @lines = lines_from(sub {
    $cb->("BOX::START::work\n");
    $cb->("before error\n");
    $cb->("BOX::ERROR::oops\n");
    $cb->("after error\n");
    $cb->(undef, 1);
  });
  ok !grep({ /after error/ } @lines), 'post-error buffered line not printed on success';
};

# ── BOX::FINISH ───────────────────────────────────────────────────────────────

subtest "FINISH completes the current task" => sub {
  my $cb = cb();
  my @lines = lines_from(sub {
    $cb->("BOX::START::do thing\n");
    $cb->("BOX::FINISH\n");
    $cb->(undef, 1);
  });
  is scalar @lines, 2;
  is   $lines[0], "\x{23f3} Currently: do thing",                   'currently line';
  like $lines[1], qr/\A\x{2705} Completed: do thing \(\d+s\)\z/,   'completed line';
};

subtest "data lines pass through after FINISH" => sub {
  my $cb = cb();
  my @lines = lines_from(sub {
    $cb->("BOX::START::do thing\n");
    $cb->("BOX::FINISH\n");
    $cb->("post-finish line\n");
    $cb->(undef, 1);
  });
  is scalar @lines, 3;
  is $lines[2], 'post-finish line', 'line passes through without header';
};

subtest "FINISH after ERROR uses star and 'with errors' suffix" => sub {
  my $cb = cb();
  my @lines = lines_from(sub {
    $cb->("BOX::START::deploy\n");
    $cb->("BOX::ERROR::hiccup\n");
    $cb->("BOX::FINISH\n");
  });
  like $lines[-1], qr/\A\x{2734}/;
  like $lines[-1], qr/Completed: deploy \(\d+s\) with errors\z/;
};

# ── unexpected directives in NoTask ──────────────────────────────────────────

subtest "ERROR in NoTask emits cross and message, no header" => sub {
  my $cb = cb();
  my @lines = lines_from(sub {
    $cb->("BOX::ERROR::something went wrong\n");
    $cb->(undef, 1);
  });
  is scalar @lines, 1;
  is $lines[0], "\x{274c} something went wrong", 'cross and message, no indent';
};

subtest "FINISH in NoTask emits interrobang message" => sub {
  my $cb = cb();
  my @lines = lines_from(sub {
    $cb->("BOX::FINISH\n");
    $cb->(undef, 1);
  });
  is scalar @lines, 1;
  is $lines[0], "\x{2049}\x{fe0f} Unexpected task completion event";
};

# ── implicit completion via START ─────────────────────────────────────────────

subtest "second START implicitly completes the first task" => sub {
  my $cb = cb();
  my @lines = lines_from(sub {
    $cb->("BOX::START::task one\n");
    $cb->("BOX::START::task two\n");
    $cb->(undef, 1);
  });
  is scalar @lines, 4, 'four output lines';
  is   $lines[0], "\x{23f3} Currently: task one",                          'currently task one';
  like $lines[1], qr/\A\x{2705} Completed: task one \(\d+s\)\z/,           'completed task one';
  is   $lines[2], "\x{23f3} Currently: task two",                          'currently task two';
  like $lines[3], qr/\A\x{2705} Completed: task two \(\d+s\)\z/,           'completed task two';
};

subtest "implicit completion via START also honours had_error" => sub {
  my $cb = cb();
  my @lines = lines_from(sub {
    $cb->("BOX::START::task one\n");
    $cb->("BOX::ERROR::oops\n");
    $cb->("BOX::START::task two\n");
    $cb->(undef, 1);
  });
  like $lines[-3], qr/\A\x{2734}/,                                       'task one starts with eight-pointed star';
  like $lines[-3], qr/Completed: task one \(\d+s\) with errors\z/,       'task one implicitly completed with errors';
  like $lines[-1], qr/\A\x{2705} Completed: task two \(\d+s\)\z/,
    'task two completed cleanly';
};

# ── failed EOS ────────────────────────────────────────────────────────────────

subtest "failed EOS with running task dumps buffer and uses task name" => sub {
  my $cb = cb();
  my @lines = lines_from(sub {
    $cb->("BOX::START::important step\n");
    $cb->("accumulated output\n");
    $cb->(undef, 0);
  });
  is scalar @lines, 3;
  is $lines[0], "\x{23f3} Currently: important step", 'currently message present';
  is $lines[1], 'accumulated output',                  'buffer dumped on EOS failure';
  is $lines[2], "\x{274c} Failed: important step",     'task name used, no duration';
};

done_testing;
