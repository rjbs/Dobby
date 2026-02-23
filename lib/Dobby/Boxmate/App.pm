package Dobby::Boxmate::App;
use App::Cmd::Setup -app => {};

# ABSTRACT: the App::Cmd that powers Dobby::Boxmate

use v5.36.0;
use utf8;

use Dobby::Boxmate::TaskStream;

sub config ($self) {
  return $self->{_config} if $self->{_config};

  require Dobby::Boxmate::Config;
  $self->{_config} //= Dobby::Boxmate::Config->load;
}

sub _loop ($self) {
  return $self->{_loop} if $self->{_loop};
  $self->{_loop} //= IO::Async::Loop->new;
}

sub boxman ($self, %opts) {
  return $self->{_boxman} if $self->{_boxman};

  require Dobby::BoxManager;
  require IO::Async::Loop;
  require String::Flogger;

  my $token = $ENV{DIGITALOCEAN_TOKEN};
  unless ($token) {
    die "\$DIGITALOCEAN_TOKEN isn't set. It should contain your API token or an opcli: URI\n";
  }

  if ($token =~ m{^opcli:}) {
    require Password::OnePassword::OPCLI;
    my $actual_token = Password::OnePassword::OPCLI->new->get_field($token);
    $token = $actual_token;
  }

  my $dobby = Dobby::Client->new(bearer_token => $token);

  $self->_loop->add($dobby);

  my $taskstream_cb = $opts{verbose_setup}
    ? sub ($line, @) { print $line if defined $line }
    : Dobby::Boxmate::TaskStream->new_taskstream_cb({ loop => $self->_loop });

  my $config = $self->config;
  $self->{_boxman} = Dobby::BoxManager->new({
    dobby       => $dobby,
    box_domain  => $config->box_domain,

    error_cb      => sub ($err) { die "❌ $err\n" },
    log_cb        => sub ($log) { say "🔸 " . String::Flogger->flog($log) },
    message_cb    => sub ($msg) { say "🔹 $msg" },
    taskstream_cb => $taskstream_cb,
  });
}

1;
